package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ServerConfigPersistenceTest {
    @Test
    fun manualOpenCodeIdCanonicalizesDefaultHttpScheme() {
        val first = manualServerId(BackendKind.OPENCODE, "127.0.0.1", 4096)
        val second = manualServerId(BackendKind.OPENCODE, "http://127.0.0.1", 4096)

        assertEquals(first, second)
    }

    @Test
    fun savedServerRoundTripsOpenCodeFields() {
        val server =
            ServerConfig(
                id = "opencode-main",
                name = "OpenCode",
                host = "192.168.1.10",
                port = 4096,
                source = ServerSource.MANUAL,
                backendKind = BackendKind.OPENCODE,
                hasCodexServer = false,
                username = "opencode",
                password = "secret",
                directory = "/workspace/demo",
            )

        val restored = SavedServer.from(server).toServerConfig()

        assertEquals(BackendKind.OPENCODE, restored.backendKind)
        assertEquals("opencode", restored.username)
        assertEquals("secret", restored.password)
        assertEquals("/workspace/demo", restored.directory)
    }

    @Test
    fun savedServerDefaultsToCodexWhenBackendKindMissing() {
        val restored =
            SavedServer(
                id = "legacy",
                name = "Legacy",
                host = "127.0.0.1",
                port = 8390,
                source = "manual",
                hasCodexServer = true,
            ).toServerConfig()

        assertEquals(BackendKind.CODEX, restored.backendKind)
        assertNull(restored.username)
        assertNull(restored.directory)
    }

    @Test
    fun manualOpenCodeIdKeepsPathSegments() {
        val first = manualServerId(BackendKind.OPENCODE, "https://example.com/base", 443)
        val second = manualServerId(BackendKind.OPENCODE, "https://example.com/base/", 443)
        val third = manualServerId(BackendKind.OPENCODE, "https://example.com/other", 443)

        assertEquals(first, second)
        assertNotEquals(first, third)
    }
}
