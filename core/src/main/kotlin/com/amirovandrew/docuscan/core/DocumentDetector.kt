package com.amirovandrew.docuscan.core

import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfInt
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Finds the outline of a sheet of paper in a photo.
 *
 * The image is downscaled and text is wiped out with a morphological closing. Then several
 * binarisations are searched for large convex four-sided contours: two Canny edge maps with fixed
 * thresholds, one on a contrast-equalised copy with thresholds taken from the frame itself (for
 * white paper on a white table) and an Otsu threshold. Colour images are searched in their
 * colour channels (Lab a* and b*) as well, for tinted paper as bright as the table. Every
 * candidate must be backed by a real edge along its outline (see [sideSupport]); the biggest such
 * candidate wins.
 */
object DocumentDetector {

    /** Default minimum share of the frame the document has to cover. */
    const val DEFAULT_MIN_AREA = 0.1

    private const val WORK_SIZE = 500.0
    private val APPROX_EPSILONS = doubleArrayOf(0.015, 0.02, 0.03, 0.04, 0.05, 0.06, 0.08)

    /**
     * A possible document outline (in image coordinates), the share of its outline backed by an
     * edge and the same share for its weakest side.
     */
    internal data class Candidate(val quad: Quad, val support: Double, val weakestSide: Double) {
        val isSupported get() = support >= MIN_EDGE_SUPPORT && weakestSide >= MIN_SIDE_SUPPORT
    }

    /**
     * @param image grayscale (CV_8UC1), RGB (CV_8UC3) or RGBA (CV_8UC4) image.
     * @param minAreaFraction minimum share of the frame the document must cover.
     * @return corners of the document in [image] pixel coordinates, or null if none was found.
     */
    fun detect(image: Mat, minAreaFraction: Double = DEFAULT_MIN_AREA): Quad? {
        val supported = candidates(image, minAreaFraction).filter { it.isSupported }
        // The page is normally the biggest outline, but a slightly bigger one with a poorly backed
        // side must not beat an exact one: weigh the area by the edge support.
        val best = supported.maxByOrNull { it.quad.area() * it.support } ?: return null

        // The same outline is usually found several times: as the outer and inner border of the
        // (dilated) edge line and as the outline of the thresholded page. Average them, trusting
        // the better-backed ones more.
        val tolerance = NEAR_DUPLICATE_FRACTION * hypot(image.cols().toDouble(), image.rows().toDouble())
        val cluster = supported.filter { other ->
            best.quad.corners.zip(other.quad.corners).all { (a, b) -> a.distanceTo(b) <= tolerance }
        }
        return average(cluster)
    }

    /** All plausible outlines with their edge support, in [image] coordinates. */
    internal fun candidates(image: Mat, minAreaFraction: Double = DEFAULT_MIN_AREA): List<Candidate> = matScope {
        if (image.empty()) return emptyList()
        val gray = when (image.channels()) {
            1 -> image
            3 -> mat().also { Imgproc.cvtColor(image, it, Imgproc.COLOR_RGB2GRAY) }
            4 -> mat().also { Imgproc.cvtColor(image, it, Imgproc.COLOR_RGBA2GRAY) }
            else -> return emptyList()
        }

        val scale = min(1.0, WORK_SIZE / max(gray.cols(), gray.rows()))
        val small = if (scale < 1.0) {
            mat().also { Imgproc.resize(gray, it, Size(), scale, scale, Imgproc.INTER_AREA) }
        } else {
            gray
        }

        val frameArea = small.cols().toDouble() * small.rows()
        val minArea = frameArea * minAreaFraction
        val maxArea = frameArea * 0.995

        val quads = ArrayList<Quad>()
        // Brightness: the usual case of a page brighter or darker than the table.
        val fields = arrayListOf(checkNotNull(searchChannel(small, minArea, maxArea, quads, colour = false)))
        // Colour: tinted paper (forms, certificates) on a grey table can be exactly as bright as
        // the table and only differ in colour, and vice versa for white paper on a wooden table.
        if (image.channels() >= 3) {
            for (chroma in chromaChannels(image, small.size())) {
                searchChannel(chroma.track(), minArea, maxArea, quads, colour = true)?.let { fields += it }
            }
        }

        quads.map { quad ->
            // A side counts as backed by an edge if it is backed in any of the channels.
            val perChannel = fields.map { (gradient, threshold) -> sideSupport(quad, gradient, threshold) }
            val sides = (0..3).map { i -> perChannel.maxOf { it[i].first } to perChannel[0][i].second }
            Candidate(
                quad = quad.scale(1.0 / scale),
                support = sides.sumOf { it.first }.toDouble() / max(1, sides.sumOf { it.second }),
                weakestSide = sides.minOf { it.first.toDouble() / max(1, it.second) },
            )
        }
    }

