package com.amirovandrew.docuscan.core

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.FilterOutputStream
import java.io.OutputStream
import java.util.Locale
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import kotlin.math.max

/** A page image ready to be embedded in a PDF. */
class PdfImage private constructor(
    val width: Int,
    val height: Int,
    internal val colorSpace: String,
    internal val bitsPerComponent: Int,
    internal val filter: String,
    internal val data: ByteArray,
) {
    companion object {
        /** A JPEG file, embedded as is. */
        fun jpeg(bytes: ByteArray, width: Int, height: Int, gray: Boolean) = PdfImage(
            width, height, if (gray) "/DeviceGray" else "/DeviceRGB", 8, "/DCTDecode", bytes,
        )

        /**
         * A black & white image stored with 1 bit per pixel.
         *
         * @param pixels one byte per pixel, row by row: 0 is black, anything else white.
         */
        fun bilevel(pixels: ByteArray, width: Int, height: Int): PdfImage {
            require(pixels.size == width * height) { "Expected ${width * height} pixels, got ${pixels.size}" }
            val rowBytes = (width + 7) / 8
            val packed = ByteArray(rowBytes * height)
            for (y in 0 until height) {
                val row = y * width
                val out = y * rowBytes
                for (x in 0 until width) {
                    // In DeviceGray a 1 bit is white.
                    if (pixels[row + x] != 0.toByte()) {
                        packed[out + (x shr 3)] = (packed[out + (x shr 3)].toInt() or (0x80 ushr (x and 7))).toByte()
                    }
                }
            }
            val compressed = ByteArrayOutputStream(packed.size / 8 + 64)
            DeflaterOutputStream(compressed, Deflater(Deflater.BEST_COMPRESSION)).use { it.write(packed) }
            return PdfImage(width, height, "/DeviceGray", 1, "/FlateDecode", compressed.toByteArray())
        }
    }
}

/**
 * Writes a PDF with one full-page image per page, straight to [output].
 *
 * Pages keep the aspect ratio of their image; the long side is as long as that of an A4 sheet,
 * so an A4 document prints at its real size. Call [close] to finish the file (the stream itself is
 * flushed but not closed).
 */
class PdfWriter(output: OutputStream) : Closeable {

    private val out = CountingStream(output.buffered())
    /** Byte offset of every object, by object number. Objects 1 and 2 are written last. */
    private val offsets = HashMap<Int, Long>()
    private val pages = ArrayList<Int>()
    private var nextObject = 3
    private var closed = false

    init {
        write("%PDF-1.4\n")
        // A comment with high-bit bytes marks the file as binary for transfer tools.
        out.write(byteArrayOf('%'.code.toByte(), 0xE2.toByte(), 0xE3.toByte(), 0xCF.toByte(), 0xD3.toByte(), '\n'.code.toByte()))
    }

    val pageCount: Int get() = pages.size

    fun addPage(image: PdfImage) {
        check(!closed) { "Already closed" }
        val pageObject = nextObject++
        val contentObject = nextObject++
        val imageObject = nextObject++
        val (pageWidth, pageHeight) = pageSize(image.width, image.height)

        beginObject(imageObject)
        write(
            "<< /Type /XObject /Subtype /Image /Width ${image.width} /Height ${image.height} " +
                "/ColorSpace ${image.colorSpace} /BitsPerComponent ${image.bitsPerComponent} " +
                "/Filter ${image.filter} /Length ${image.data.size} >>\nstream\n",
        )
        out.write(image.data)
        write("\nendstream\nendobj\n")

        val content = "q ${number(pageWidth)} 0 0 ${number(pageHeight)} 0 0 cm /Im0 Do Q".toByteArray(Charsets.US_ASCII)
        beginObject(contentObject)
        write("<< /Length ${content.size} >>\nstream\n")
        out.write(content)
        write("\nendstream\nendobj\n")

        beginObject(pageObject)
        write(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${number(pageWidth)} ${number(pageHeight)}] " +
                "/Resources << /XObject << /Im0 $imageObject 0 R >> >> /Contents $contentObject 0 R >>\nendobj\n",
        )
        pages += pageObject
    }

    override fun close() {
        if (closed) return
        closed = true
        beginObject(1)
        write("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        beginObject(2)
        write("<< /Type /Pages /Kids [${pages.joinToString(" ") { "$it 0 R" }}] /Count ${pages.size} >>\nendobj\n")
        val infoObject = nextObject++
        beginObject(infoObject)
        write("<< /Producer (DocuScan) >>\nendobj\n")

        val xref = out.count
        write("xref\n0 $nextObject\n0000000000 65535 f \n")
        for (number in 1 until nextObject) {
            write(String.format(Locale.US, "%010d 00000 n \n", offsets.getValue(number)))
        }
        write("trailer\n<< /Size $nextObject /Root 1 0 R /Info $infoObject 0 R >>\nstartxref\n$xref\n%%EOF\n")
        out.flush()
    }

    private fun beginObject(number: Int) {
        offsets[number] = out.count
        write("$number 0 obj\n")
    }

    private fun write(text: String) = out.write(text.toByteArray(Charsets.US_ASCII))

    private class CountingStream(stream: OutputStream) : FilterOutputStream(stream) {
        var count = 0L
            private set

        override fun write(b: Int) {
            out.write(b)
            count++
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            out.write(b, off, len)
            count += len
        }
    }

    companion object {
        /** Long side of an A4 sheet in points. */
        const val PAGE_LONG_SIDE = 841.89

        /** Page size in points for an image of the given size. */
        fun pageSize(width: Int, height: Int): Pair<Double, Double> {
            val k = PAGE_LONG_SIDE / max(width, height)
            return width * k to height * k
        }

        private fun number(value: Double) = String.format(Locale.US, "%.2f", value)
    }
}
