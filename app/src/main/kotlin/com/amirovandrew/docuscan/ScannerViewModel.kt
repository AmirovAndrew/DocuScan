package com.amirovandrew.docuscan

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.amirovandrew.docuscan.core.Adjustments
import com.amirovandrew.docuscan.core.ChannelGains
import com.amirovandrew.docuscan.core.DocumentDetector
import com.amirovandrew.docuscan.core.DocumentProcessor
import com.amirovandrew.docuscan.core.Quad
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.opencv.core.Mat
import java.io.File

enum class Screen { CAMERA, CROP, EDIT }

data class ScannerUiState(
    val screen: Screen = Screen.CAMERA,
    val busy: Boolean = false,
    /** Downscaled photo shown on the crop screen. */
    val photo: ImageBitmap? = null,
    /** Document corners in normalized photo coordinates (0..1). */
    val cropQuad: Quad = Quad.UNIT,
    /** What the detector found, null if nothing. */
    val detectedQuad: Quad? = null,
    /** Rendered page shown on the edit screen. */
    val preview: ImageBitmap? = null,
    val adjustments: Adjustments = Adjustments(),
)

sealed interface ScannerEvent {
    data class Saved(val uri: Uri) : ScannerEvent
    data object DocumentNotFound : ScannerEvent
    data object CaptureFailed : ScannerEvent
    data object OpenFailed : ScannerEvent
    data object SaveFailed : ScannerEvent
}

class ScannerViewModel(application: Application) : AndroidViewModel(application) {

    /** All OpenCV work runs here, one task at a time, so native images are never used concurrently. */
    private val processing = Dispatchers.Default.limitedParallelism(1)
    private val cleanupScope = CoroutineScope(SupervisorJob() + processing)
    private val preferences = ScanPreferences(application)

    private val _state = MutableStateFlow(ScannerUiState(adjustments = preferences.load()))
    val state: StateFlow<ScannerUiState> = _state.asStateFlow()

    private val _events = Channel<ScannerEvent>(Channel.BUFFERED)
    val events: Flow<ScannerEvent> = _events.receiveAsFlow()

    // Native images, only touched on [processing].
    private var photo: Mat? = null
    private var page: Mat? = null
    private var pagePreview: Mat? = null
    private var autoGains = ChannelGains.NEUTRAL

    private var previewJob: Job? = null

    fun onPhotoCaptured(file: File) = openImage {
        try {
            ImageIo.decodeFile(file)
        } finally {
            file.delete()
        }
    }

    fun onImagePicked(uri: Uri) = openImage { ImageIo.decodeUri(getApplication(), uri) }

    fun onCaptureFailed() {
        viewModelScope.launch { _events.send(ScannerEvent.CaptureFailed) }
    }