    /**
     * Looks for page outlines in one channel of the working image and adds them to [quads].
     *
     * @param colour [channel] is a colour channel: it is skipped when the scene has no real colour
     *   contrast (its variations would be noise), and the fixed Canny thresholds, which are meant
     *   for brightness, are not used.
     * @return the gradient of the channel and the edge threshold to check candidates against, or
     *   null if the channel was skipped.
     */
    private fun MatScope.searchChannel(
        channel: Mat,
        minArea: Double,
        maxArea: Double,
        quads: MutableList<Quad>,
        colour: Boolean,
    ): Pair<GradientField, Double>? {
        val blurred = mat()
        Imgproc.GaussianBlur(channel, blurred, Size(5.0, 5.0), 0.0)
        // A closing removes dark details such as text, so mostly the outline of the page remains.
        val closeKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(9.0, 9.0)).track()
        val closed = mat()
        Imgproc.morphologyEx(blurred, closed, Imgproc.MORPH_CLOSE, closeKernel)
        // Measured after the closing, so that coloured ink does not count, only coloured areas.
        if (colour && spread(closed) < MIN_COLOUR_SPREAD) return null

        val dilateKernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0)).track()
        val edges = mat()
        if (!colour) {
            val median = median(closed)
            val cannyThresholds = listOf(
                max(10.0, 0.66 * median) to min(255.0, max(30.0, 1.33 * median)),
                20.0 to 60.0, // low-contrast scenes: white paper on a light table
            )
            for ((low, high) in cannyThresholds) {
                Imgproc.Canny(closed, edges, low, high)
                Imgproc.dilate(edges, edges, dilateKernel)
                collectQuads(edges, minArea, maxArea, quads)
            }
        }

        // White paper on a white table: the outline differs from the background by only a few
        // levels. Local contrast equalisation (CLAHE) brings it out, and the Canny thresholds are
        // taken from the gradient statistics of this very frame instead of being fixed.
        val equalized = mat()
        Imgproc.createCLAHE(CLAHE_CLIP_LIMIT, Size(8.0, 8.0)).apply(closed, equalized)
        Imgproc.GaussianBlur(equalized, equalized, Size(3.0, 3.0), 0.0)
        val gradient = GradientField.of(equalized)
        val high = max(MIN_ADAPTIVE_THRESHOLD, gradient.magnitudePercentile(ADAPTIVE_EDGE_PERCENTILE))
        Imgproc.Canny(equalized, edges, high * 0.5, high, 3, true)
        Imgproc.dilate(edges, edges, dilateKernel)
        collectQuads(edges, minArea, maxArea, quads)

        // The page as a region brighter (or, through the holes it leaves, darker) than the rest.
        val binary = mat()
        Imgproc.threshold(closed, binary, 0.0, 255.0, Imgproc.THRESH_BINARY or Imgproc.THRESH_OTSU)
        collectQuads(binary, minArea, maxArea, quads)

        return gradient to high
    }

    /** The red-green and yellow-blue channels (CIE Lab a* and b*) of [image], scaled to [size]. */
    private fun chromaChannels(image: Mat, size: Size): List<Mat> = matScope {
        val small = mat()
        Imgproc.resize(image, small, size, 0.0, 0.0, Imgproc.INTER_AREA)
        val rgb = if (small.channels() == 4) mat().also { Imgproc.cvtColor(small, it, Imgproc.COLOR_RGBA2RGB) } else small
        val lab = mat()
        Imgproc.cvtColor(rgb, lab, Imgproc.COLOR_RGB2Lab)
        val channels = ArrayList<Mat>()
        Core.split(lab, channels)
        channels[0].release()
        listOf(channels[1], channels[2])
    }

    private fun average(candidates: List<Candidate>): Quad {
        val weights = candidates.map { it.support * it.support }
        val total = weights.sum()
        fun mean(pick: (Quad) -> Vec2) = Vec2(
            candidates.indices.sumOf { pick(candidates[it].quad).x * weights[it] } / total,
            candidates.indices.sumOf { pick(candidates[it].quad).y * weights[it] } / total,
        )
        return Quad(mean { it.topLeft }, mean { it.topRight }, mean { it.bottomRight }, mean { it.bottomLeft })
    }

    private const val NEAR_DUPLICATE_FRACTION = 0.015

    /** Gradient of the (contrast-equalised) working image. */
    internal class GradientField(val width: Int, val height: Int, val dx: FloatArray, val dy: FloatArray) {

        /** The given percentile of the gradient magnitude (L2, as Canny with `L2gradient`). */
        fun magnitudePercentile(percentile: Double): Double {
            val histogram = IntArray(GRADIENT_BINS)
            for (i in dx.indices) {
                val magnitude = sqrt(dx[i] * dx[i] + dy[i] * dy[i])
                histogram[magnitude.toInt().coerceIn(0, GRADIENT_BINS - 1)]++
            }
            val wanted = (dx.size * percentile).toLong()
            var accumulated = 0L
            for (bin in 0 until GRADIENT_BINS) {
                accumulated += histogram[bin]
                if (accumulated >= wanted) return bin.toDouble()
            }
            return (GRADIENT_BINS - 1).toDouble()
        }

        companion object {
            fun of(gray: Mat): GradientField = matScope {
                val gx = mat()
                val gy = mat()
                Imgproc.Sobel(gray, gx, CvType.CV_32F, 1, 0)
                Imgproc.Sobel(gray, gy, CvType.CV_32F, 0, 1)
                val dx = FloatArray(gx.total().toInt())
                val dy = FloatArray(gy.total().toInt())
                gx.get(0, 0, dx)
                gy.get(0, 0, dy)
                GradientField(gray.cols(), gray.rows(), dx, dy)
            }
        }
    }

    /**
     * How much of each side of [quad] is backed by a real edge, as (supporting samples, samples).
     *
     * A point of a side supports it if the brightness changes across the side by at least
     * [threshold], and in the same direction as along the rest of the side (paper on one side,
     * table on the other). Texture and noise change direction all the time, and a side running
     * along the image border has no edge under it at all.
     */
    internal fun sideSupport(quad: Quad, gradient: GradientField, threshold: Double): List<Pair<Int, Int>> {
        val corners = quad.corners
        return (0..3).map { i ->
            val a = corners[i]
            val b = corners[(i + 1) % 4]
            val length = a.distanceTo(b)
            if (length < 1.0) return@map 0 to 0
            val ux = (b.x - a.x) / length
            val uy = (b.y - a.y) / length
            val nx = -uy
            val ny = ux
            var positive = 0
            var negative = 0
            val steps = length.toInt()
            for (s in 0 until steps) {
                val px = a.x + ux * s
                val py = a.y + uy * s
                // The outline may be off by a pixel or two: take the strongest response nearby.
                var best = 0.0
                for (offset in -SUPPORT_SEARCH..SUPPORT_SEARCH) {
                    val x = (px + nx * offset).roundToInt()
                    val y = (py + ny * offset).roundToInt()
                    if (x !in 0 until gradient.width || y !in 0 until gradient.height) continue
                    val index = y * gradient.width + x
                    val across = gradient.dx[index] * nx + gradient.dy[index] * ny
                    if (abs(across) > abs(best)) best = across
                }
                if (best >= threshold) positive++ else if (best <= -threshold) negative++
            }
            max(positive, negative) to steps
        }
    }

    /**
     * Thresholds for [sideSupport], measured against the edge threshold of the frame (the 90th
     * percentile of the gradient). A white page on a white table scores about 0.6 overall with its
     * faintest side around 0.3; outlines found in plain noise score about 0.1.
     */
    private const val MIN_EDGE_SUPPORT = 0.45
    private const val MIN_SIDE_SUPPORT = 0.15
    private const val SUPPORT_SEARCH = 2

    private fun collectQuads(binary: Mat, minArea: Double, maxArea: Double, out: MutableList<Quad>) {
        val contours = ArrayList<MatOfPoint>()
        val hierarchy = Mat()
        Imgproc.findContours(binary, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)
        hierarchy.release()
        val hullIndices = MatOfInt()
        val approx = MatOfPoint2f()
        try {
            for (contour in contours) {
                if (contour.rows() < 4 || Imgproc.boundingRect(contour).area() < minArea) continue

                // The convex hull closes gaps in the outline (e.g. a missing edge on one side).
                Imgproc.convexHull(contour, hullIndices)
                val points = contour.toArray()
                val hullPoints = hullIndices.toArray().map { points[it] }
                if (hullPoints.size < 4) continue
                val hull = MatOfPoint2f(*hullPoints.toTypedArray())
                try {
                    val hullArea = Imgproc.contourArea(hull)
                    if (hullArea < minArea || hullArea > maxArea) continue
                    val perimeter = Imgproc.arcLength(hull, true)
                    for (epsilon in APPROX_EPSILONS) {
                        Imgproc.approxPolyDP(hull, approx, epsilon * perimeter, true)
                        val n = approx.rows()
                        if (n < 4) break
                        if (n == 4) {
                            val quad = Quad.fromPoints(approx.toArray().map { Vec2(it.x, it.y) })
                            if (isPlausible(quad, hullArea, minArea, maxArea)) out += quad
                            break
                        }
                    }
                } finally {
                    hull.release()
                }
            }
        } finally {
            hullIndices.release()
            approx.release()
            contours.forEach { it.release() }
        }
    }

    internal fun isPlausible(quad: Quad, hullArea: Double, minArea: Double, maxArea: Double): Boolean {
        if (!quad.isConvex()) return false
        val area = quad.area()
        if (area < minArea || area > maxArea) return false
        // The four corners must describe the contour well, not just be forced onto a blob.
        if (area / hullArea !in 0.85..1.15) return false
        if (Geometry.interiorAngles(quad.corners).any { it < 35.0 || it > 145.0 }) return false
        val c = quad.corners
        val sides = (0..3).map { c[it].distanceTo(c[(it + 1) % 4]) }
        return sides.min() >= 0.05 * sides.max()
    }

    private const val CLAHE_CLIP_LIMIT = 2.0
    private const val ADAPTIVE_EDGE_PERCENTILE = 0.9
    /** Keeps the adaptive pass from turning sensor noise of a featureless frame into edges. */
    private const val MIN_ADAPTIVE_THRESHOLD = 8.0
    private const val GRADIENT_BINS = 2048

    /** Difference between the 98th and the 2nd percentile of an 8-bit channel. */
    private fun spread(channel: Mat): Int {
        val histogram = histogram(channel)
        val total = histogram.sum()
        fun level(percentile: Double): Int {
            val wanted = (total * percentile).toLong()
            var accumulated = 0L
            for (level in 0..255) {
                accumulated += histogram[level]
                if (accumulated > wanted) return level
            }
            return 255
        }
        return level(0.98) - level(0.02)
    }

    /**
     * Colour channels whose large areas vary less than this (in CIE Lab units) only hold noise.
     * A pale green form on a grey table spreads about 14; white paper on a white table about 4.
     */
    private const val MIN_COLOUR_SPREAD = 9

    private fun histogram(channel: Mat): IntArray {
        val bytes = ByteArray((channel.total() * channel.channels()).toInt())
        channel.get(0, 0, bytes)
        val histogram = IntArray(256)
        for (b in bytes) histogram[b.toInt() and 0xFF]++
        return histogram
    }

    private fun median(gray: Mat): Double {
        val bytes = ByteArray((gray.total() * gray.channels()).toInt())
        gray.get(0, 0, bytes)
        val histogram = IntArray(256)
        for (b in bytes) histogram[b.toInt() and 0xFF]++
        val half = bytes.size / 2
        var accumulated = 0
        for (level in 0..255) {
            accumulated += histogram[level]
            if (accumulated > half) return level.toDouble()
        }
        return 128.0
    }
}
