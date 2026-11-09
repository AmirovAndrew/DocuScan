package com.amirovandrew.docuscan

import android.app.Application
import android.net.Uri
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.amirovandrew.docuscan.core.Adjustments
import com.amirovandrew.docuscan.core.ChannelGains
import com.amirovandrew.docuscan.core.DocumentDetector
import com.amirovandrew.docuscan.core.DocumentProcessor
import com.amirovandrew.docuscan.core.EncodedImage
import com.amirovandrew.docuscan.core.PdfWriter
import com.amirovandrew.docuscan.core.Quad
import com.amirovandrew.docuscan.core.ScanEncoder
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
import java.io.FileOutputStream
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

enum class Screen { CAMERA, CROP, EDIT, PAGES }

/** A page of the document being scanned. */
data class ScanPage(
    val id: Long,
    /** The original photo, kept so that the page can be cropped and adjusted again. */
    val photo: File,
    /** Document corners in normalized (0..1) photo coordinates. */
    val crop: Quad,
    val adjustments: Adjustments,
    val thumbnail: ImageBitmap,
)

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
    /** Pages of the document, in order. */
    val pages: List<ScanPage> = emptyList(),
    /** The page being cropped/adjusted again; null while scanning a new page. */
    val editingPageId: Long? = null,
)

sealed interface ScannerEvent {
    data object SavedImages : ScannerEvent
    data object SavedPdf : ScannerEvent
    data object DocumentNotFound : ScannerEvent
    data object CaptureFailed : ScannerEvent
    data object OpenFailed : ScannerEvent
    data object SaveFailed : ScannerEvent

    /** Offer [uris] (all of [mimeType]) to other apps. */
    data class Share(val uris: List<Uri>, val mimeType: String) : ScannerEvent
    data object ShareFailed : ScannerEvent
}

class ScannerViewModel(application: Application) : AndroidViewModel(application) {

    /** All OpenCV work runs here, one task at a time, so native images are never used concurrently. */
    private val processing = Dispatchers.Default.limitedParallelism(1)
    private val cleanupScope = CoroutineScope(SupervisorJob() + processing)
    private val preferences = ScanPreferences(application)

    /** Photos of the pages. Only valid while the app runs, so leftovers are removed at start. */
    private val scanDirectory = File(application.cacheDir, "scan").apply {
        deleteRecursively()
        mkdirs()
    }

    /** Files handed to other apps; shared through the FileProvider (see res/xml/file_paths.xml). */
    private val shareDirectory = File(application.cacheDir, "share").apply { deleteRecursively() }

    private val _state = MutableStateFlow(ScannerUiState(adjustments = preferences.load()))
    val state: StateFlow<ScannerUiState> = _state.asStateFlow()

    private val _events = Channel<ScannerEvent>(Channel.BUFFERED)
    val events: Flow<ScannerEvent> = _events.receiveAsFlow()

    /** Photo of the page on the crop and edit screens. */
    private var photoFile: File? = null

    // Native images of that page, only touched on [processing].
    private var photo: Mat? = null
    private var page: Mat? = null
    private var pagePreview: Mat? = null
    private var autoGains = ChannelGains.NEUTRAL

    private var previewJob: Job? = null
    private var nextPageId = 1L

    /** A file for the camera to store the next photo in. */
    fun newPhotoFile(): File {
        scanDirectory.mkdirs()
        return File(scanDirectory, "photo_${System.nanoTime()}.jpg")
    }

    fun onPhotoCaptured(file: File) = runBusy { openNewPhoto(file) }

    fun onImagePicked(uri: Uri) = runBusy {
        val file = newPhotoFile()
        val copied = withContext(Dispatchers.IO) {
            runCatching { ImageIo.copy(getApplication(), uri, file) }
                .onFailure { Log.e(TAG, "Unable to copy $uri", it) }
                .isSuccess
        }
        if (copied) {
            openNewPhoto(file)
        } else {
            file.delete()
            _events.send(ScannerEvent.OpenFailed)
        }
    }

    fun onCaptureFailed() {
        viewModelScope.launch { _events.send(ScannerEvent.CaptureFailed) }
    }

