package com.litter.android.core.bridge

object NativeCodexBridge {
    private val loaded: Boolean =
        runCatching { System.loadLibrary("codex_bridge") }.isSuccess

    fun startServerPort(): Int {
        if (!loaded) {
            return -1000
        }
        return nativeStartServerPort()
    }

    fun stopServer() {
        if (loaded) {
            nativeStopServer()
        }
    }

    @JvmStatic
    private external fun nativeStartServerPort(): Int

    @JvmStatic
    private external fun nativeStopServer()
}
