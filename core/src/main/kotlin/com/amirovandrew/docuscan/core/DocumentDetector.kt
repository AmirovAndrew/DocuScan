package com.amirovandrew.docuscan.core

import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.core.MatOfInt
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Finds the outline of a sheet of paper in a photo.
 *
 * The image is downscaled, text is wiped out with a morphological closing, and then several
 * binarisations (two Canny edge maps and an Otsu threshold) are searched for large convex
 * four-sided contours. The biggest plausible one wins.
 */
object DocumentDetector {

    /** Default minimum share of the frame the document has to cover. */
    const val DEFAULT_MIN_AREA = 0.1

    private const val WORK_SIZE = 500.0
    private val APPROX_EPSILONS = doubleArrayOf(0.015, 0.02, 0.03, 0.04, 0.05, 0.06, 0.08)

    /**
     * @param image grayscale (CV_8UC1), RGB (CV_8UC3) or RGBA (CV_8UC4) image.
     * @param minAreaFraction minimum share of the frame the document must cover.
     * @return corners of the document in [image] pixel coordinates, or null if none was found.
     */
    fun detect(image: Mat, minAreaFraction: Double = DEFAULT_MIN_AREA): Quad? = matScope {
        if (image.empty()) return null
        val gray = when (image.channels()) {
            1 -> image
            3 -> mat().also { Imgproc.cvtColor(image, it, Imgproc.COLOR_RGB2GRAY) }
            4 -> mat().also { Imgproc.cvtColor(image, it, Imgproc.COLOR_RGBA2GRAY) }
            else -> return null
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

        val blurred = mat()
        Imgproc.GaussianBlur(small, blurred, Size(5.0, 5.0), 0.0)
        // A closing removes dark details such as text, so mostly the outline of the page remains.
        val closeKernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(9.0, 9.0)).track()
        val closed = mat()
        Imgproc.morphologyEx(blurred, closed, Imgproc.MORPH_CLOSE, closeKernel)

        val candidates = ArrayList<Quad>()
        val dilateKernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0)).track()
        val median = median(closed)
        val cannyThresholds = listOf(
            max(10.0, 0.66 * median) to min(255.0, max(30.0, 1.33 * median)),
            20.0 to 60.0, // low-contrast scenes: white paper on a light table
        )
        val edges = mat()
        // Union of all edge maps, used to check that a candidate really follows edges in the image.
        val allEdges = Mat.zeros(closed.size(), closed.type()).track()
        for ((low, high) in cannyThresholds) {
            Imgproc.Canny(closed, edges, low, high)
            Core.bitwise_or(allEdges, edges, allEdges)
            Imgproc.dilate(edges, edges, dilateKernel)
            collectQuads(edges, minArea, maxArea, candidates)
        }

        // Bright page on a darker background.
        val binary = mat()
        Imgproc.threshold(closed, binary, 0.0, 255.0, Imgproc.THRESH_BINARY or Imgproc.THRESH_OTSU)
        collectQuads(binary, minArea, maxArea, candidates)
        if (candidates.isEmpty()) return null

        val supportKernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(5.0, 5.0)).track()
        Imgproc.dilate(allEdges, allEdges, supportKernel)
        val edgeBytes = ByteArray((allEdges.total()).toInt())
        allEdges.get(0, 0, edgeBytes)

        val supported = candidates.filter {
            edgeSupport(it, edgeBytes, allEdges.cols(), allEdges.rows()) >= MIN_EDGE_SUPPORT
        }
        val best = supported.maxByOrNull { it.area() } ?: return null

        // The same outline is usually found several times: as the outer and inner border of the
        // (dilated) edge line and as the outline of the thresholded page. The outer one is the
        // biggest but lies slightly outside the page, so average all of them.
        val tolerance = NEAR_DUPLICATE_FRACTION * hypot(small.cols().toDouble(), small.rows().toDouble())
        val cluster = supported.filter { other ->
            best.corners.zip(other.corners).all { (a, b) -> a.distanceTo(b) <= tolerance }
        }
        average(cluster).scale(1.0 / scale)
    }

    private fun average(quads: List<Quad>): Quad {
        fun mean(pick: (Quad) -> Vec2) = Vec2(quads.sumOf { pick(it).x } / quads.size, quads.sumOf { pick(it).y } / quads.size)
        return Quad(mean { it.topLeft }, mean { it.topRight }, mean { it.bottomRight }, mean { it.bottomLeft })
    }

    private const val NEAR_DUPLICATE_FRACTION = 0.015

    /**
     * Share of the quad outline that lies on an edge. Sides running along the image border have no
     * edges under them, so outlines made up of the frame itself are rejected too.
     */
    internal fun edgeSupport(quad: Quad, edges: ByteArray, width: Int, height: Int): Double {
        var hits = 0
        var total = 0
        val corners = quad.corners
        for (i in 0..3) {
            val a = corners[i]
            val b = corners[(i + 1) % 4]
            val steps = max(1, a.distanceTo(b).toInt())
            for (s in 0 until steps) {
                val t = s.toDouble() / steps
                val x = (a.x + (b.x - a.x) * t).roundToInt()
                val y = (a.y + (b.y - a.y) * t).roundToInt()
                total++
                if (x in 0 until width && y in 0 until height && edges[y * width + x] != 0.toByte()) hits++
            }
        }
        return if (total == 0) 0.0 else hits.toDouble() / total
    }

    private const val MIN_EDGE_SUPPORT = 0.65

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