    private suspend fun openNewPhoto(file: File) {
        val loaded = withContext(processing) { runCatching { loadPhoto(file) } }
        loaded.onSuccess { (display, detected) ->
            photoFile = file
            _state.update {
                it.copy(
                    screen = Screen.CROP,
                    photo = display,
                    detectedQuad = detected,
                    cropQuad = detected ?: Quad.UNIT,
                    preview = null,
                    adjustments = preferences.load(),
                    editingPageId = null,
                )
            }
            if (detected == null) _events.send(ScannerEvent.DocumentNotFound)
        }.onFailure { error ->
            Log.e(TAG, "Unable to open image", error)
            file.delete()
            _events.send(ScannerEvent.OpenFailed)
        }
    }

    /** Decodes [file] into [photo]. Returns the photo for display and the detected document. */
    private fun loadPhoto(file: File): Pair<ImageBitmap, Quad?> {
        releasePage()
        releasePhoto()
        val bitmap = ImageIo.decodeFile(file)
        val mat = ImageIo.toRgbaMat(bitmap)
        photo = mat
        val display = ImageIo.scaleDown(bitmap, DISPLAY_MAX_SIDE)
        if (display !== bitmap) bitmap.recycle()
        val detected = DocumentDetector.detect(mat)?.scale(1.0 / mat.cols(), 1.0 / mat.rows())
        return display.asImageBitmap() to detected
    }

    fun onCropChanged(quad: Quad) = _state.update { it.copy(cropQuad = quad) }

    fun useDetectedCrop() = _state.update { s -> s.detectedQuad?.let { s.copy(cropQuad = it) } ?: s }

    fun useFullImage() = _state.update { it.copy(cropQuad = Quad.UNIT) }

    fun confirmCrop() = runBusy {
        val quad = _state.value.cropQuad
        val ok = withContext(processing) {
            runCatching { preparePage(quad) }.onFailure { Log.e(TAG, "Unable to flatten the page", it) }.isSuccess
        }
        if (ok) {
            _state.update { it.copy(screen = Screen.EDIT, preview = null) }
            renderPreview()
        } else {
            _events.send(ScannerEvent.OpenFailed)
        }
    }

