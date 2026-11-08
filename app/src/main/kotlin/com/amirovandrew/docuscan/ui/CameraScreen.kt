package com.amirovandrew.docuscan.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.view.CameraController
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.FlashAuto
import androidx.compose.material.icons.filled.FlashOff
import androidx.compose.material.icons.filled.FlashOn
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.amirovandrew.docuscan.R
import com.amirovandrew.docuscan.camera.DocumentAnalyzer
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.Executors

@Composable
fun CameraScreen(
    onPhotoCaptured: (File) -> Unit,
    onImagePicked: (Uri) -> Unit,
    onCaptureFailed: () -> Unit,
) {
    val context = LocalContext.current
    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) onImagePicked(uri)
    }
    val openGallery = {
        pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }

    var hasCamera by remember { mutableStateOf(hasCameraPermission(context)) }
    val requestPermissions = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { hasCamera = hasCameraPermission(context) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { hasCamera = hasCameraPermission(context) }
    LaunchedEffect(Unit) {
        if (requiredPermissions().any { !isGranted(context, it) }) requestPermissions.launch(requiredPermissions())
    }

    if (hasCamera) {
        CameraContent(onPhotoCaptured, onCaptureFailed, openGallery)
    } else {
        PermissionRequest(
            onRequest = { requestPermissions.launch(requiredPermissions()) },
            onOpenSettings = {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                )
            },
            onOpenGallery = openGallery,
        )
    }
}

private enum class FlashMode(val captureMode: Int) {
    OFF(ImageCapture.FLASH_MODE_OFF),
    AUTO(ImageCapture.FLASH_MODE_AUTO),
    ON(ImageCapture.FLASH_MODE_ON);

    fun next(): FlashMode = entries[(ordinal + 1) % entries.size]
}

@Composable
private fun CameraContent(
    onPhotoCaptured: (File) -> Unit,
    onCaptureFailed: () -> Unit,
    onOpenGallery: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    val controller = remember {
        val fourByThree = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
            .build()
        LifecycleCameraController(context).apply {
            setEnabledUseCases(CameraController.IMAGE_CAPTURE or CameraController.IMAGE_ANALYSIS)
            imageCaptureMode = ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY
            previewResolutionSelector = fourByThree
            imageCaptureResolutionSelector = fourByThree
            imageAnalysisResolutionSelector = fourByThree
        }
    }
    var outline by remember { mutableStateOf<List<Offset>?>(null) }
    var flashMode by rememberSaveable { mutableStateOf(FlashMode.OFF) }
    var capturing by remember { mutableStateOf(false) }
    val shutterFlash = remember { Animatable(0f) }

    DisposableEffect(lifecycleOwner, controller) {
        val executor = Executors.newSingleThreadExecutor()
        val mainExecutor = ContextCompat.getMainExecutor(context)
        val analyzer = DocumentAnalyzer { points -> mainExecutor.execute { outline = points } }
        controller.setImageAnalysisAnalyzer(executor, analyzer)
        controller.bindToLifecycle(lifecycleOwner)
        onDispose {
            controller.clearImageAnalysisAnalyzer()
            controller.unbind()
            executor.execute { analyzer.release() }
            executor.shutdown()
        }
    }
    LaunchedEffect(flashMode) { controller.imageCaptureFlashMode = flashMode.captureMode }

    val capture = {
        capturing = true
        scope.launch {
            shutterFlash.snapTo(0.7f)
            shutterFlash.animateTo(0f, tween(300))
        }
        val file = File(context.cacheDir, "capture_${System.currentTimeMillis()}.jpg")
        controller.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).build(),
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    capturing = false
                    onPhotoCaptured(file)
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e("DocuScan", "Capture failed", exception)
                    capturing = false
                    file.delete()
                    onCaptureFailed()
                }
            },
        )
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .safeDrawingPadding(),
    ) {
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f)) {
                AndroidView(
                    factory = { ctx ->
                        PreviewView(ctx).apply {
                            scaleType = PreviewView.ScaleType.FILL_CENTER
                            this.controller = controller
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
                DocumentOutline(outline, Modifier.fillMaxSize())
                if (shutterFlash.value > 0f) {
                    Box(Modifier.fillMaxSize().background(Color.White.copy(alpha = shutterFlash.value)))
                }
            }
        }

        Text(
            text = stringResource(if (outline != null) R.string.camera_hint_found else R.string.camera_hint),
            color = Color.White,
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
        )

        Row(
            Modifier.fillMaxWidth().padding(vertical = 20.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onOpenGallery, modifier = Modifier.size(56.dp)) {
                Icon(
                    Icons.Outlined.PhotoLibrary,
                    contentDescription = stringResource(R.string.import_from_gallery),
                    tint = Color.White,
                    modifier = Modifier.size(30.dp),
                )
            }
            ShutterButton(enabled = !capturing, onClick = capture)
            IconButton(onClick = { flashMode = flashMode.next() }, modifier = Modifier.size(56.dp)) {
                val (icon, description) = when (flashMode) {
                    FlashMode.OFF -> Icons.Filled.FlashOff to R.string.flash_off
                    FlashMode.AUTO -> Icons.Filled.FlashAuto to R.string.flash_auto
                    FlashMode.ON -> Icons.Filled.FlashOn to R.string.flash_on
                }
                Icon(icon, contentDescription = stringResource(description), tint = Color.White, modifier = Modifier.size(30.dp))
            }
        }
    }
}

