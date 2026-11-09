package com.amirovandrew.docuscan.ui

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.amirovandrew.docuscan.R
import com.amirovandrew.docuscan.ScannerEvent
import com.amirovandrew.docuscan.ScannerViewModel
import com.amirovandrew.docuscan.Screen

@Composable
fun DocuScanApp(viewModel: ScannerViewModel = viewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var confirmDiscard by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            val (message, duration) = when (event) {
                ScannerEvent.SavedImages -> R.string.saved to Toast.LENGTH_LONG
                ScannerEvent.SavedPdf -> R.string.saved_pdf to Toast.LENGTH_LONG
                ScannerEvent.DocumentNotFound -> R.string.document_not_found to Toast.LENGTH_LONG
                ScannerEvent.CaptureFailed -> R.string.error_capture to Toast.LENGTH_SHORT
                ScannerEvent.OpenFailed -> R.string.error_open to Toast.LENGTH_SHORT
                ScannerEvent.SaveFailed -> R.string.error_save to Toast.LENGTH_SHORT
            }
            Toast.makeText(context, message, duration).show()
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (state.screen) {
            Screen.CAMERA -> {
                // Leaving the app would lose the unsaved pages: ask first.
                BackHandler(enabled = state.pages.isNotEmpty()) { confirmDiscard = true }
                CameraScreen(
                    pageCount = state.pages.size,
                    lastPage = state.pages.lastOrNull()?.thumbnail,
                    newPhotoFile = viewModel::newPhotoFile,
                    onPhotoCaptured = viewModel::onPhotoCaptured,
                    onImagePicked = viewModel::onImagePicked,
                    onCaptureFailed = viewModel::onCaptureFailed,
                    onOpenPages = viewModel::openPages,
                )
            }

            Screen.CROP -> {
                BackHandler { viewModel.backFromCrop() }
                state.photo?.let { photo ->
                    CropScreen(
                        photo = photo,
                        quad = state.cropQuad,
                        canUseDetected = state.detectedQuad != null,
                        onQuadChange = viewModel::onCropChanged,
                        onUseDetected = viewModel::useDetectedCrop,
                        onUseFullImage = viewModel::useFullImage,
                        onBack = viewModel::backFromCrop,
                        onConfirm = viewModel::confirmCrop,
                    )
                }
            }

            Screen.EDIT -> {
                BackHandler { viewModel.backFromEdit() }
                EditScreen(
                    preview = state.preview,
                    adjustments = state.adjustments,
                    onAdjust = viewModel::updateAdjustments,
                    onBack = viewModel::backFromEdit,
                    onDone = viewModel::finishPage,
                )
            }

            Screen.PAGES -> {
                BackHandler { if (!state.busy) viewModel.addPage() }
                PagesScreen(
                    pages = state.pages,
                    onBack = viewModel::addPage,
                    onAddPage = viewModel::addPage,
                    onOpenPage = viewModel::editPage,
                    onMovePage = viewModel::movePage,
                    onDeletePage = viewModel::deletePage,
                    onDiscard = { confirmDiscard = true },
                    onSaveImages = viewModel::saveAsImages,
                    onSavePdf = viewModel::saveAsPdf,
                )
            }
        }

        if (state.busy) {
            // Swallows touches while the image is being processed.
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.5f))
                    .pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent() } },
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }
        }
    }

    if (confirmDiscard) {
        DiscardDocumentDialog(
            onConfirm = {
                confirmDiscard = false
                viewModel.discardDocument()
            },
            onDismiss = { confirmDiscard = false },
        )
    }
}
