package com.amirovandrew.docuscan

import android.content.Context
import androidx.core.content.edit
import com.amirovandrew.docuscan.core.Adjustments
import com.amirovandrew.docuscan.core.ColorMode

/** Remembers the colour mode and the switches between scans. */
class ScanPreferences(context: Context) {
    private val prefs = context.getSharedPreferences("scan", Context.MODE_PRIVATE)

    fun load(): Adjustments = Adjustments(
        mode = ColorMode.entries.firstOrNull { it.name == prefs.getString(KEY_MODE, null) } ?: ColorMode.COLOR,
        autoWhiteBalance = prefs.getBoolean(KEY_AUTO_WB, true),
        evenLighting = prefs.getBoolean(KEY_EVEN_LIGHTING, true),
    )

    fun save(adjustments: Adjustments) = prefs.edit {
        putString(KEY_MODE, adjustments.mode.name)
        putBoolean(KEY_AUTO_WB, adjustments.autoWhiteBalance)
        putBoolean(KEY_EVEN_LIGHTING, adjustments.evenLighting)
    }

    private companion object {
        const val KEY_MODE = "mode"
        const val KEY_AUTO_WB = "auto_white_balance"
        const val KEY_EVEN_LIGHTING = "even_lighting"
    }
}
