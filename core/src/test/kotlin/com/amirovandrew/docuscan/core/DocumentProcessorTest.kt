package com.amirovandrew.docuscan.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Scalar

class DocumentProcessorTest {

    companion object {
        @BeforeClass
        @JvmStatic
        fun loadOpenCv() = OpenCv.load()
    }

    private val warmPaper = Scalar(225.0, 205.0, 165.0, 255.0)

    /** A tilted A4 page with a warm colour cast, already flattened by [DocumentProcessor.warp]. */
    private fun flattenedPage(): Mat {
        val quad = TestScenes.projectRectangle(
            210.0, 297.0, 1500.0, 2000.0, focal = 1500.0, distance = 400.0,
            tiltX = 30.0, tiltY = -10.0, roll = 3.0,
        ).normalized()
        val scene = TestScenes.scene(1500, 2000, TestScenes.page(1050, 1485, warmPaper), quad)
        val found = DocumentDetector.detect(scene)!!
        return DocumentProcessor.warp(scene, found).also { scene.release() }
    }

    @Test
    fun `warp restores the A4 aspect ratio and crops the background away`() {
        val page = flattenedPage()
        assertEquals(210.0 / 297.0, page.cols().toDouble() / page.rows(), 0.02)
        // Margins of the page are paper coloured, not table coloured.
        val inset = page.cols() / 50
        for ((x, y) in listOf(inset to inset, page.cols() - 3 * inset to inset, inset to page.rows() - 3 * inset)) {
            val c = TestScenes.meanColor(page, x, y, inset * 2, inset * 2)
            assertTrue("corner area should be paper, got ${c.toList()}", c[0] > 190 && c[1] > 170)
        }
        // No strip of the (dark) table along the borders of the page.
        val strip = maxOf(2, page.cols() / 200)
        val edges = listOf(
            TestScenes.meanColor(page, 0, 0, page.cols(), strip),
            TestScenes.meanColor(page, 0, page.rows() - strip, page.cols(), strip),
            TestScenes.meanColor(page, 0, 0, strip, page.rows()),
            TestScenes.meanColor(page, page.cols() - strip, 0, strip, page.rows()),
        )
        edges.forEach { assertTrue("border strip should be paper, got ${it.toList()}", it[0] > 180) }
        page.release()
    }

    @Test
    fun `auto white balance makes the paper neutral white`() {
        val page = flattenedPage()
        val gains = DocumentProcessor.estimateAutoGains(page)
        val out = DocumentProcessor.render(page, Adjustments(), gains)
        val inset = page.cols() / 50
        val c = TestScenes.meanColor(out, inset, inset, inset * 3, inset * 3)
        for (channel in 0..2) assertEquals("channel $channel", WhiteBalance.TARGET_WHITE, c[channel], 6.0)
        assertEquals(4, out.channels())
        out.release()
        page.release()
    }

    @Test
    fun `manual white balance without auto keeps the original colours`() {
        val page = flattenedPage()
        val out = DocumentProcessor.render(page, Adjustments(autoWhiteBalance = false), ChannelGains(2.0, 2.0, 2.0))
        val inset = page.cols() / 50
        val before = TestScenes.meanColor(page, inset, inset, inset * 3, inset * 3)
        val after = TestScenes.meanColor(out, inset, inset, inset * 3, inset * 3)
        for (channel in 0..2) assertEquals(before[channel], after[channel], 1.0)
        val warmer = DocumentProcessor.render(page, Adjustments(autoWhiteBalance = false, temperature = 1f), ChannelGains.NEUTRAL)
        val w = TestScenes.meanColor(warmer, inset, inset, inset * 3, inset * 3)
        assertTrue(w[2] < before[2] - 20)
        listOf(out, warmer, page).forEach { it.release() }
    }

    @Test
    fun `grayscale output has one channel`() {
        val page = flattenedPage()
        val out = DocumentProcessor.render(page, Adjustments(mode = ColorMode.GRAYSCALE), DocumentProcessor.estimateAutoGains(page))
        assertEquals(CvType.CV_8UC1, out.type())
        assertEquals(page.size(), out.size())
        out.release()
        page.release()
    }

    @Test
    fun `black and white output is pure black and white with readable text`() {
        val page = flattenedPage()
        val out = DocumentProcessor.render(page, Adjustments(mode = ColorMode.BLACK_WHITE), DocumentProcessor.estimateAutoGains(page))
        assertEquals(CvType.CV_8UC1, out.type())
        val total = out.total().toDouble()
        val white = Core.countNonZero(out)
        val mid = Mat()
        Core.inRange(out, Scalar(1.0), Scalar(254.0), mid)
        assertEquals("only 0 and 255 expected", 0, Core.countNonZero(mid))
        val whiteShare = white / total
        // The page is mostly paper but the text must survive.
        assertTrue("white share $whiteShare", whiteShare in 0.6..0.97)
        listOf(out, mid, page).forEach { it.release() }
    }

    @Test
    fun `rotation swaps the dimensions`() {
        val page = flattenedPage()
        val out = DocumentProcessor.render(page, Adjustments(rotation = 90), ChannelGains.NEUTRAL)
        assertEquals(page.rows(), out.cols())
        assertEquals(page.cols(), out.rows())
        out.release()
        page.release()
    }

    @Test
    fun `downscale limits the longest side`() {
        val image = Mat(3000, 2000, CvType.CV_8UC4, Scalar(1.0, 2.0, 3.0, 255.0))
        val small = DocumentProcessor.downscale(image, 1500)
        assertEquals(1500, small.rows())
        assertEquals(1000, small.cols())
        listOf(image, small).forEach { it.release() }
    }
}
