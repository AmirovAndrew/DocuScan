package com.amirovandrew.docuscan.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Scalar
import org.opencv.imgproc.Imgproc
import java.io.ByteArrayOutputStream
import java.util.zip.InflaterInputStream

class PdfWriterTest {

    companion object {
        @BeforeClass
        @JvmStatic
        fun loadOpenCv() = OpenCv.load()
    }

    private fun latin1(bytes: ByteArray) = String(bytes, Charsets.ISO_8859_1)

    private fun threePagePdf(): Pair<ByteArray, ByteArray> {
        val color = TestScenes.page(420, 594, Scalar(240.0, 230.0, 210.0, 255.0))
        val gray = Mat()
        Imgproc.cvtColor(color, gray, Imgproc.COLOR_RGBA2GRAY)
        val bw = Mat()
        Imgproc.threshold(gray, bw, 128.0, 255.0, Imgproc.THRESH_BINARY)
        // Landscape black & white page whose width is not a multiple of 8.
        val wide = Mat()
        org.opencv.core.Core.rotate(bw, wide, org.opencv.core.Core.ROTATE_90_CLOCKWISE)
        val pixels = ByteArray(wide.cols() * wide.rows())
        wide.get(0, 0, pixels)

        val out = ByteArrayOutputStream()
        PdfWriter(out).use { pdf ->
            pdf.addPage(ScanEncoder.pdfImage(color, ColorMode.COLOR))
            pdf.addPage(ScanEncoder.pdfImage(gray, ColorMode.GRAYSCALE))
            pdf.addPage(ScanEncoder.pdfImage(wide, ColorMode.BLACK_WHITE))
            assertEquals(3, pdf.pageCount)
        }
        return out.toByteArray() to pixels
    }

    @Test
    fun `cross-reference table points at every object`() {
        val (pdf, _) = threePagePdf()
        val text = latin1(pdf)
        assertTrue(text.startsWith("%PDF-1.4\n"))
        assertTrue(text.endsWith("%%EOF\n"))

        val startXref = Regex("startxref\n(\\d+)\n%%EOF\n$").find(text)!!.groupValues[1].toInt()
        assertTrue(text.startsWith("xref\n", startXref))
        val header = Regex("xref\n0 (\\d+)\n").find(text, startXref)!!
        val size = header.groupValues[1].toInt()
        val entriesStart = header.range.last + 1
        for (n in 1 until size) {
            val entry = text.substring(entriesStart + n * 20, entriesStart + (n + 1) * 20)
            assertTrue("entry $n: '$entry'", entry.endsWith(" 00000 n \n"))
            val offset = entry.substring(0, 10).toInt()
            assertTrue("object $n at $offset", text.startsWith("$n 0 obj\n", offset))
        }
        assertTrue(text.contains("/Type /Pages /Kids [3 0 R 6 0 R 9 0 R] /Count 3"))
    }

    @Test
    fun `pages have the right size and image types`() {
        val (pdf, _) = threePagePdf()
        val text = latin1(pdf)
        // A4-shaped portrait image -> an A4 page; the rotated one -> landscape.
        assertTrue(text.contains("/MediaBox [0 0 595.28 841.89]"))
        assertTrue(text.contains("/MediaBox [0 0 841.89 595.28]"))
        assertTrue(text.contains("/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"))
        assertTrue(text.contains("/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode"))
        assertTrue(text.contains("/Width 594 /Height 420 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode"))
    }

    @Test
    fun `black and white pages are stored losslessly with one bit per pixel`() {
        val (pdf, pixels) = threePagePdf()
        val text = latin1(pdf)
        val dictionary = Regex("/BitsPerComponent 1 /Filter /FlateDecode /Length (\\d+) >>\nstream\n").find(text)!!
        val length = dictionary.groupValues[1].toInt()
        val start = dictionary.range.last + 1
        val packed = InflaterInputStream(pdf.copyOfRange(start, start + length).inputStream()).readBytes()

        val width = 594
        val height = 420
        val rowBytes = (width + 7) / 8
        assertEquals(rowBytes * height, packed.size)
        val unpacked = ByteArray(width * height) { i ->
            val x = i % width
            val bit = (packed[(i / width) * rowBytes + x / 8].toInt() shr (7 - x % 8)) and 1
            if (bit == 1) 255.toByte() else 0
        }
        assertArrayEquals(pixels.map { if (it == 0.toByte()) 0.toByte() else 255.toByte() }.toByteArray(), unpacked)
    }

    @Test
    fun `page size keeps the aspect ratio`() {
        val (w, h) = PdfWriter.pageSize(1000, 2000)
        assertEquals(PdfWriter.PAGE_LONG_SIDE, h, 1e-9)
        assertEquals(PdfWriter.PAGE_LONG_SIDE / 2, w, 1e-9)
    }
}
