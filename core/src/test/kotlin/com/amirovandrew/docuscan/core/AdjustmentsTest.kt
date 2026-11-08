package com.amirovandrew.docuscan.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AdjustmentsTest {

    private fun pixels(vararg rgb: Triple<Int, Int, Int>, repeat: Int = 1): ByteArray {
        val out = ByteArray(rgb.size * repeat * 4)
        var o = 0
        repeat(repeat) {
            for ((r, g, b) in rgb) {
                out[o++] = r.toByte(); out[o++] = g.toByte(); out[o++] = b.toByte(); out[o++] = 255.toByte()
            }
        }
        return out
    }

    @Test
    fun `identity tone curve`() {
        assertArrayEquals(IntArray(256) { it }, ToneCurve.buildLut(1.0, 0f, 0f))
    }

    @Test
    fun `tone curve clamps and stays monotonic`() {
        for (lut in listOf(
            ToneCurve.buildLut(2.0, 0.5f, 1f),
            ToneCurve.buildLut(0.6, -1f, -1f),
            ToneCurve.buildLut(1.3, 0.2f, 0.4f),
        )) {
            assertTrue(lut.all { it in 0..255 })
            for (i in 1 until 256) assertTrue(lut[i] >= lut[i - 1])
        }
        assertEquals(255, ToneCurve.buildLut(2.0, 0f, 0f)[200])
    }

    @Test
    fun `brightness and contrast move values the expected way`() {
        assertTrue(ToneCurve.buildLut(1.0, 0.5f, 0f)[100] > 100)
        assertTrue(ToneCurve.buildLut(1.0, -0.5f, 0f)[100] < 100)
        val contrast = ToneCurve.buildLut(1.0, 0f, 0.5f)
        assertTrue(contrast[200] > 200 && contrast[50] < 50)
    }

    @Test
    fun `paper colour comes from the brightest pixels`() {
        // 80 % dark text, 20 % warm paper.
        val data = pixels(
            Triple(20, 20, 20), Triple(25, 25, 25), Triple(22, 22, 22), Triple(21, 21, 21),
            Triple(230, 210, 170),
            repeat = 200,
        )
        val paper = WhiteBalance.estimatePaperColor(data, 4)!!
        assertEquals(230.0, paper[0], 0.5)
        assertEquals(210.0, paper[1], 0.5)
        assertEquals(170.0, paper[2], 0.5)
    }

    @Test
    fun `auto gains neutralise a colour cast and whiten the paper`() {
        val paper = doubleArrayOf(200.0, 180.0, 140.0)
        val gains = WhiteBalance.gainsForPaper(paper)
        assertEquals(WhiteBalance.TARGET_WHITE, paper[0] * gains.r, 0.01)
        assertEquals(WhiteBalance.TARGET_WHITE, paper[1] * gains.g, 0.01)
        assertEquals(WhiteBalance.TARGET_WHITE, paper[2] * gains.b, 0.01)
    }

    @Test
    fun `auto gains never darken a bright neutral page`() {
        val gains = WhiteBalance.gainsForPaper(doubleArrayOf(252.0, 252.0, 252.0))
        assertEquals(1.0, gains.r, 1e-9)
        assertEquals(1.0, gains.g, 1e-9)
        assertEquals(1.0, gains.b, 1e-9)
    }

    @Test
    fun `auto gains are limited for very dark images`() {
        val gains = WhiteBalance.gainsForPaper(doubleArrayOf(10.0, 10.0, 10.0))
        assertEquals(WhiteBalance.MAX_GAIN, gains.r, 1e-9)
    }

    @Test
    fun `manual temperature and tint`() {
        val warm = WhiteBalance.manualGains(1f, 0f)
        assertTrue(warm.r > 1.0 && warm.b < 1.0)
        val cool = WhiteBalance.manualGains(-1f, 0f)
        assertTrue(cool.r < 1.0 && cool.b > 1.0)
        val magenta = WhiteBalance.manualGains(0f, 1f)
        assertTrue(magenta.g < magenta.r && magenta.g < magenta.b)
        val neutral = WhiteBalance.manualGains(0f, 0f)
        for (g in listOf(neutral.r, neutral.g, neutral.b)) assertEquals(1.0, g, 1e-9)
        // Overall brightness is preserved.
        for (g in listOf(warm, cool, magenta)) {
            assertEquals(1.0, 0.299 * g.r + 0.587 * g.g + 0.114 * g.b, 1e-9)
        }
    }

    @Test
    fun `rotation wraps around`() {
        var a = Adjustments()
        repeat(4) { a = a.rotatedClockwise() }
        assertEquals(0, a.rotation)
        assertEquals(90, Adjustments().rotatedClockwise().rotation)
    }

    @Test
    fun `reset keeps mode and rotation`() {
        val a = Adjustments(mode = ColorMode.BLACK_WHITE, brightness = 0.3f, temperature = -0.2f, rotation = 180)
        assertEquals(Adjustments(mode = ColorMode.BLACK_WHITE, rotation = 180), a.resetSliders())
    }
}
