package com.amirovandrew.docuscan.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.amirovandrew.docuscan.R
import com.amirovandrew.docuscan.core.Quad
import com.amirovandrew.docuscan.core.Vec2
import kotlin.math.min
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CropScreen(
    photo: ImageBitmap,
    quad: Quad,
    canUseDetected: Boolean,
    onQuadChange: (Quad) -> Unit,
    onUseDetected: () -> Unit,
    onUseFullImage: () -> Unit,
    onBack: () -> Unit,
    onConfirm: () -> Unit,
) {
    Scaffold(
        containerColor = Color.Black,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.crop_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Black),
            )
        },
        bottomBar = {
            Row(
                Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val compact = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                OutlinedButton(onClick = onUseDetected, enabled = canUseDetected, contentPadding = compact) {
                    Text(stringResource(R.string.crop_auto))
                }
                OutlinedButton(onClick = onUseFullImage, contentPadding = compact) {
                    Text(stringResource(R.string.crop_full))
                }
                Spacer(Modifier.weight(1f))
                Button(onClick = onConfirm, contentPadding = compact) {
                    Text(stringResource(R.string.next))
                    Spacer(Modifier.size(6.dp))
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, modifier = Modifier.size(18.dp))
                }
            }
        },
    ) { padding ->
        CropEditor(photo, quad, onQuadChange, Modifier.padding(padding).fillMaxSize())
    }
}

/**
 * Shows [photo] with the document outline; the four corners can be dragged. While a corner is
 * being dragged a magnifier shows the area under the finger.
 *
 * @param quad corners in normalized (0..1) photo coordinates.
 */
@Composable
fun CropEditor(
    photo: ImageBitmap,
    quad: Quad,
    onQuadChange: (Quad) -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentQuad by rememberUpdatedState(quad)
    val currentOnQuadChange by rememberUpdatedState(onQuadChange)
    var activeCorner by remember { mutableIntStateOf(-1) }
    var fingerOnLeft by remember { mutableStateOf(false) }
    val accent = MaterialTheme.colorScheme.primary
    val density = LocalDensity.current

    BoxWithConstraints(modifier) {
        val margin = with(density) { 28.dp.toPx() }
        val boxWidth = constraints.maxWidth.toFloat()
        val boxHeight = constraints.maxHeight.toFloat()
        val scale = min((boxWidth - 2 * margin) / photo.width, (boxHeight - 2 * margin) / photo.height)
            .coerceAtLeast(0.01f)
        val imageSize = Size(photo.width * scale, photo.height * scale)
        val imageRect = Rect(Offset((boxWidth - imageSize.width) / 2, (boxHeight - imageSize.height) / 2), imageSize)

        Canvas(
            Modifier
                .fillMaxSize()
                .pointerInput(imageRect) {
                    val touchRadius = 48.dp.toPx()
                    var grabOffset = Offset.Zero
                    detectDragGestures(
                        onDragStart = { start ->
                            val corners = currentQuad.corners.map { imageRect.toScreen(it) }
                            val nearest = corners.indices.minBy { (corners[it] - start).getDistance() }
                            if ((corners[nearest] - start).getDistance() <= touchRadius) {
                                activeCorner = nearest
                                grabOffset = corners[nearest] - start
                                fingerOnLeft = start.x < size.width / 2
                            } else {
                                activeCorner = -1
                            }
                        },
                        onDrag = { change, _ ->
                            val index = activeCorner
                            if (index >= 0) {
                                change.consume()
                                fingerOnLeft = change.position.x < size.width / 2
                                val point = imageRect.toNormalized(change.position + grabOffset)
                                currentOnQuadChange(currentQuad.withCorner(index, point))
                            }
                        },
                        onDragEnd = { activeCorner = -1 },
                        onDragCancel = { activeCorner = -1 },
                    )
                },
        ) {
            drawPhoto(photo, imageRect, FilterQuality.Medium)

            val corners = quad.corners.map { imageRect.toScreen(it) }
            val outline = Path().apply {
                moveTo(corners[0].x, corners[0].y)
                for (i in 1..3) lineTo(corners[i].x, corners[i].y)
                close()
            }
            // Dim everything that will be cut away.
            val outside = Path().apply {
                fillType = PathFillType.EvenOdd
                addRect(imageRect)
                addPath(outline)
            }
            drawPath(outside, Color.Black.copy(alpha = 0.55f))
            drawPath(outline, accent, style = Stroke(width = 2.dp.toPx()))

            corners.forEachIndexed { i, corner ->
                val radius = (if (i == activeCorner) 14.dp else 11.dp).toPx()
                drawCircle(Color.White, radius, corner)
                drawCircle(accent, radius, corner, style = Stroke(width = 3.dp.toPx()))
            }

            val active = activeCorner
            if (active >= 0) drawLoupe(photo, imageRect, outline, corners[active], accent, placeRight = fingerOnLeft)
        }
    }
}

private fun Rect.toScreen(p: Vec2) = Offset(left + (p.x * width).toFloat(), top + (p.y * height).toFloat())

private fun Rect.toNormalized(o: Offset) = Vec2(
    ((o.x - left) / width).toDouble().coerceIn(0.0, 1.0),
    ((o.y - top) / height).toDouble().coerceIn(0.0, 1.0),
)

private fun DrawScope.drawPhoto(photo: ImageBitmap, rect: Rect, quality: FilterQuality) {
    drawImage(
        photo,
        dstOffset = IntOffset(rect.left.roundToInt(), rect.top.roundToInt()),
        dstSize = IntSize(rect.width.roundToInt(), rect.height.roundToInt()),
        filterQuality = quality,
    )
}

/** A circular magnifier in a top corner showing the area around [focus]. */
private fun DrawScope.drawLoupe(
    photo: ImageBitmap,
    imageRect: Rect,
    outline: Path,
    focus: Offset,
    accent: Color,
    placeRight: Boolean,
) {
    val radius = 60.dp.toPx()
    val zoom = 2.5f
    val margin = 12.dp.toPx()
    val center = Offset(
        if (placeRight) size.width - margin - radius else margin + radius,
        margin + radius,
    )
    val circle = Path().apply { addOval(Rect(center, radius)) }
    clipPath(circle) {
        drawRect(Color.Black, topLeft = center - Offset(radius, radius), size = Size(radius * 2, radius * 2))
        withTransform({
            translate(center.x - focus.x * zoom, center.y - focus.y * zoom)
            scale(zoom, zoom, pivot = Offset.Zero)
        }) {
            drawPhoto(photo, imageRect, FilterQuality.High)
            drawPath(outline, accent, style = Stroke(width = 1.5.dp.toPx() / zoom))
        }
    }
    drawCircle(Color.White, radius, center, style = Stroke(width = 2.dp.toPx()))
    val arm = 10.dp.toPx()
    val stroke = 1.5.dp.toPx()
    drawLine(accent, center - Offset(arm, 0f), center + Offset(arm, 0f), strokeWidth = stroke)
    drawLine(accent, center - Offset(0f, arm), center + Offset(0f, arm), strokeWidth = stroke)
}
