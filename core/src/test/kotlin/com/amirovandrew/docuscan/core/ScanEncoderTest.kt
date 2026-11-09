package com.amirovandrew.docuscan.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.core.Scalar
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc

class ScanEncoderTest {

    companion object {
        @BeforeClass
        @JvmStatic
        fun loadOpenCv() = OpenCv.load()
    }

    private fun decode(bytes: ByteArray): Mat = Imgcodecs.imdecode(MatOfByte(*bytes), Imgcodecs.IMREAD_UNCHANGED)

    @Test
    fun `colour pages are JPEGs with the right colours`() {
        val page = Mat(300, 200, CvType.CV_8UC4, Scalar(200.0, 40.0, 30.0, 255.0)) // red, RGBA
        val encoded = ScanEncoder.encodeImage(page, ColorMode.COLOR)
        assertEquals(ImageFormat.JPEG, encoded.format)
        val decoded = decode(encoded.bytes) // BGR
        assertEquals(3, decoded.channels())
        assertEquals(200, decoded.cols())
        val bgr = Core.mean(decoded).`val`
        assertEquals(200.0, bgr[2], 4.0)
        assertEquals(30.0, bgr[0], 4.0)
    }

    @Test
    fun `grayscale pages are single-channel JPEGs`() {
        val page = Mat(300, 200, CvType.CV_8UC1, Scalar(120.0))
        val encoded = ScanEncoder.encodeImage(page, ColorMode.GRAYSCALE)
        assertEquals(ImageFormat.JPEG, encoded.format)
        assertEquals(1, decode(encoded.bytes).channels())
    }

    @Test
    fun `black and white pages are lossless PNGs`() {
        val page = TestScenes.page(600, 800, Scalar(255.0, 255.0, 255.0, 255.0), Scalar(0.0, 0.0, 0.0, 255.0))
        val bw = Mat()
        Imgproc.cvtColor(page, bw, Imgproc.COLOR_RGBA2GRAY)
        val encoded = ScanEncoder.encodeImage(bw, ColorMode.BLACK_WHITE)
        assertEquals(ImageFormat.PNG, encoded.format)
        val decoded = decode(encoded.bytes)
        assertEquals(1, decoded.channels())
        val difference = Mat()
        Core.absdiff(decoded, bw, difference)
        assertEquals(0, Core.countNonZero(difference))
        // 1 bit per pixel: much smaller than the JPEG of the same page.
        assertTrue(encoded.bytes.size < ScanEncoder.encodeImage(bw, ColorMode.GRAYSCALE).bytes.size)
    }
}
