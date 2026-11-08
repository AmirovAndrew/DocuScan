package com.amirovandrew.docuscan

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.amirovandrew.docuscan.ui.DocuScanApp
import com.amirovandrew.docuscan.ui.theme.DocuScanTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            DocuScanTheme {
                DocuScanApp()
            }
        }
    }
}
