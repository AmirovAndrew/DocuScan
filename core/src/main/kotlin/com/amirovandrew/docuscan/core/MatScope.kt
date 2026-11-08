package com.amirovandrew.docuscan.core

import org.opencv.core.Mat

/**
 * Releases the native memory of every [Mat] registered with [track] when the scope ends.
 * Use [keep] for the Mat that is handed to the caller.
 */
class MatScope : AutoCloseable {
    private val mats = ArrayList<Mat>()

    fun <T : Mat> T.track(): T {
        mats += this
        return this
    }

    fun <T : Mat> T.keep(): T {
        mats.remove(this)
        return this
    }

    fun mat(): Mat = Mat().track()

    override fun close() {
        mats.forEach { it.release() }
        mats.clear()
    }
}

inline fun <R> matScope(block: MatScope.() -> R): R = MatScope().use { it.block() }
