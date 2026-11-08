package com.amirovandrew.docuscan.core

import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.max
import kotlin.math.min

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
     * Applies white balance, brightness/contrast, the colour mode and rotation.
     *
     * @return RGB(A) image for [ColorMode.COLOR], single-channel image otherwise.
     */
    fun render(source: Mat, adjustments: Adjustments, autoGains: ChannelGains): Mat = matScope {
        val channels = source.channels()
        require(channels == 3 || channels == 4) { "Expected an RGB or RGBA image, got $channels channels" }

        val baseGains = if (adjustments.autoWhiteBalance) autoGains else ChannelGains.NEUTRAL
        val gains = baseGains * WhiteBalance.manualGains(adjustments.temperature, adjustments.tint)
        val adjusted = mat()
        Core.LUT(source, lookupTable(gains, adjustments, channels).track(), adjusted)

        val result = when (adjustments.mode) {
            ColorMode.COLOR -> adjusted
            ColorMode.GRAYSCALE -> toGray(adjusted).track()
            ColorMode.BLACK_WHITE -> binarize(toGray(adjusted).track(), adjustments.threshold).track()
        }
        (rotate(result, adjustments.rotation)?.track() ?: result).keep()
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
        out
    }

    private const val BW_BASE_C = 12.0
    private const val BW_C_RANGE = 10.0

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
