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
        val out = DocumentProcessor.render(page, Adjustments(autoWhiteBalance = false, evenLighting = false, sharpness = 0f), ChannelGains(2.0, 2.0, 2.0))
        val inset = page.cols() / 50
        val before = TestScenes.meanColor(page, inset, inset, inset * 3, inset * 3)
        val after = TestScenes.meanColor(out, inset, inset, inset * 3, inset * 3)
        for (channel in 0..2) assertEquals(before[channel], after[channel], 1.0)
        val warmer = DocumentProcessor.render(page, Adjustments(autoWhiteBalance = false, evenLighting = false, sharpness = 0f, temperature = 1f), ChannelGains.NEUTRAL)
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
    fun `black and white clears dark slivers along the page edge but keeps text`() {
        val bw = Mat(1000, 800, CvType.CV_8UC1, Scalar(255.0))
        // A shadow strip along the right edge, a dark corner wedge and a line running into the edge.
        org.opencv.imgproc.Imgproc.rectangle(bw, org.opencv.core.Point(785.0, 0.0), org.opencv.core.Point(799.0, 999.0), Scalar(0.0), -1)
        org.opencv.imgproc.Imgproc.rectangle(bw, org.opencv.core.Point(0.0, 0.0), org.opencv.core.Point(20.0, 12.0), Scalar(0.0), -1)
        org.opencv.imgproc.Imgproc.line(bw, org.opencv.core.Point(100.0, 500.0), org.opencv.core.Point(799.0, 500.0), Scalar(0.0), 3)
        // Text: a glyph inside the margin that does not touch the edge, and one in the body.
        org.opencv.imgproc.Imgproc.rectangle(bw, org.opencv.core.Point(6.0, 300.0), org.opencv.core.Point(16.0, 320.0), Scalar(0.0), -1)
        org.opencv.imgproc.Imgproc.rectangle(bw, org.opencv.core.Point(300.0, 300.0), org.opencv.core.Point(330.0, 330.0), Scalar(0.0), -1)

        DocumentProcessor.clearBorder(bw)

        assertEquals("strip", 255.0, Core.mean(bw.submat(0, 1000, 785, 800)).`val`[0], 0.0)
        assertEquals("wedge", 255.0, Core.mean(bw.submat(0, 13, 0, 21)).`val`[0], 0.0)
        assertEquals("glyph in the margin kept", 0.0, Core.mean(bw.submat(300, 321, 6, 17)).`val`[0], 0.0)
        assertEquals("glyph in the body kept", 0.0, Core.mean(bw.submat(300, 331, 300, 331)).`val`[0], 0.0)
        // The line keeps its part outside the margin.
        assertEquals("line kept", 0.0, Core.mean(bw.submat(499, 502, 100, 700)).`val`[0], 0.0)
        bw.release()
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

    /** A flat page lit from the top-left: the bottom-right corner gets 35 % less light. */
    private fun unevenlyLitPage(paper: Scalar = Scalar(235.0, 235.0, 232.0, 255.0), dark: Boolean = false): Mat {
        val flat = TestScenes.page(1050, 1485, paper)
        if (dark) {
            // A large photo-like dark block in the middle of the page.
            org.opencv.imgproc.Imgproc.rectangle(
                flat, org.opencv.core.Point(200.0, 400.0), org.opencv.core.Point(850.0, 1000.0),
                Scalar(25.0, 25.0, 25.0, 255.0), -1,
            )
        }
        val lit = TestScenes.scene(
            1050, 1485, flat, Quad.fullFrame(1050.0, 1485.0),
            background = paper, noise = 2.0, lighting = 0.35,
        )
        flat.release()
        return lit
    }

    private fun corners(image: Mat): Pair<Double, Double> {
        // Margins of the page: no text there.
        val s = image.cols() / 25
        val topLeft = TestScenes.meanColor(image, 4, 4, s, s)[0]
        val bottomRight = TestScenes.meanColor(image, image.cols() - s - 4, image.rows() - s - 4, s, s)[0]
        return topLeft to bottomRight
    }

    @Test
    fun `even lighting removes the falloff of light`() {
        val page = unevenlyLitPage()
        val gains = DocumentProcessor.estimateAutoGains(page)
        for (mode in listOf(ColorMode.COLOR, ColorMode.GRAYSCALE)) {
            val plain = DocumentProcessor.render(page, Adjustments(mode = mode, evenLighting = false), gains)
            val even = DocumentProcessor.render(page, Adjustments(mode = mode, evenLighting = true), gains)
            val (plainBright, plainDark) = corners(plain)
            val (evenBright, evenDark) = corners(even)
            assertTrue("$mode: test page should be unevenly lit ($plainBright vs $plainDark)", plainBright - plainDark > 50)
            assertEquals("$mode: lit corner", WhiteBalance.TARGET_WHITE, evenBright, 8.0)
            assertEquals("$mode: dim corner should be as white ($evenBright vs $evenDark)", evenBright, evenDark, 10.0)
            listOf(plain, even).forEach { it.release() }
        }
        page.release()
    }

    @Test
    fun `even lighting keeps text dark and large dark areas dark`() {
        val page = unevenlyLitPage(dark = true)
        val out = DocumentProcessor.render(page, Adjustments(mode = ColorMode.GRAYSCALE), DocumentProcessor.estimateAutoGains(page))
        // The dark block, even its dimly lit part, must not be "corrected" towards paper white.
        val block = TestScenes.meanColor(out, 600, 800, 200, 150)[0]
        assertTrue("dark block brightened to $block", block < 60)
        // Text stays dark next to the paper.
        val minMax = Core.minMaxLoc(out.submat(1100, 1400, 100, 950))
        assertTrue("text should stay dark, min ${minMax.minVal}", minMax.minVal < 60)
        out.release()
        page.release()
    }

    @Test
    fun `lighting gain`() {
        assertEquals(1.0, DocumentProcessor.lightingGain(200.0, 200.0), 1e-9)
        assertEquals(1.25, DocumentProcessor.lightingGain(160.0, 200.0), 1e-9) // shadow: fully corrected
        assertEquals(1.0, DocumentProcessor.lightingGain(60.0, 200.0), 1e-9) // dark content: untouched
        val partial = DocumentProcessor.lightingGain(105.0, 200.0)
        assertTrue(partial > 1.0 && partial < 200.0 / 105.0)
        assertEquals(0.85, DocumentProcessor.lightingGain(255.0, 200.0), 1e-9) // limited darkening
    }

    @Test
    fun `sharpening makes edges crisper and leaves flat paper alone`() {
        val page = flattenedPage()
        val gains = DocumentProcessor.estimateAutoGains(page)
        val soft = DocumentProcessor.render(page, Adjustments(mode = ColorMode.GRAYSCALE, sharpness = 0f), gains)
        val sharp = DocumentProcessor.render(page, Adjustments(mode = ColorMode.GRAYSCALE, sharpness = 1f), gains)
        fun detail(m: Mat): Double {
            val lap = Mat()
            org.opencv.imgproc.Imgproc.Laplacian(m, lap, CvType.CV_64F)
            val mean = org.opencv.core.MatOfDouble()
            val std = org.opencv.core.MatOfDouble()
            Core.meanStdDev(lap, mean, std)
            return std.toArray()[0]
        }
        assertTrue("sharpening should add detail", detail(sharp) > detail(soft) * 1.3)
        val inset = page.cols() / 50
        assertEquals(
            TestScenes.meanColor(soft, inset, inset, inset * 3, inset * 3)[0],
            TestScenes.meanColor(sharp, inset, inset, inset * 3, inset * 3)[0],
            2.0,
        )
        listOf(soft, sharp, page).forEach { it.release() }
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
