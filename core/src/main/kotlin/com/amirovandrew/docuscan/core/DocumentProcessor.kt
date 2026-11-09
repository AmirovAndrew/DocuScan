package com.amirovandrew.docuscan.core

import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Turns a photo plus document corners into the final scan.
 *
 * Every function returns a new [Mat] owned by the caller; inputs are never modified.
 * Colour images are expected as RGB or RGBA (red first), 8 bits per channel.
 */
object DocumentProcessor {

    const val MAX_OUTPUT_SIDE = 6000

    /** Cuts out [quad] from [source] and flattens it into a rectangle. */
    fun warp(source: Mat, quad: Quad, maxSide: Int = MAX_OUTPUT_SIDE): Mat = matScope {
        val (width, height) = PerspectiveMath.targetSize(
            quad, source.cols().toDouble(), source.rows().toDouble(), maxSide,
        )
        val w = width.toDouble()
        val h = height.toDouble()
        val from = MatOfPoint2f(*quad.corners.map { Point(it.x, it.y) }.toTypedArray()).track()
        val to = MatOfPoint2f(Point(0.0, 0.0), Point(w, 0.0), Point(w, h), Point(0.0, h)).track()
        val transform = Imgproc.getPerspectiveTransform(from, to).track()
        val out = Mat()
        Imgproc.warpPerspective(source, out, transform, Size(w, h), Imgproc.INTER_LINEAR, Core.BORDER_REPLICATE)
        out
    }

    /** A copy of [source] whose longest side is at most [maxSide] pixels. */
    fun downscale(source: Mat, maxSide: Int): Mat {
        val out = Mat()
        val longest = max(source.cols(), source.rows())
        if (longest <= maxSide) {
            source.copyTo(out)
        } else {
            val k = maxSide.toDouble() / longest
            Imgproc.resize(source, out, Size(), k, k, Imgproc.INTER_AREA)
        }
        return out
    }

    /** Automatic white balance gains for a flattened document. */
    fun estimateAutoGains(image: Mat): ChannelGains = matScope {
        val small = downscale(image, 400).track()
        val bytes = ByteArray((small.total() * small.channels()).toInt())
        small.get(0, 0, bytes)
        WhiteBalance.autoGains(bytes, small.channels())
    }

    /**
     * Applies lighting correction, white balance, brightness/contrast, the colour mode,
     * sharpening and rotation.
     *
     * @return RGB(A) image for [ColorMode.COLOR], single-channel image otherwise.
     */
    fun render(source: Mat, adjustments: Adjustments, autoGains: ChannelGains): Mat = matScope {
        val channels = source.channels()
        require(channels == 3 || channels == 4) { "Expected an RGB or RGBA image, got $channels channels" }
        val blackWhite = adjustments.mode == ColorMode.BLACK_WHITE

        // Black & white uses a local threshold, which copes with uneven light by itself.
        val base = if (adjustments.evenLighting && !blackWhite) flattenLighting(source).track() else source

        val baseGains = if (adjustments.autoWhiteBalance) autoGains else ChannelGains.NEUTRAL
        val gains = baseGains * WhiteBalance.manualGains(adjustments.temperature, adjustments.tint)
        val adjusted = mat()
        Core.LUT(base, lookupTable(gains, adjustments, channels).track(), adjusted)
        if (base !== source) base.release() // full-size images are big: free memory early

        val result = when (adjustments.mode) {
            ColorMode.COLOR -> adjusted
            ColorMode.GRAYSCALE -> toGray(adjusted).track()
            ColorMode.BLACK_WHITE -> binarize(toGray(adjusted).track(), adjustments.threshold).track()
        }
        if (!blackWhite) sharpen(result, adjustments.sharpness)
        (rotate(result, adjustments.rotation)?.track() ?: result).keep()
    }

    /**
     * Evens out the lighting of a page.
     *
     * The brightness of the bare paper is estimated on a small copy: a large morphological closing
     * wipes out text and other small dark details, a blur smooths the result. Every pixel is then
     * brightened by as much as its surroundings fall short of the well-lit paper, so shadows and
     * dim corners become as bright as the rest of the page. Areas much darker than the paper are
     * taken for content (photos, dark blocks) and left alone.
     */
    fun flattenLighting(image: Mat): Mat = matScope {
        val channels = image.channels()
        val small = mat()
        toGray(image).track().let { gray ->
            val k = FLATTEN_WORK_SIZE / max(gray.cols(), gray.rows())
            Imgproc.resize(gray, small, Size(), k, k, Imgproc.INTER_AREA)
            gray.release()
        }

        val radius = max(2, (max(small.cols(), small.rows()) * FLATTEN_RADIUS).roundToInt())
        val kernelSize = 2.0 * radius + 1
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(kernelSize, kernelSize)).track()
        val background = mat()
        Imgproc.morphologyEx(small, background, Imgproc.MORPH_CLOSE, kernel)
        Imgproc.medianBlur(background, background, 5)
        Imgproc.GaussianBlur(background, background, Size(0.0, 0.0), radius / 2.0)