    /** Flattens the current photo along [quad] (normalized). */
    private fun preparePage(quad: Quad) {
        val source = checkNotNull(photo) { "No photo" }
        releasePage()
        val flat = DocumentProcessor.warp(source, quad.toPixels(source))
        page = flat
        pagePreview = DocumentProcessor.downscale(flat, PREVIEW_MAX_SIDE)
        autoGains = DocumentProcessor.estimateAutoGains(flat)
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
                runCatching { renderBitmap(source, adjustments) }
                    .onFailure { Log.e(TAG, "Unable to render preview", it) }
                    .getOrNull()
            } ?: return@launch
            _state.update { it.copy(preview = bitmap) }
        }
    }

    private fun renderBitmap(source: Mat, adjustments: Adjustments): ImageBitmap {
        val rendered = DocumentProcessor.render(source, adjustments, autoGains)
        try {
            return ImageIo.toBitmap(rendered).asImageBitmap()
        } finally {
            rendered.release()
        }
    }

    /** "Done" on the edit screen: adds the page to the document, or updates the page being edited. */
    fun finishPage() = runBusy {
        val current = _state.value
        val file = photoFile ?: return@runBusy
        val thumbnail = withContext(processing) {
            runCatching {
                val small = DocumentProcessor.downscale(checkNotNull(pagePreview), THUMBNAIL_MAX_SIDE)
                try {
                    renderBitmap(small, current.adjustments)
                } finally {
                    small.release()
                }
            }.onFailure { Log.e(TAG, "Unable to render thumbnail", it) }.getOrNull()
        }
        if (thumbnail == null) {
            _events.send(ScannerEvent.SaveFailed)
            return@runBusy
        }

        val id = current.editingPageId ?: nextPageId++
        val newPage = ScanPage(id, file, current.cropQuad, current.adjustments, thumbnail)
        val pages = if (current.editingPageId != null) {
            current.pages.map { if (it.id == id) newPage else it }
        } else {
            current.pages + newPage
        }
        preferences.save(current.adjustments)
        closePage()
        _state.update { it.copy(screen = Screen.PAGES, pages = pages, editingPageId = null) }
    }

    /** Opens a page of the document on the edit screen again. */
    fun editPage(id: Long) = runBusy {
        val target = _state.value.pages.firstOrNull { it.id == id } ?: return@runBusy
        val loaded = withContext(processing) {
            runCatching {
                val (display, detected) = loadPhoto(target.photo)
                preparePage(target.crop)
                display to detected
            }
        }
        loaded.onSuccess { (display, detected) ->
            photoFile = target.photo
            _state.update {
                it.copy(
                    screen = Screen.EDIT,
                    photo = display,
                    detectedQuad = detected,
                    cropQuad = target.crop,
                    adjustments = target.adjustments,
                    preview = null,
                    editingPageId = id,
                )
            }
            renderPreview()
        }.onFailure { error ->
            Log.e(TAG, "Unable to open page", error)
            _events.send(ScannerEvent.OpenFailed)
        }
    }

    /** Back from the crop screen: drops a new photo, or returns to the document when re-editing. */
    fun backFromCrop() {
        if (_state.value.busy) return
        val editing = _state.value.editingPageId != null
        val file = photoFile
        closePage()
        if (!editing && file != null) cleanupScope.launch { file.delete() }
        _state.update {
            it.copy(screen = if (editing) Screen.PAGES else Screen.CAMERA, editingPageId = null)
        }
    }

    fun backFromEdit() {
        if (_state.value.busy) return
        previewJob?.cancel()
        _state.update { it.copy(screen = Screen.CROP, preview = null) }
        cleanupScope.launch { releasePage() }
    }

    fun openPages() = _state.update { it.copy(screen = Screen.PAGES) }

    fun addPage() = _state.update { it.copy(screen = Screen.CAMERA) }

    /** Moves a page [delta] positions forward (+1) or back (-1). */
    fun movePage(id: Long, delta: Int) = _state.update { s ->
        val from = s.pages.indexOfFirst { it.id == id }
        val to = from + delta
        if (from < 0 || to !in s.pages.indices) return@update s
        val pages = s.pages.toMutableList()
        pages.add(to, pages.removeAt(from))
        s.copy(pages = pages)
    }

    fun deletePage(id: Long) {
        val removed = _state.value.pages.firstOrNull { it.id == id } ?: return
        _state.update { s -> s.copy(pages = s.pages.filter { it.id != id }) }
        cleanupScope.launch { removed.photo.delete() }
    }

    /** Drops all pages without saving. */
    fun discardDocument() {
        if (_state.value.busy) return
        val files = _state.value.pages.map { it.photo }
        _state.update { it.copy(screen = Screen.CAMERA, pages = emptyList()) }
        cleanupScope.launch { files.forEach { it.delete() } }
    }

    fun saveAsImages() = save(asPdf = false)

    fun saveAsPdf() = save(asPdf = true)

    private fun save(asPdf: Boolean) = runBusy {
        val pages = _state.value.pages
        if (pages.isEmpty()) return@runBusy
        val name = documentName()
        val context = getApplication<Application>()
        val result = withContext(processing) {
            runCatching {
                if (asPdf) {
                    ImageIo.save(context, "$name.pdf", PDF_MIME_TYPE, ImageIo.Folder.DOWNLOADS) { writePdf(pages, it) }
                } else {
                    exportImages(pages, name) { fileName, encoded ->
                        ImageIo.save(context, fileName, encoded.format.mimeType, ImageIo.Folder.PICTURES) {
                            it.write(encoded.bytes)
                        }
                    }
                }
            }
        }
        result.onSuccess {
            val files = pages.map { it.photo }
            _state.update { it.copy(screen = Screen.CAMERA, pages = emptyList()) }
            cleanupScope.launch { files.forEach { it.delete() } }
            _events.send(if (asPdf) ScannerEvent.SavedPdf else ScannerEvent.SavedImages)
        }.onFailure { error ->
            Log.e(TAG, "Unable to save", error)
            _events.send(ScannerEvent.SaveFailed)
        }
    }

    fun shareAsPdf() = share(asPdf = true)

    fun shareAsImages() = share(asPdf = false)

    /**
     * Renders the document into temporary files and asks the UI to offer them to other apps.
     * The document stays open, so it can still be saved or changed afterwards.
     */
    private fun share(asPdf: Boolean) = runBusy {
        val pages = _state.value.pages
        if (pages.isEmpty()) return@runBusy
        val name = documentName()
        val context = getApplication<Application>()
        val result = withContext(processing) {
            runCatching {
                // Files of an earlier share have been picked up by now.
                shareDirectory.deleteRecursively()
                shareDirectory.mkdirs()
                val files = ArrayList<File>()
                val mimeTypes = LinkedHashSet<String>()
                if (asPdf) {
                    val file = File(shareDirectory, "$name.pdf")
                    FileOutputStream(file).use { writePdf(pages, it) }
                    files += file
                    mimeTypes += PDF_MIME_TYPE
                } else {
                    exportImages(pages, name) { fileName, encoded ->
                        files += File(shareDirectory, fileName).apply { writeBytes(encoded.bytes) }
                        mimeTypes += encoded.format.mimeType
                    }
                }
                val uris = files.map { FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", it) }
                ScannerEvent.Share(uris, mimeTypes.singleOrNull() ?: "image/*")
            }
        }
        result.onSuccess { _events.send(it) }.onFailure { error ->
            Log.e(TAG, "Unable to prepare files for sharing", error)
            _events.send(ScannerEvent.ShareFailed)
        }
    }

    /** Writes the whole document as a PDF. Runs on [processing]. */
    private fun writePdf(pages: List<ScanPage>, stream: OutputStream) {
        PdfWriter(stream).use { pdf ->
            for (p in pages) {
                pdf.addPage(renderFullSize(p) { ScanEncoder.pdfImage(it, p.adjustments.mode) })
            }
        }
    }

    /** Encodes every page as an image and hands it over with its file name. Runs on [processing]. */
    private fun exportImages(pages: List<ScanPage>, name: String, consume: (String, EncodedImage) -> Unit) {
        pages.forEachIndexed { index, p ->
            val encoded = renderFullSize(p) { ScanEncoder.encodeImage(it, p.adjustments.mode) }
            val fileName = (if (pages.size == 1) name else "${name}_${index + 1}") + "." + encoded.format.extension
            consume(fileName, encoded)
        }
    }

    private fun documentName() = "DocuScan_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())

    /**
     * Renders [scan] at full resolution and hands the result to [use]. Only one page is held in
     * memory at a time, however long the document. Runs on [processing].
     */
    private fun <T> renderFullSize(scan: ScanPage, use: (Mat) -> T): T {
        val bitmap = ImageIo.decodeFile(scan.photo)
        val source = ImageIo.toRgbaMat(bitmap)
        bitmap.recycle()
        val flat = try {
            DocumentProcessor.warp(source, scan.crop.toPixels(source))
        } finally {
            source.release()
        }
        val rendered = try {
            DocumentProcessor.render(flat, scan.adjustments, DocumentProcessor.estimateAutoGains(flat))
        } finally {
            flat.release()
        }
        try {
            return use(rendered)
        } finally {
            rendered.release()
        }
    }

    /** Runs [block] with the busy flag set; ignored while another busy task runs. */
    private fun runBusy(block: suspend () -> Unit) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                block()
            } finally {
                _state.update { it.copy(busy = false) }
            }
        }
    }

    /** Leaves the crop/edit screens: forgets the open page and frees its images. */
    private fun closePage() {
        previewJob?.cancel()
        photoFile = null
        _state.update { it.copy(photo = null, preview = null, detectedQuad = null, cropQuad = Quad.UNIT) }
        cleanupScope.launch {
            releasePage()
            releasePhoto()
        }
    }

    override fun onCleared() {
        cleanupScope.launch {
            releasePage()
            releasePhoto()
            scanDirectory.deleteRecursively()
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

    private fun Quad.toPixels(image: Mat): Quad =
        scale(image.cols().toDouble(), image.rows().toDouble()).normalized()

    private companion object {
        const val TAG = "DocuScan"
        const val PDF_MIME_TYPE = "application/pdf"

        /** Larger bitmaps may exceed the GPU texture limit on older phones. */
        const val DISPLAY_MAX_SIDE = 2048
        const val PREVIEW_MAX_SIDE = 1600
        const val THUMBNAIL_MAX_SIDE = 480
    }
}
