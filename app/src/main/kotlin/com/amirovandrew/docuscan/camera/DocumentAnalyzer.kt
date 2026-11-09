package com.amirovandrew.docuscan.camera

import android.graphics.Matrix
import android.util.Log
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.compose.ui.geometry.Offset
import com.amirovandrew.docuscan.core.DocumentDetector
import com.amirovandrew.docuscan.core.Quad
import com.amirovandrew.docuscan.core.Vec2
import org.opencv.core.CvType
import org.opencv.core.Mat

/**
 * Looks for a document in camera frames and reports its outline in preview (view) coordinates.
 *
 * CameraX calls [updateTransform] with the sensor-to-view matrix because the analyzer asks for
 * [ImageAnalysis.COORDINATE_SYSTEM_VIEW_REFERENCED]; frames are analysed in their native
 * orientation. Frames must be RGBA ([ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888]).
 */
class DocumentAnalyzer(
    private val onOutline: (List<Offset>?) -> Unit,
) : ImageAnalysis.Analyzer {

    @Volatile
    private var sensorToView: Matrix? = null

    private var pixels = ByteArray(0)
    private var frame: Mat? = null
    private var smoothed: FloatArray? = null
    private var misses = 0

    override fun getTargetCoordinateSystem(): Int = ImageAnalysis.COORDINATE_SYSTEM_VIEW_REFERENCED

    override fun updateTransform(matrix: Matrix?) {
        sensorToView = matrix?.let(::Matrix)
    }

    override fun analyze(image: ImageProxy) {
        image.use {
            val transform = sensorToView ?: return
            val quad = try {
                detect(image)
            } catch (e: Exception) {
                Log.w("DocuScan", "Detection failed", e)
                null
            }
            if (quad == null) {
                // Keep the outline for a few frames to avoid flicker.
                if (++misses >= MAX_MISSES && smoothed != null) {
                    smoothed = null
                    onOutline(null)
                }
                return
            }
            misses = 0

            val bufferToView = Matrix()
            image.imageInfo.sensorToBufferTransformMatrix.invert(bufferToView)
            bufferToView.postConcat(transform)
            val points = FloatArray(8)
            quad.corners.forEachIndexed { i, p ->
                points[2 * i] = p.x.toFloat()
                points[2 * i + 1] = p.y.toFloat()
            }
            bufferToView.mapPoints(points)

            // Re-order on screen so that corners match between frames for smoothing.
            val ordered = Quad.fromPoints((0..3).map { Vec2(points[2 * it].toDouble(), points[2 * it + 1].toDouble()) })
            val target = FloatArray(8)
            ordered.corners.forEachIndexed { i, p ->
                target[2 * i] = p.x.toFloat()
                target[2 * i + 1] = p.y.toFloat()
            }
            val previous = smoothed
            val next = if (previous == null) target else FloatArray(8) { previous[it] + (target[it] - previous[it]) * SMOOTHING }
            smoothed = next
            onOutline((0..3).map { Offset(next[2 * it], next[2 * it + 1]) })
        }
    }

    private fun detect(image: ImageProxy): Quad? {
        val plane = image.planes[0]
        val width = image.width
        val height = image.height
        val rowBytes = width * BYTES_PER_PIXEL
        val rowStride = plane.rowStride
        val buffer = plane.buffer
        buffer.rewind()
        if (pixels.size != rowBytes * height) pixels = ByteArray(rowBytes * height)
        if (rowStride == rowBytes) {
            buffer.get(pixels, 0, rowBytes * height)
        } else {
            for (row in 0 until height) {
                buffer.position(row * rowStride)
                buffer.get(pixels, row * rowBytes, rowBytes)
            }
        }
        val mat = frame?.takeIf { it.cols() == width && it.rows() == height }
            ?: Mat(height, width, CvType.CV_8UC4).also {
                frame?.release()
                frame = it
            }
        mat.put(0, 0, pixels)
        return DocumentDetector.detect(mat, LIVE_MIN_AREA)
    }

    /** Frees native memory. Call on the analysis thread once the analyzer is no longer used. */
    fun release() {
        frame?.release()
        frame = null
    }

    private companion object {
        const val MAX_MISSES = 4
        const val SMOOTHING = 0.5f
        const val LIVE_MIN_AREA = 0.12
        const val BYTES_PER_PIXEL = 4
    }
}
