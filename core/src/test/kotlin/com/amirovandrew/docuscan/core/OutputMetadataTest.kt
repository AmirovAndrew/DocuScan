package com.amirovandrew.docuscan.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.opencv.core.Mat
import org.opencv.core.Scalar
import org.opencv.imgproc.Imgproc
import java.io.ByteArrayOutputStream

/**
 * Saved and shared files must carry nothing but the picture: no EXIF (location, phone model,
 * time), no comments, no document properties. Everything the app writes comes from
 * [ScanEncoder] and [PdfWriter], so their output is checked byte by byte here.
 */
class OutputMetadataTest {

    companion object {
        @BeforeClass
        @JvmStatic
        fun loadOpenCv() = OpenCv.load()
    }

    private fun colourPage(): Mat = TestScenes.page(420, 594, Scalar(240.0, 230.0, 210.0, 255.0))

    private fun grayPage(): Mat = Mat().also { Imgproc.cvtColor(colourPage(), it, Imgproc.COLOR_RGBA2GRAY) }

    private fun blackWhitePage(): Mat =
        Mat().also { Imgproc.threshold(grayPage(), it, 128.0, 255.0, Imgproc.THRESH_BINARY) }

    /** Marker segments of a JPEG before the image data, as (marker byte, first bytes of the payload). */
    private fun jpegSegments(jpeg: ByteArray): List<Pair<Int, String>> {
        assertEquals("not a JPEG", 0xFFD8, ((jpeg[0].toInt() and 0xFF) shl 8) or (jpeg[1].toInt() and 0xFF))
        val segments = ArrayList<Pair<Int, String>>()
        var i = 2
        while (i + 4 <= jpeg.size) {
            assertEquals("marker expected at $i", 0xFF, jpeg[i].toInt() and 0xFF)
            val marker = jpeg[i + 1].toInt() and 0xFF
            val length = ((jpeg[i + 2].toInt() and 0xFF) shl 8) or (jpeg[i + 3].toInt() and 0xFF)
            val payload = String(jpeg, i + 4, minOf(length - 2, 12), Charsets.ISO_8859_1)
            segments += marker to payload
            if (marker == 0xDA) break // start of scan: compressed image data follows
            i += 2 + length
        }
        return segments
    }

    private fun assertNoJpegMetadata(jpeg: ByteArray) {
        val segments = jpegSegments(jpeg)
        assertTrue("no image data found", segments.any { it.first == 0xDA })
        for ((marker, payload) in segments) {
            when (marker) {
                0xE0 -> assertTrue("unexpected APP0 segment '$payload'", payload.startsWith("JFIF"))
                in 0xE1..0xEF -> throw AssertionError("application segment APP${marker - 0xE0} ('$payload'): EXIF, XMP, ICC, IPTC…")
                0xFE -> throw AssertionError("comment segment '$payload'")
            }
        }
    }

    private fun pngChunkTypes(png: ByteArray): List<String> {
        val signature = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10)
        assertTrue("not a PNG", png.copyOfRange(0, 8).contentEquals(signature))
        val types = ArrayList<String>()
        var i = 8
        while (i + 8 <= png.size) {
            val length = (0..3).fold(0) { acc, k -> (acc shl 8) or (png[i + k].toInt() and 0xFF) }
            types += String(png, i + 4, 4, Charsets.ISO_8859_1)
            i += 12 + length
        }
        return types
    }

    @Test
    fun `colour and grayscale JPEGs contain only the picture`() {
        assertNoJpegMetadata(ScanEncoder.encodeImage(colourPage(), ColorMode.COLOR).bytes)
        assertNoJpegMetadata(ScanEncoder.encodeImage(grayPage(), ColorMode.GRAYSCALE).bytes)
    }

    @Test
    fun `black and white PNG contains only the picture`() {
        val types = pngChunkTypes(ScanEncoder.encodeImage(blackWhitePage(), ColorMode.BLACK_WHITE).bytes)
        // No tEXt/zTXt/iTXt (text), tIME (time), eXIf, iCCP…
        assertEquals(setOf("IHDR", "IDAT", "IEND"), types.toSet())
        assertEquals("IHDR", types.first())
        assertEquals("IEND", types.last())
    }

    @Test
    fun `PDF has no document properties and its pictures no metadata`() {
        val out = ByteArrayOutputStream()
        PdfWriter(out).use { pdf ->
            pdf.addPage(ScanEncoder.pdfImage(colourPage(), ColorMode.COLOR))
            pdf.addPage(ScanEncoder.pdfImage(grayPage(), ColorMode.GRAYSCALE))
            pdf.addPage(ScanEncoder.pdfImage(blackWhitePage(), ColorMode.BLACK_WHITE))
        }
        val bytes = out.toByteArray()
        val text = String(bytes, Charsets.ISO_8859_1)
        val streams = Regex("/Length (\\d+) >>\nstream\n").findAll(text).toList()

        // The structure of the file without the (binary) contents of its streams.
        val structure = StringBuilder()
        var position = 0
        for (match in streams) {
            structure.append(text, position, match.range.last + 1)
            position = match.range.last + 1 + match.groupValues[1].toInt()
        }
        structure.append(text, position, text.length)

        // The information dictionary only names the producing app.
        assertTrue(structure.contains("<< /Producer (DocuScan) >>"))
        for (key in listOf(
            "/CreationDate", "/ModDate", "/Author", "/Title", "/Subject", "/Keywords", "/Creator",
            "/Metadata", // XMP packet
            "/JavaScript", "/JS", "/OpenAction", "/AA", "/EmbeddedFile", "/URI", "/Launch",
        )) {
            assertFalse("PDF contains $key", Regex(Regex.escape(key) + "\\b").containsMatchIn(structure))
        }

        // The embedded JPEGs are complete files: check each of them as well.
        val jpegStreams = Regex("/Filter /DCTDecode /Length (\\d+) >>\nstream\n").findAll(text).toList()
        assertEquals(2, jpegStreams.size)
        for (match in jpegStreams) {
            val start = match.range.last + 1
            assertNoJpegMetadata(bytes.copyOfRange(start, start + match.groupValues[1].toInt()))
        }
    }

    @Test
    fun `the JPEG check itself notices EXIF and comments`() {
        val clean = ScanEncoder.encodeImage(colourPage(), ColorMode.COLOR).bytes
        fun withSegment(marker: Int, payload: ByteArray): ByteArray {
            val length = payload.size + 2
            val segment = byteArrayOf(0xFF.toByte(), marker.toByte(), (length shr 8).toByte(), length.toByte()) + payload
            return clean.copyOfRange(0, 2) + segment + clean.copyOfRange(2, clean.size)
        }
        for (dirty in listOf(
            withSegment(0xE1, "Exif\u0000\u0000MM".toByteArray(Charsets.ISO_8859_1)),
            withSegment(0xFE, "made on a phone".toByteArray(Charsets.ISO_8859_1)),
        )) {
            val failed = runCatching { assertNoJpegMetadata(dirty) }.exceptionOrNull() is AssertionError
            assertTrue("metadata was not noticed", failed)
        }
    }
}
