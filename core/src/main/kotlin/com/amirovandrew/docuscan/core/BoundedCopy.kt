package com.amirovandrew.docuscan.core

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** Thrown by [copyAtMost] when the input is longer than allowed. */
class InputTooLargeException(val limit: Long) : IOException("Input is larger than $limit bytes")

/**
 * Copies [input] to [output] but refuses inputs longer than [maxBytes], so that a huge (or
 * endless) source cannot fill up the storage.
 *
 * @return the number of bytes copied.
 * @throws InputTooLargeException if the input has more than [maxBytes] bytes; [output] has
 *   received at most [maxBytes] bytes by then and should be discarded by the caller.
 */
fun copyAtMost(input: InputStream, output: OutputStream, maxBytes: Long): Long {
    val buffer = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val read = input.read(buffer)
        if (read < 0) return total
        if (total + read > maxBytes) throw InputTooLargeException(maxBytes)
        output.write(buffer, 0, read)
        total += read
    }
}
