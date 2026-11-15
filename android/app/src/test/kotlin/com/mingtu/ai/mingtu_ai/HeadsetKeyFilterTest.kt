package com.mingtu.ai.mingtu_ai

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HeadsetKeyFilterTest {
    @Test fun acceptsOnlyFreshForegroundHeadsetDowns() {
        for (key in listOf(79, 85)) {
            assertTrue(HeadsetKeyFilter.accepts(true, key, 0, 0))
            assertFalse(HeadsetKeyFilter.accepts(false, key, 0, 0))
            assertFalse(HeadsetKeyFilter.accepts(true, key, 1, 0))
            assertFalse(HeadsetKeyFilter.accepts(true, key, 0, 1))
        }
        assertFalse(HeadsetKeyFilter.accepts(true, 86, 0, 0))
    }
}
