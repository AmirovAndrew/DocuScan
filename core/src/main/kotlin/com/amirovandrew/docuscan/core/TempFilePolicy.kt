package com.amirovandrew.docuscan.core

/** Decides when a temporary file that was handed to another app may be deleted. */
object TempFilePolicy {

    /**
     * @param ageMs current time minus the file's modification time. Slightly negative for a file
     *   that is being written while the clean-up runs.
     * @param lifetimeMs how long the receiving app gets to read the file.
     */
    fun isExpired(ageMs: Long, lifetimeMs: Long): Boolean =
        // A file dated far in the future means the clock was set back: it must not stay forever.
        ageMs >= lifetimeMs || ageMs < -lifetimeMs
}