@Composable
private fun ShutterButton(enabled: Boolean, onClick: () -> Unit) {
    val description = stringResource(R.string.capture)
    Box(
        Modifier
            .size(78.dp)
            .border(4.dp, Color.White, CircleShape)
            .padding(8.dp)
            .clip(CircleShape)
            .background(if (enabled) Color.White else Color.White.copy(alpha = 0.4f))
            .clickable(enabled = enabled, onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (!enabled) CircularProgressIndicator(Modifier.size(32.dp), color = Color.Black, strokeWidth = 3.dp)
    }
}

/** Draws the detected document outline on top of the camera preview. */
@Composable
private fun DocumentOutline(points: List<Offset>?, modifier: Modifier) {
    val accent = MaterialTheme.colorScheme.primary
    Canvas(modifier) {
        val corners = points ?: return@Canvas
        val path = Path().apply {
            moveTo(corners[0].x, corners[0].y)
            for (i in 1 until corners.size) lineTo(corners[i].x, corners[i].y)
            close()
        }
        drawPath(path, accent.copy(alpha = 0.22f))
        drawPath(path, accent, style = Stroke(width = 3.dp.toPx(), join = StrokeJoin.Round))
        corners.forEach { drawCircle(Color.White, radius = 5.dp.toPx(), center = it) }
    }
}

@Composable
private fun PermissionRequest(onRequest: () -> Unit, onOpenSettings: () -> Unit, onOpenGallery: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .safeDrawingPadding()
            .padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Filled.CameraAlt, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(64.dp))
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.permission_title), style = MaterialTheme.typography.titleLarge, color = Color.White, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.permission_text), style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.8f), textAlign = TextAlign.Center)
        Spacer(Modifier.height(24.dp))
        Button(onClick = onRequest) { Text(stringResource(R.string.permission_grant)) }
        TextButton(onClick = onOpenSettings) { Text(stringResource(R.string.permission_settings)) }
        Spacer(Modifier.height(16.dp))
        OutlinedButton(onClick = onOpenGallery) {
            Icon(Icons.Outlined.PhotoLibrary, contentDescription = null)
            Spacer(Modifier.size(8.dp))
            Text(stringResource(R.string.import_from_gallery))
        }
    }
}

private fun requiredPermissions(): Array<String> =
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
        arrayOf(Manifest.permission.CAMERA, Manifest.permission.WRITE_EXTERNAL_STORAGE)
    } else {
        arrayOf(Manifest.permission.CAMERA)
    }

private fun isGranted(context: Context, permission: String) =
    ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

private fun hasCameraPermission(context: Context) = isGranted(context, Manifest.permission.CAMERA)
