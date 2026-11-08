package com.amirovandrew.docuscan.core

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Scalar
import org.opencv.imgproc.Imgproc

class DocumentDetectorTest {

    companion object {
        @BeforeClass
        @JvmStatic
        fun loadOpenCv() = OpenCv.load()
    }

    private val white = Scalar(235.0, 235.0, 230.0, 255.0)

    private fun assertCornersNear(expected: Quad, actual: Quad?, tolerance: Double) {
        assertNotNull("document not found", actual)
        expected.corners.zip(actual!!.corners).forEachIndexed { i, (e, a) ->
            assertTrue("corner $i: expected $e, got $a", e.distanceTo(a) <= tolerance)
        }
    }

    private fun detectIn(scene: Mat): Quad? = DocumentDetector.detect(scene).also { scene.release() }

    @Test
    fun `finds a page on a dark table`() {
        val quad = Quad(Vec2(140.0, 110.0), Vec2(600.0, 140.0), Vec2(620.0, 760.0), Vec2(110.0, 730.0))
        val scene = TestScenes.scene(720, 900, TestScenes.page(420, 594, white), quad)
        assertCornersNear(quad, detectIn(scene), tolerance = 8.0)
    }

    @Test
    fun `finds a page photographed at an angle`() {
        val quad = TestScenes.projectRectangle(
            210.0, 297.0, 1200.0, 1600.0, focal = 1200.0, distance = 420.0,
            tiltX = 35.0, tiltY = 10.0, roll = 4.0,
        ).normalized()
        val scene = TestScenes.scene(1200, 1600, TestScenes.page(840, 1188, white), quad)
        assertCornersNear(quad, detectIn(scene), tolerance = 14.0)
    }

    @Test
    fun `finds a page on a light, low-contrast table`() {
        val quad = Quad(Vec2(90.0, 120.0), Vec2(560.0, 90.0), Vec2(590.0, 780.0), Vec2(120.0, 800.0))
        val scene = TestScenes.scene(
            700, 900, TestScenes.page(420, 594, white), quad,
            background = Scalar(185.0, 180.0, 170.0, 255.0), noise = 3.0,
        )
        assertCornersNear(quad, detectIn(scene), tolerance = 8.0)
    }

    @Test
    fun `finds a page on a textured table`() {
        val quad = Quad(Vec2(160.0, 140.0), Vec2(640.0, 120.0), Vec2(660.0, 800.0), Vec2(150.0, 820.0))
        val scene = TestScenes.scene(
            800, 960, TestScenes.page(420, 594, white), quad,
            background = Scalar(110.0, 80.0, 50.0, 255.0), texture = true,
        )
        assertCornersNear(quad, detectIn(scene), tolerance = 10.0)
    }

    @Test
    fun `works on full-resolution photos`() {
        val quad = Quad(Vec2(500.0, 420.0), Vec2(2550.0, 520.0), Vec2(2480.0, 3500.0), Vec2(420.0, 3380.0))
        val scene = TestScenes.scene(3000, 4000, TestScenes.page(1240, 1754, white), quad)
        assertCornersNear(quad, detectIn(scene), tolerance = 30.0)
    }

    @Test
    fun `accepts grayscale input`() {
        val quad = Quad(Vec2(140.0, 110.0), Vec2(600.0, 140.0), Vec2(620.0, 760.0), Vec2(110.0, 730.0))
        val scene = TestScenes.scene(720, 900, TestScenes.page(420, 594, white), quad)
        val gray = Mat()
        Imgproc.cvtColor(scene, gray, Imgproc.COLOR_RGBA2GRAY)
        scene.release()
        assertCornersNear(quad, detectIn(gray), tolerance = 8.0)
    }

    @Test
    fun `reports nothing when there is no document`() {
        val noise = Mat(600, 800, CvType.CV_8UC1)
        Core.randn(noise, 90.0, 20.0)
        Imgproc.GaussianBlur(noise, noise, org.opencv.core.Size(5.0, 5.0), 0.0)
        assertNull(detectIn(noise))
        assertNull(detectIn(Mat(600, 800, CvType.CV_8UC4, Scalar(50.0, 50.0, 50.0, 255.0))))
    }

    @Test
    fun `ignores small rectangles`() {
        val quad = Quad(Vec2(300.0, 300.0), Vec2(380.0, 300.0), Vec2(380.0, 400.0), Vec2(300.0, 400.0))
        val scene = TestScenes.scene(800, 900, TestScenes.page(80, 100, white), quad)
        assertNull(detectIn(scene))
    }
}
