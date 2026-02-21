package com.litter.android

import com.sigkitten.litter.android.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Test

class RuntimeFlavorConfigTest {
    @Test
    fun startupModeMatchesOnDeviceToggle() {
        val expectedMode = if (BuildConfig.ENABLE_ON_DEVICE_BRIDGE) "hybrid" else "remote_only"
        assertEquals(expectedMode, BuildConfig.RUNTIME_STARTUP_MODE)
    }

    @Test
    fun canonicalRuntimeTransportIsPinned() {
        assertEquals("app_bridge_rpc_transport", BuildConfig.APP_RUNTIME_TRANSPORT)
    }
}
