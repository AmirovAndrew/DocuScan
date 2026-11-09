package com.amirovandrew.docuscan.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.amirovandrew.docuscan.R
import com.amirovandrew.docuscan.ScanPage

/** The pages of the document: reorder, delete, re-edit, add more and save. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PagesScreen(
    pages: List<ScanPage>,
    onBack: () -> Unit,
    onAddPage: () -> Unit,
    onOpenPage: (Long) -> Unit,
    onMovePage: (Long, Int) -> Unit,
    onDeletePage: (Long) -> Unit,
    onDiscard: () -> Unit,
    onSaveImages: () -> Unit,
    onSavePdf: () -> Unit,
) {
    Scaffold(
        containerColor = Color.Black,
        topBar = {
            TopAppBar(
                title = { Text(pluralStringResource(R.plurals.pages_count, pages.size, pages.size)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = {
                    IconButton(onClick = onDiscard, enabled = pages.isNotEmpty()) {
                        Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.discard_document))
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
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                val compact = PaddingValues(horizontal = 12.dp, vertical = 10.dp)
                OutlinedButton(
                    onClick = onSaveImages,
                    enabled = pages.isNotEmpty(),
                    contentPadding = compact,
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Outlined.PhotoLibrary, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.save_images), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Button(
                    onClick = onSavePdf,
                    enabled = pages.isNotEmpty(),
                    contentPadding = compact,
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Filled.PictureAsPdf, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.save_pdf), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        },
    ) { padding ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(150.dp),
            contentPadding = PaddingValues(
                start = 12.dp,
                end = 12.dp,
                top = padding.calculateTopPadding() + 4.dp,
                bottom = padding.calculateBottomPadding() + 12.dp,
            ),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            itemsIndexed(pages, key = { _, page -> page.id }) { index, page ->
                PageCard(
                    page = page,
                    number = index + 1,
                    canMoveEarlier = index > 0,
                    canMoveLater = index < pages.lastIndex,
                    onOpen = { onOpenPage(page.id) },
                    onMove = { delta -> onMovePage(page.id, delta) },
                    onDelete = { onDeletePage(page.id) },
                    modifier = Modifier.animateItem(),
                )
            }
            item(key = "add") {
                OutlinedCard(onClick = onAddPage) {
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .aspectRatio(PAGE_ASPECT),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(40.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(stringResource(R.string.add_page), style = MaterialTheme.typography.labelLarge)
                    }
                    // Same height as the button row of the page cards.
                    Spacer(Modifier.size(48.dp))
                }
            }
        }
    }
}

@Composable
private fun PageCard(
    page: ScanPage,
    number: Int,
    canMoveEarlier: Boolean,
    canMoveLater: Boolean,
    onOpen: () -> Unit,
    onMove: (Int) -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(onClick = onOpen, modifier = modifier) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(PAGE_ASPECT)
                .background(Color(0xFF2A2F31))
                .padding(8.dp),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                bitmap = page.thumbnail,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize(),
            )
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .size(26.dp)
                    .background(MaterialTheme.colorScheme.primary, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    number.toString(),
                    color = MaterialTheme.colorScheme.onPrimary,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            IconButton(onClick = { onMove(-1) }, enabled = canMoveEarlier) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = stringResource(R.string.move_earlier))
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.delete_page))
            }
            IconButton(onClick = { onMove(1) }, enabled = canMoveLater) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = stringResource(R.string.move_later))
            }
        }
    }
}

/** Asks before throwing away all scanned pages. */
@Composable
fun DiscardDocumentDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.discard_title)) },
        text = { Text(stringResource(R.string.discard_text)) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.discard)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

private const val PAGE_ASPECT = 3f / 4f
