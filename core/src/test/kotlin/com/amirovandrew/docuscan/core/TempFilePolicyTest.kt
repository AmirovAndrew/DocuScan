package com.amirovandrew.docuscan.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TempFilePolicyTest {

    private val lifetime = 10 * 60 * 1000L

    @Test
    fun `files are kept for their lifetime and deleted afterwards`() {
        assertFalse(TempFilePolicy.isExpired(0, lifetime))
        assertFalse(TempFilePolicy.isExpired(lifetime - 1, lifetime))
        assertTrue(TempFilePolicy.isExpired(lifetime, lifetime))
        assertTrue(TempFilePolicy.isExpired(24 * 60 * 60 * 1000L, lifetime))
    }

    @Test
    fun `a file written during the clean-up is kept`() {
        // Its timestamp is a moment later than the time the clean-up started with.
        assertFalse(TempFilePolicy.isExpired(-1, lifetime))
        assertFalse(TempFilePolicy.isExpired(-2_000, lifetime))
    }

    @Test
    fun `a file dated far in the future does not stay forever`() {
        assertTrue(TempFilePolicy.isExpired(-lifetime - 1, lifetime))
        assertTrue(TempFilePolicy.isExpired(-365L * 24 * 60 * 60 * 1000, lifetime))
    }
}
