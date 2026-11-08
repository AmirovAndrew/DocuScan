package com.amirovandrew.docuscan.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Rotate90DegreesCw
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.amirovandrew.docuscan.R
import com.amirovandrew.docuscan.core.Adjustments
import com.amirovandrew.docuscan.core.ColorMode
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditScreen(
    preview: ImageBitmap?,
    adjustments: Adjustments,
    onAdjust: ((Adjustments) -> Adjustments) -> Unit,
    onBack: () -> Unit,
    onSave: () -> Unit,
) {
    Scaffold(
        containerColor = Color.Black,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.edit_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = {
                    IconButton(onClick = { onAdjust { it.rotatedClockwise() } }) {
                        Icon(Icons.Filled.Rotate90DegreesCw, contentDescription = stringResource(R.string.rotate))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Black),
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(12.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (preview != null) {
                    Image(
                        bitmap = preview,
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    CircularProgressIndicator()
                }
            }
            AdjustmentPanel(adjustments, onAdjust, onSave)
        }
    }
}

@Composable
private fun AdjustmentPanel(
    adjustments: Adjustments,
    onAdjust: ((Adjustments) -> Adjustments) -> Unit,
    onSave: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            ModeSelector(adjustments.mode) { mode -> onAdjust { it.copy(mode = mode) } }

            Column(
                Modifier
                    .padding(top = 8.dp)
                    .heightIn(max = 240.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                if (adjustments.mode == ColorMode.COLOR) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(stringResource(R.string.white_balance), style = MaterialTheme.typography.titleSmall)
                            Text(
                                stringResource(
                                    if (adjustments.autoWhiteBalance) R.string.white_balance_auto_hint else R.string.white_balance_manual_hint,
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Text(stringResource(R.string.auto), style = MaterialTheme.typography.labelLarge)
                        Spacer(Modifier.width(8.dp))
                        Switch(
                            checked = adjustments.autoWhiteBalance,
                            onCheckedChange = { checked -> onAdjust { it.copy(autoWhiteBalance = checked) } },
                        )
                    }
                    AdjustmentSlider(stringResource(R.string.temperature), adjustments.temperature) { v ->
                        onAdjust { it.copy(temperature = v) }
                    }
                    AdjustmentSlider(stringResource(R.string.tint), adjustments.tint) { v ->
                        onAdjust { it.copy(tint = v) }
                    }
                }
                AdjustmentSlider(stringResource(R.string.brightness), adjustments.brightness) { v ->
                    onAdjust { it.copy(brightness = v) }
                }
                AdjustmentSlider(stringResource(R.string.contrast), adjustments.contrast) { v ->
                    onAdjust { it.copy(contrast = v) }
                }
                if (adjustments.mode == ColorMode.BLACK_WHITE) {
                    AdjustmentSlider(stringResource(R.string.threshold), adjustments.threshold) { v ->
                        onAdjust { it.copy(threshold = v) }
                    }
                }
            }

            Row(
                Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedButton(onClick = { onAdjust { it.resetSliders() } }) {
                    Text(stringResource(R.string.reset))
                }
                Spacer(Modifier.weight(1f))
                Button(onClick = onSave) {
                    Icon(Icons.Filled.Save, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.save))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModeSelector(selected: ColorMode, onSelect: (ColorMode) -> Unit) {
    val modes = ColorMode.entries
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        modes.forEachIndexed { index, mode ->
            SegmentedButton(
                selected = mode == selected,
                onClick = { onSelect(mode) },
                shape = SegmentedButtonDefaults.itemShape(index, modes.size),
                icon = {},
                label = {
                    Text(
                        stringResource(
                            when (mode) {
                                ColorMode.COLOR -> R.string.mode_color
                                ColorMode.GRAYSCALE -> R.string.mode_grayscale
                                ColorMode.BLACK_WHITE -> R.string.mode_black_white
                            },
                        ),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
            )
        }
    }
}

/** A compact slider for a -1..1 value, shown as -100..100. */
@Composable
private fun AdjustmentSlider(label: String, value: Float, onValueChange: (Float) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.width(104.dp),
        )
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = -1f..1f,
            modifier = Modifier.weight(1f),
        )
        Text(
            (value * 100).roundToInt().toString(),
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.End,
            modifier = Modifier.width(40.dp),
        )
    }
}
