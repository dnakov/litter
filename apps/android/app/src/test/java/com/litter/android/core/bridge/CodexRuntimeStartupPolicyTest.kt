package com.litter.android.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CodexRuntimeStartupPolicyTest {
    @Test
    fun parseBooleanFlagSupportsExpectedValues() {
        assertTrue(CodexRuntimeStartupPolicy.parseBooleanFlag("true") == true)
        assertTrue(CodexRuntimeStartupPolicy.parseBooleanFlag("1") == true)
        assertEquals(false, CodexRuntimeStartupPolicy.parseBooleanFlag("false"))
        assertEquals(false, CodexRuntimeStartupPolicy.parseBooleanFlag("0"))
        assertNull(CodexRuntimeStartupPolicy.parseBooleanFlag("maybe"))
    }

    @Test
    fun systemPropertyTakesPriorityOverEnvironmentAndBuildConfig() {
        val enabled = CodexRuntimeStartupPolicy.onDeviceBridgeEnabled(
            buildConfigValue = true,
            systemPropertyValue = "false",
            environmentValue = "true",
        )
        assertFalse(enabled)
    }

    @Test
    fun environmentTakesPriorityOverBuildConfigWhenPropertyMissing() {
        val enabled = CodexRuntimeStartupPolicy.onDeviceBridgeEnabled(
            buildConfigValue = true,
            systemPropertyValue = null,
            environmentValue = "off",
        )
        assertFalse(enabled)
    }

    @Test
    fun buildConfigUsedWhenNoOverridesPresent() {
        val enabled = CodexRuntimeStartupPolicy.onDeviceBridgeEnabled(
            buildConfigValue = false,
            systemPropertyValue = null,
            environmentValue = null,
        )
        assertFalse(enabled)
    }

    @Test
    fun defaultIsEnabledWhenEverythingIsUnset() {
        val enabled = CodexRuntimeStartupPolicy.onDeviceBridgeEnabled(
            buildConfigValue = null,
            systemPropertyValue = null,
            environmentValue = null,
        )
        assertTrue(enabled)
    }
}
