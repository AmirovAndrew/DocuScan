package com.amirovandrew.docuscan

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * The temporary files that hold document content. Both kinds live in the app's private cache,
 * out of reach of other apps:
 *
 * - photos of the pages being scanned ([scanDirectory]), needed until the document is saved or
 *   discarded. If the app is killed before that they are useless: the document cannot be resumed;
 * - files handed to other apps by "Share" ([newShareDirectory]), which the receiving app may read
 *   a little later, e.g. when a message is finally sent.
 *
 * [cleanUp] deletes what is no longer needed. [CleanupReceiver] runs it again later, so nothing
 * is left behind until the next launch if the app gets closed.
 */
object TempFiles {

    /** How long shared files are kept for the receiving app. */
    const val SHARE_LIFETIME_MS = 10 * 60 * 1000L

    private const val CHECK_INTERVAL_MS = 15 * 60 * 1000L

    /** Number of scans in progress in this process (normally 0 or 1). */
    private val scanSessions = AtomicInteger(0)

    fun scanDirectory(context: Context) = File(context.cacheDir, "scan")

    /** Root of the shared files; this is the only directory the FileProvider exposes. */
    private fun shareRoot(context: Context) = File(context.cacheDir, "share")

    /** A fresh directory for the files of one "Share" action. */
    fun newShareDirectory(context: Context): File {
        val root = shareRoot(context)
        var directory = File(root, System.currentTimeMillis().toString())
        while (directory.exists()) directory = File(root, directory.name + "_")
        check(directory.mkdirs()) { "Unable to create $directory" }
        return directory
    }

    /** A scan starts: page photos are in use from now on. Leftovers of an earlier run are removed. */
    fun beginScanSession(context: Context) {
        if (scanSessions.getAndIncrement() == 0) scanDirectory(context).deleteRecursively()
        scanDirectory(context).mkdirs()
    }

    /** The scan is over; the caller deletes its photos. */
    fun endScanSession() {
        scanSessions.updateAndGet { maxOf(0, it - 1) }
    }

    /**
     * Deletes shared files past their lifetime and, unless a scan is in progress in this process,
     * all page photos.
     *
     * @return true if temporary files remain, i.e. another clean-up is needed later.
     */
    fun cleanUp(context: Context, now: Long = System.currentTimeMillis()): Boolean {
        var remaining = false
        shareRoot(context).listFiles()?.forEach { entry ->
            val age = now - entry.lastModified()
            // A timestamp far in the future means the clock was changed: don't keep such files forever.
            if (age >= SHARE_LIFETIME_MS || age < -SHARE_LIFETIME_MS) entry.deleteRecursively() else remaining = true
        }
        val scan = scanDirectory(context)
        if (scanSessions.get() > 0) {
            if (!scan.list().isNullOrEmpty()) remaining = true
        } else {
            scan.deleteRecursively()
        }
        return remaining
    }

    /** Runs [cleanUp] now and, if files remain, arranges for another run later. */
    fun cleanUpAndReschedule(context: Context) {
        if (cleanUp(context)) scheduleCleanUp(context)
    }

    /**
     * Asks the system to run [CleanupReceiver] in a while, even if the app is not running then.
     * The timing is inexact (and needs no permission); a newer request replaces a pending one.
     */
    fun scheduleCleanUp(context: Context) {
        val app = context.applicationContext
        val alarms = app.getSystemService(AlarmManager::class.java) ?: return
        val operation = PendingIntent.getBroadcast(
            app, 0, Intent(app, CleanupReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarms.set(AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + CHECK_INTERVAL_MS, operation)
    }
}

/** Started by the alarm of [TempFiles.scheduleCleanUp]; not reachable from other apps. */
class CleanupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Runs on the main thread, like the code that starts and ends scan sessions.
        TempFiles.cleanUpAndReschedule(context.applicationContext)
    }
}
