package com.amirovandrew.docuscan

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.graphics.createBitmap
import androidx.core.graphics.scale
import androidx.exifinterface.media.ExifInterface
import org.opencv.android.Utils
import org.opencv.core.Mat
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import kotlin.math.max
import kotlin.math.roundToInt

object ImageIo {

    /** Photos are scaled down to this size: plenty for a page and keeps memory use in check. */
    const val MAX_PHOTO_SIDE = 4000

    private const val ALBUM = "DocuScan"

    fun decodeFile(file: File): Bitmap = decode { FileInputStream(file) }

    /** Decodes an image, scaled down to [MAX_PHOTO_SIDE] and rotated upright according to EXIF. */
    private fun decode(open: () -> InputStream): Bitmap {
        val orientation = runCatching {
            open().use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        open().use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IOException("Not an image")

        var sampleSize = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sampleSize * 2) >= MAX_PHOTO_SIDE) sampleSize *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = open().use { BitmapFactory.decodeStream(it, null, options) }
            ?: throw IOException("Unable to decode image")
        val scaled = scaleDown(decoded, MAX_PHOTO_SIDE).also { if (it !== decoded) decoded.recycle() }
        return applyOrientation(scaled, orientation)
    }

    /** Returns [bitmap] itself if it is small enough, otherwise a scaled-down copy. */
    fun scaleDown(bitmap: Bitmap, maxSide: Int): Bitmap {
        val longest = max(bitmap.width, bitmap.height)
        if (longest <= maxSide) return bitmap
        val k = maxSide.toFloat() / longest
        return bitmap.scale(
            (bitmap.width * k).roundToInt().coerceAtLeast(1),
            (bitmap.height * k).roundToInt().coerceAtLeast(1),
        )
    }

    private fun applyOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setRotate(180f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return bitmap
        }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }

    /** RGBA [Mat] with the pixels of [bitmap]. */
    fun toRgbaMat(bitmap: Bitmap): Mat {
        val source = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
        val mat = Mat()
        Utils.bitmapToMat(source, mat)
        if (source !== bitmap) source.recycle()
        return mat
    }

    /** Converts a gray, RGB or RGBA [Mat] to a bitmap. */
    fun toBitmap(mat: Mat): Bitmap {
        val bitmap = createBitmap(mat.cols(), mat.rows())
        Utils.matToBitmap(mat, bitmap)
        return bitmap
    }

    /** Copies the image behind [uri] (e.g. from the photo picker) into [file]. */
    fun copy(context: Context, uri: Uri, file: File) {
        val input = context.contentResolver.openInputStream(uri) ?: throw FileNotFoundException(uri.toString())
        input.use { source -> FileOutputStream(file).use { source.copyTo(it) } }
    }

    enum class Folder { PICTURES, DOWNLOADS }

    /**
     * Creates [fileName] in the DocuScan folder of Pictures or Download, where the gallery and file
     * managers see it, and lets [write] fill it. A half-written file is removed on failure.
     */
    fun save(context: Context, fileName: String, mimeType: String, folder: Folder, write: (OutputStream) -> Unit): Uri {
        val directory = when (folder) {
            Folder.PICTURES -> Environment.DIRECTORY_PICTURES
            Folder.DOWNLOADS -> Environment.DIRECTORY_DOWNLOADS
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val collection = when (folder) {
                Folder.PICTURES -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                Folder.DOWNLOADS -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$directory/$ALBUM")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values) ?: throw IOException("Unable to create $fileName")
            try {
                val stream = resolver.openOutputStream(uri) ?: throw IOException("Unable to open $uri")
                stream.use(write)
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return uri
        }

        @Suppress("DEPRECATION")
        val target = File(Environment.getExternalStoragePublicDirectory(directory), ALBUM)
        if (!target.isDirectory && !target.mkdirs()) throw IOException("Unable to create $target")
        val file = File(target, fileName)
        try {
            FileOutputStream(file).use(write)
        } catch (e: Exception) {
            file.delete()
            throw e
        }
        MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf(mimeType), null)
        return Uri.fromFile(file)
    }
}
