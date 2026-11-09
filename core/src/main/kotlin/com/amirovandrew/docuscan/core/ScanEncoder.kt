package com.amirovandrew.docuscan.core

import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.core.MatOfInt
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc

enum class ImageFormat(val mimeType: String, val extension: String) {
    JPEG("image/jpeg", "jpg"),
    PNG("image/png", "png"),
}

class EncodedImage(val bytes: ByteArray, val format: ImageFormat)

/** Encodes rendered pages (output of [DocumentProcessor.render]) for saving. */
object ScanEncoder {

    const val PHOTO_JPEG_QUALITY = 92
    const val PDF_JPEG_QUALITY = 85

    /** File format for a page in [mode]: lossless PNG for black & white, JPEG otherwise. */
    fun formatFor(mode: ColorMode): ImageFormat =
        if (mode == ColorMode.BLACK_WHITE) ImageFormat.PNG else ImageFormat.JPEG

    /**
     * Encodes a rendered page as an image file. Black & white pages become 1-bit PNGs: crisp and
     * small. Grayscale pages become single-channel JPEGs.
     */
    fun encodeImage(rendered: Mat, mode: ColorMode, jpegQuality: Int = PHOTO_JPEG_QUALITY): EncodedImage {
        val format = formatFor(mode)
        val bytes = if (format == ImageFormat.PNG) {
            encode(rendered, ".png", Imgcodecs.IMWRITE_PNG_BILEVEL, 1)
        } else {
            jpeg(rendered, jpegQuality)
        }
        return EncodedImage(bytes, format)
    }

    /** Prepares a rendered page for [PdfWriter]. */
    fun pdfImage(rendered: Mat, mode: ColorMode, jpegQuality: Int = PDF_JPEG_QUALITY): PdfImage {
        val width = rendered.cols()
        val height = rendered.rows()
        return if (mode == ColorMode.BLACK_WHITE) {
            require(rendered.type() == CvType.CV_8UC1) { "Black & white page must be single-channel" }
            val pixels = ByteArray(width * height)
            rendered.get(0, 0, pixels)
            PdfImage.bilevel(pixels, width, height)
        } else {
            PdfImage.jpeg(jpeg(rendered, jpegQuality), width, height, gray = rendered.channels() == 1)
        }
    }

    /** JPEG of a gray, RGB or RGBA image (red first, as everywhere in this module). */
    private fun jpeg(image: Mat, quality: Int): ByteArray = matScope {
        val source = when (image.channels()) {
            1 -> image
            3 -> mat().also { Imgproc.cvtColor(image, it, Imgproc.COLOR_RGB2BGR) }
            4 -> mat().also { Imgproc.cvtColor(image, it, Imgproc.COLOR_RGBA2BGR) }
            else -> throw IllegalArgumentException("Unsupported channel count ${image.channels()}")
        }
        encode(source, ".jpg", Imgcodecs.IMWRITE_JPEG_QUALITY, quality)
    }

    private fun encode(image: Mat, extension: String, flag: Int, value: Int): ByteArray {
        val buffer = MatOfByte()
        val params = MatOfInt(flag, value)
        try {
            check(Imgcodecs.imencode(extension, image, buffer, params)) { "Unable to encode $extension" }
            return buffer.toArray()
        } finally {
            buffer.release()
            params.release()
        }
    }
}
