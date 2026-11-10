package com.amirovandrew.docuscan.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream

class BoundedCopyTest {

    @Test
    fun `copies inputs up to the limit unchanged`() {
        for (size in listOf(0, 1, 65_536, 200_000)) {
            val data = ByteArray(size) { (it * 31).toByte() }
            val out = ByteArrayOutputStream()
            assertEquals(size.toLong(), copyAtMost(ByteArrayInputStream(data), out, maxBytes = 200_000))
            assertArrayEquals(data, out.toByteArray())
        }
    }

    @Test
    fun `refuses an input one byte over the limit`() {
        val out = ByteArrayOutputStream()
        val error = assertThrows(InputTooLargeException::class.java) {
            copyAtMost(ByteArrayInputStream(ByteArray(100_001)), out, maxBytes = 100_000)
        }
        assertEquals(100_000L, error.limit)
        assertTrue("must not write more than the limit", out.size() <= 100_000)
    }

    @Test
    fun `stops reading an endless input`() {
        var served = 0L
        val endless = object : InputStream() {
            override fun read(): Int = 0.also { served++ }
            override fun read(b: ByteArray, off: Int, len: Int): Int = len.also { served += len }
        }
        assertThrows(InputTooLargeException::class.java) {
            copyAtMost(endless, ByteArrayOutputStream(), maxBytes = 1_000_000)
        }
        assertTrue("read $served bytes", served < 2_000_000)
    }
}
