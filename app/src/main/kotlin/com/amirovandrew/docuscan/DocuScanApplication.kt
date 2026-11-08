package com.amirovandrew.docuscan

import android.app.Application
import android.util.Log
import org.opencv.android.OpenCVLoader

class DocuScanApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (!OpenCVLoader.initLocal()) Log.e("DocuScan", "Unable to load OpenCV")
    }
}
