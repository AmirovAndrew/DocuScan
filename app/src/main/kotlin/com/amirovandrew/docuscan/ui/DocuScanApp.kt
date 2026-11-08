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

    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            val (message, duration) = when (event) {
                is ScannerEvent.Saved -> R.string.saved to Toast.LENGTH_LONG
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
            Screen.CAMERA -> CameraScreen(
                onPhotoCaptured = viewModel::onPhotoCaptured,
                onImagePicked = viewModel::onImagePicked,
                onCaptureFailed = viewModel::onCaptureFailed,
            )

            Screen.CROP -> {
                BackHandler { if (!state.busy) viewModel.backToCamera() }
                state.photo?.let { photo ->
                    CropScreen(
                        photo = photo,
                        quad = state.cropQuad,
                        canUseDetected = state.detectedQuad != null,
                        onQuadChange = viewModel::onCropChanged,
                        onUseDetected = viewModel::useDetectedCrop,
                        onUseFullImage = viewModel::useFullImage,
                        onBack = viewModel::backToCamera,
                        onConfirm = viewModel::confirmCrop,
                    )
                }
            }

            Screen.EDIT -> {
                BackHandler { if (!state.busy) viewModel.backToCrop() }
                EditScreen(
                    preview = state.preview,
                    adjustments = state.adjustments,
                    onAdjust = viewModel::updateAdjustments,
                    onBack = viewModel::backToCrop,
                    onSave = viewModel::save,
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
}