        val levels = ByteArray(background.total().toInt())
        background.get(0, 0, levels)
        val paper = max(1.0, percentile(levels, PAPER_PERCENTILE))

        // Gain per background level, stored as a fixed-point byte so that a plain 8-bit
        // multiplication can apply it to the full-size image.
        val gainTable = ByteArray(256) { level ->
            (lightingGain(level.toDouble(), paper) * GAIN_ONE).roundToInt().coerceIn(0, 255).toByte()
        }
        val gainLut = Mat(1, 256, CvType.CV_8UC1).track()
        gainLut.put(0, 0, gainTable)
        val smallGain = mat()
        Core.LUT(background, gainLut, smallGain)
        val gain = mat()
        Imgproc.resize(smallGain, gain, image.size(), 0.0, 0.0, Imgproc.INTER_LINEAR)

        val planes = ArrayList<Mat>()
        repeat(3) { planes += gain }
        if (channels == 4) planes += Mat(gain.size(), CvType.CV_8UC1, Scalar(GAIN_ONE)).track()
        val gains = mat()
        Core.merge(planes, gains)
        gain.release()

        val out = Mat()
        Core.multiply(image, gains, out, 1.0 / GAIN_ONE)
        out
    }

    /**
     * How much to brighten a pixel whose surroundings have brightness [background] when well-lit
     * paper has brightness [paper].
     */
    internal fun lightingGain(background: Double, paper: Double): Double {
        val full = (paper / max(background, 1.0)).coerceIn(MIN_LIGHTING_GAIN, MAX_LIGHTING_GAIN)
        // Fade the correction out for areas too dark to be shadowed paper.
        val t = ((background / paper - DARK_CONTENT_RATIO) / (SHADOW_RATIO - DARK_CONTENT_RATIO)).coerceIn(0.0, 1.0)
        val weight = t * t * (3 - 2 * t)
        return 1.0 + weight * (full - 1.0)
    }

    /** Unsharp masking in place; [strength] is 0..1. The radius scales with the image size. */
    fun sharpen(image: Mat, strength: Float) {
        if (strength <= 0f) return
        val sigma = max(0.8, max(image.cols(), image.rows()) / SHARPEN_SCALE)
        val amount = strength.coerceIn(0f, 1f) * MAX_SHARPEN_AMOUNT
        val blurred = Mat()
        Imgproc.GaussianBlur(image, blurred, Size(0.0, 0.0), sigma)
        Core.addWeighted(image, 1.0 + amount, blurred, -amount.toDouble(), 0.0, image)
        blurred.release()
    }

    private const val FLATTEN_WORK_SIZE = 256.0
    /** Radius of the closing relative to the long side: wider than any text, smaller than shadows. */
    private const val FLATTEN_RADIUS = 0.05
    private const val PAPER_PERCENTILE = 0.95
    private const val GAIN_ONE = 127.0
    private const val MIN_LIGHTING_GAIN = 0.85
    private const val MAX_LIGHTING_GAIN = 2.0
    /** Background below this share of the paper brightness is content, not a shadow… */
    private const val DARK_CONTENT_RATIO = 0.45
    /** …and above this share it is fully corrected. */
    private const val SHADOW_RATIO = 0.6
    /** Image size (long side) at which the sharpening radius is 1 pixel. */
    private const val SHARPEN_SCALE = 1600.0
    private const val MAX_SHARPEN_AMOUNT = 1.5

    private fun percentile(levels: ByteArray, percentile: Double): Double {
        val histogram = IntArray(256)
        for (b in levels) histogram[b.toInt() and 0xFF]++
        val wanted = (levels.size * percentile).toLong()
        var accumulated = 0L
        for (level in 0..255) {
            accumulated += histogram[level]
            if (accumulated >= wanted) return level.toDouble()
        }
        return 255.0
    }

    /**
     * Converts a grayscale page to pure black and white. A local (adaptive) threshold copes with
     * shadows and uneven lighting; very dark areas are kept black as well.
     *
     * @param threshold -1..1, higher values keep more dark detail.
     */
    fun binarize(gray: Mat, threshold: Float): Mat = matScope {
        var block = min(gray.cols(), gray.rows()) / 16
        if (block % 2 == 0) block += 1
        block = max(block, 15)

        val smoothed = mat()
        Imgproc.GaussianBlur(gray, smoothed, Size(3.0, 3.0), 0.0)

        val c = BW_BASE_C - threshold.coerceIn(-1f, 1f) * BW_C_RANGE
        val adaptive = mat()
        Imgproc.adaptiveThreshold(
            smoothed, adaptive, 255.0, Imgproc.ADAPTIVE_THRESH_MEAN_C, Imgproc.THRESH_BINARY, block, c,
        )

        // Large dark areas look locally uniform to the adaptive threshold and would turn white.
        val otsu = Imgproc.threshold(smoothed, mat(), 0.0, 255.0, Imgproc.THRESH_BINARY or Imgproc.THRESH_OTSU)
        val notDark = mat()
        Imgproc.threshold(smoothed, notDark, otsu * 0.5, 255.0, Imgproc.THRESH_BINARY)

        val out = Mat()
        Core.bitwise_and(adaptive, notDark, out)
        clearBorder(out)
        out
    }

    /**
     * Whitens black areas that run into the edge of the page within a narrow margin: slivers of
     * the table or the shadow of the page edge left over from cropping. Text in the margin that
     * does not touch the edge is kept.
     */
    internal fun clearBorder(bw: Mat) = matScope {
        val width = bw.cols()
        val height = bw.rows()
        val bandX = max(1, (width * BORDER_MARGIN).roundToInt())
        val bandY = max(1, (height * BORDER_MARGIN).roundToInt())

        // Ink (black pixels) within the margin only.
        val ink = mat()
        Core.bitwise_not(bw, ink)
        val margin = Mat(bw.size(), CvType.CV_8UC1, Scalar(255.0)).track()
        margin.submat(bandY, height - bandY, bandX, width - bandX).setTo(Scalar(0.0))
        Core.bitwise_and(ink, margin, ink)

        // Flood-fill the ink from every edge pixel; whatever got filled touches the edge.
        val remaining = ink.clone().track()
        val fillMask = Mat.zeros(height + 2, width + 2, CvType.CV_8UC1).track()
        val pixel = ByteArray(1)
        fun fillFrom(x: Int, y: Int) {
            remaining.get(y, x, pixel)
            if (pixel[0] != 0.toByte()) {
                Imgproc.floodFill(remaining, fillMask, Point(x.toDouble(), y.toDouble()), Scalar(0.0), null, Scalar(0.0), Scalar(0.0), 8)
            }
        }
        for (x in 0 until width) {
            fillFrom(x, 0)
            fillFrom(x, height - 1)
        }
        for (y in 0 until height) {
            fillFrom(0, y)
            fillFrom(width - 1, y)
        }
        val touchingEdge = mat()
        Core.subtract(ink, remaining, touchingEdge)
        Core.bitwise_or(bw, touchingEdge, bw)
    }

    private const val BW_BASE_C = 12.0
    private const val BW_C_RANGE = 10.0
    /** Width of the page margin cleaned by [clearBorder], relative to the page size. */
    private const val BORDER_MARGIN = 0.03

    private fun toGray(image: Mat): Mat {
        val gray = Mat()
        val code = if (image.channels() == 4) Imgproc.COLOR_RGBA2GRAY else Imgproc.COLOR_RGB2GRAY
        Imgproc.cvtColor(image, gray, code)
        return gray
    }

    private fun rotate(image: Mat, degrees: Int): Mat? {
        val code = when (((degrees % 360) + 360) % 360) {
            90 -> Core.ROTATE_90_CLOCKWISE
            180 -> Core.ROTATE_180
            270 -> Core.ROTATE_90_COUNTERCLOCKWISE
            else -> return null
        }
        val out = Mat()
        Core.rotate(image, out, code)
        return out
    }

    private fun lookupTable(gains: ChannelGains, adjustments: Adjustments, channels: Int): Mat {
        val curves = listOf(gains.r, gains.g, gains.b).map {
            ToneCurve.buildLut(it, adjustments.brightness, adjustments.contrast)
        }
        val data = ByteArray(256 * channels)
        for (i in 0 until 256) {
            for (c in 0 until 3) data[i * channels + c] = curves[c][i].toByte()
            if (channels == 4) data[i * channels + 3] = i.toByte() // alpha unchanged
        }
        val lut = Mat(1, 256, CvType.makeType(CvType.CV_8U, channels))
        lut.put(0, 0, data)
        return lut
    }
}
