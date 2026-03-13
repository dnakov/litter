package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Test

class OpenCodeClientPathTest {
    @Test
    fun openCodePathKeepsConfiguredBasePrefix() {
        assertEquals("/base/slash", openCodePath("/base", "/slash"))
        assertEquals("/nested/root/skill", openCodePath("/nested/root/", "skill"))
        assertEquals("/slash", openCodePath("/", "/slash"))
    }
}