    private fun openImage(decode: () -> Bitmap) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true) }
        viewModelScope.launch {
            val result = withContext(processing) {
                runCatching {
                    releasePage()
                    releasePhoto()
                    val bitmap = decode()
                    val mat = ImageIo.toRgbaMat(bitmap)
                    photo = mat
                    val display = ImageIo.scaleDown(bitmap, DISPLAY_MAX_SIDE)
                    if (display !== bitmap) bitmap.recycle()
                    val quad = DocumentDetector.detect(mat)
                        ?.scale(1.0 / mat.cols(), 1.0 / mat.rows())
                    display to quad
                }
            }
            result.onSuccess { (display, quad) ->
                _state.update {
                    it.copy(
                        busy = false,
                        screen = Screen.CROP,
                        photo = display.asImageBitmap(),
                        detectedQuad = quad,
                        cropQuad = quad ?: Quad.UNIT,
                        preview = null,
                        adjustments = preferences.load(),
                    )
                }
                if (quad == null) _events.send(ScannerEvent.DocumentNotFound)
            }.onFailure { error ->
                Log.e(TAG, "Unable to open image", error)
                _state.update { it.copy(busy = false) }
                _events.send(ScannerEvent.OpenFailed)
            }
        }
    }

    fun onCropChanged(quad: Quad) = _state.update { it.copy(cropQuad = quad) }

    fun useDetectedCrop() = _state.update { s -> s.detectedQuad?.let { s.copy(cropQuad = it) } ?: s }

    fun useFullImage() = _state.update { it.copy(cropQuad = Quad.UNIT) }

    fun confirmCrop() {
        if (_state.value.busy) return
        val quad = _state.value.cropQuad
        _state.update { it.copy(busy = true) }
        viewModelScope.launch {
            val ok = withContext(processing) {
                runCatching {
                    val source = checkNotNull(photo) { "No photo" }
                    releasePage()
                    val corners = quad.scale(source.cols().toDouble(), source.rows().toDouble()).normalized()
                    val flat = DocumentProcessor.warp(source, corners)
                    page = flat
                    pagePreview = DocumentProcessor.downscale(flat, PREVIEW_MAX_SIDE)
                    autoGains = DocumentProcessor.estimateAutoGains(flat)
                }.onFailure { Log.e(TAG, "Unable to flatten the page", it) }.isSuccess
            }
            if (ok) {
                _state.update { it.copy(busy = false, screen = Screen.EDIT, preview = null) }
                renderPreview()
            } else {
                _state.update { it.copy(busy = false) }
                _events.send(ScannerEvent.OpenFailed)
            }
        }
    }

    fun updateAdjustments(change: (Adjustments) -> Adjustments) {
        _state.update { it.copy(adjustments = change(it.adjustments)) }
        renderPreview()
    }

    /** Re-renders the downscaled page; a newer request cancels one that has not started yet. */
    private fun renderPreview() {
        val adjustments = _state.value.adjustments
        previewJob?.cancel()
        previewJob = viewModelScope.launch {
            val bitmap = withContext(processing) {
                val source = pagePreview ?: return@withContext null
                runCatching {
                    val rendered = DocumentProcessor.render(source, adjustments, autoGains)
                    try {
                        ImageIo.toBitmap(rendered)
                    } finally {
                        rendered.release()
                    }
                }.onFailure { Log.e(TAG, "Unable to render preview", it) }.getOrNull()
            } ?: return@launch
            _state.update { it.copy(preview = bitmap.asImageBitmap()) }
        }
    }

    fun save() {
        if (_state.value.busy) return
        val adjustments = _state.value.adjustments
        _state.update { it.copy(busy = true) }
        viewModelScope.launch {
            val result = withContext(processing) {
                runCatching {
                    val source = checkNotNull(page) { "No page" }
                    val rendered = DocumentProcessor.render(source, adjustments, autoGains)
                    val bitmap = try {
                        ImageIo.toBitmap(rendered)
                    } finally {
                        rendered.release()
                    }
                    try {
                        ImageIo.saveToGallery(getApplication(), bitmap)
                    } finally {
                        bitmap.recycle()
                    }
                }
            }
            result.onSuccess { uri ->
                preferences.save(adjustments)
                previewJob?.cancel()
                withContext(processing) {
                    releasePage()
                    releasePhoto()
                }
                _state.value = ScannerUiState(adjustments = preferences.load())
                _events.send(ScannerEvent.Saved(uri))
            }.onFailure { error ->
                Log.e(TAG, "Unable to save", error)
                _state.update { it.copy(busy = false) }
                _events.send(ScannerEvent.SaveFailed)
            }
        }
    }

    fun backToCamera() {
        previewJob?.cancel()
        _state.value = ScannerUiState(adjustments = preferences.load())
        cleanupScope.launch {
            releasePage()
            releasePhoto()
        }
    }

    fun backToCrop() {
        previewJob?.cancel()
        _state.update { it.copy(screen = Screen.CROP, preview = null) }
        cleanupScope.launch { releasePage() }
    }

    override fun onCleared() {
        cleanupScope.launch {
            releasePage()
            releasePhoto()
        }
    }

    private fun releasePhoto() {
        photo?.release()
        photo = null
    }

    private fun releasePage() {
        page?.release()
        pagePreview?.release()
        page = null
        pagePreview = null
        autoGains = ChannelGains.NEUTRAL
    }

    private companion object {
        const val TAG = "DocuScan"

        /** Larger bitmaps may exceed the GPU texture limit on older phones. */
        const val DISPLAY_MAX_SIDE = 2048
        const val PREVIEW_MAX_SIDE = 1600
    }
}
