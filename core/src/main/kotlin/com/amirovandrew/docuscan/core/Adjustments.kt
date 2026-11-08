package com.amirovandrew.docuscan.core

import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

enum class ColorMode { COLOR, GRAYSCALE, BLACK_WHITE }

/**
 * User-controlled settings for rendering a flattened document.
 *
 * All slider values are in the range -1..1, 0 meaning "no change".
 */
data class Adjustments(
    val mode: ColorMode = ColorMode.COLOR,
    /** Neutralise the paper colour automatically. Manual temperature/tint are applied on top. */
    val autoWhiteBalance: Boolean = true,
    /** Positive = warmer (more red, less blue). */
    val temperature: Float = 0f,
    /** Positive = more magenta, negative = more green. */
    val tint: Float = 0f,
    val brightness: Float = 0f,
    val contrast: Float = 0f,
    /** Black & white only: positive keeps more dark detail (bolder text), negative gives a cleaner page. */
    val threshold: Float = 0f,
    /** Clockwise rotation of the result, one of 0, 90, 180, 270. */
    val rotation: Int = 0,
) {
    fun rotatedClockwise(): Adjustments = copy(rotation = (rotation + 90) % 360)

    /** Resets the sliders but keeps the chosen mode, auto white balance setting and rotation. */
    fun resetSliders(): Adjustments =
        Adjustments(mode = mode, autoWhiteBalance = autoWhiteBalance, rotation = rotation)
}

/** Per-channel multipliers. */
data class ChannelGains(val r: Double, val g: Double, val b: Double) {
    operator fun times(other: ChannelGains) = ChannelGains(r * other.r, g * other.g, b * other.b)

    companion object {
        val NEUTRAL = ChannelGains(1.0, 1.0, 1.0)
    }
}

object WhiteBalance {

    /** Brightness the paper is pushed to by the automatic white balance. */
    const val TARGET_WHITE = 245.0
    const val MIN_GAIN = 0.6
    const val MAX_GAIN = 2.5

    /** Share of the brightest pixels that are assumed to be paper. */
    private const val PAPER_FRACTION = 0.10

    /**
     * Estimates the colour of the paper as the average colour of the brightest pixels.
     *
     * @param pixels interleaved 8-bit pixels, red first (RGB or RGBA).
     * @param channels bytes per pixel (3 or 4).
     * @return average red, green and blue of the paper, or null if there are no pixels.
     */
    fun estimatePaperColor(pixels: ByteArray, channels: Int): DoubleArray? {
        require(channels >= 3) { "Need at least 3 channels" }
        val count = pixels.size / channels
        if (count == 0) return null

        val histogram = IntArray(256)
        for (i in 0 until count) {
            val o = i * channels
            histogram[luma(pixels[o], pixels[o + 1], pixels[o + 2])]++
        }

        // Luma level from which the brightest PAPER_FRACTION of pixels start.
        val wanted = max(1, (count * PAPER_FRACTION).roundToInt())
        var level = 255
        var accumulated = histogram[255]
        while (level > 0 && accumulated < wanted) {
            level--
            accumulated += histogram[level]
        }

        // Clipped pixels carry no colour information, so prefer the unclipped ones.
        val unclipped = averageColor(pixels, channels, level, skipClipped = true)
        return unclipped ?: averageColor(pixels, channels, level, skipClipped = false)
    }

    /** Gains that turn [paper] into a neutral white of at least [TARGET_WHITE]. */
    fun gainsForPaper(paper: DoubleArray): ChannelGains {
        val paperLuma = 0.299 * paper[0] + 0.587 * paper[1] + 0.114 * paper[2]
        // Never darken a page that is already brighter than the target.
        val target = max(TARGET_WHITE, paperLuma)
        fun gain(v: Double) = (target / max(v, 1.0)).coerceIn(MIN_GAIN, MAX_GAIN)
        return ChannelGains(gain(paper[0]), gain(paper[1]), gain(paper[2]))
    }

    /** Automatic white balance gains for an image, see [estimatePaperColor]. */
    fun autoGains(pixels: ByteArray, channels: Int): ChannelGains =
        estimatePaperColor(pixels, channels)?.let(::gainsForPaper) ?: ChannelGains.NEUTRAL

    /**
     * Gains for manual temperature and tint (both -1..1). They are normalised so that the overall
     * brightness stays the same.
     */
    fun manualGains(temperature: Float, tint: Float): ChannelGains {
        val t = temperature.coerceIn(-1f, 1f).toDouble()
        val m = tint.coerceIn(-1f, 1f).toDouble()
        val r = 1.0 + TEMPERATURE_STRENGTH * t
        val b = 1.0 - TEMPERATURE_STRENGTH * t
        val g = 1.0 - TINT_STRENGTH * m
        val luma = 0.299 * r + 0.587 * g + 0.114 * b
        return ChannelGains(r / luma, g / luma, b / luma)
    }

    private const val TEMPERATURE_STRENGTH = 0.35
    private const val TINT_STRENGTH = 0.25

    internal fun luma(r: Byte, g: Byte, b: Byte): Int =
        (299 * (r.toInt() and 0xFF) + 587 * (g.toInt() and 0xFF) + 114 * (b.toInt() and 0xFF)) / 1000

    private fun averageColor(pixels: ByteArray, channels: Int, minLuma: Int, skipClipped: Boolean): DoubleArray? {
        var sr = 0L
        var sg = 0L
        var sb = 0L
        var n = 0L
        var o = 0
        while (o + 2 < pixels.size) {
            val r = pixels[o].toInt() and 0xFF
            val g = pixels[o + 1].toInt() and 0xFF
            val b = pixels[o + 2].toInt() and 0xFF
            if (luma(pixels[o], pixels[o + 1], pixels[o + 2]) >= minLuma &&
                !(skipClipped && (r == 255 || g == 255 || b == 255))
            ) {
                sr += r
                sg += g
                sb += b
                n++
            }
            o += channels
        }
        if (n == 0L) return null
        return doubleArrayOf(sr.toDouble() / n, sg.toDouble() / n, sb.toDouble() / n)
    }
}

object ToneCurve {

    /**
     * Builds a 256-entry lookup table for one channel:
     * `v -> clamp((v * gain - 128) * contrastFactor + 128 + brightnessOffset)`.
     */
    fun buildLut(gain: Double, brightness: Float, contrast: Float): IntArray {
        val factor = contrastFactor(contrast)
        val offset = brightnessOffset(brightness)
        return IntArray(256) { v ->
            ((v * gain - 128.0) * factor + 128.0 + offset).roundToInt().coerceIn(0, 255)
        }
    }

    /** -1..1 maps to roughly 0.4x..2.4x contrast. */
    fun contrastFactor(contrast: Float): Double = 2.0.pow(contrast.coerceIn(-1f, 1f) * 1.25)

    /** -1..1 maps to -96..+96 levels. */
    fun brightnessOffset(brightness: Float): Double = brightness.coerceIn(-1f, 1f) * 96.0
}
