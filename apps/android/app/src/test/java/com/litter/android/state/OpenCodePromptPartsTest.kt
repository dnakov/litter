package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenCodePromptPartsTest {
    @Test
    fun promptPartsUseFileAttachmentForImageDataUrl() {
        val parts =
            buildOpenCodePromptParts(
                text = "Describe this",
                localImageDataUrl = "data:image/png;base64,abc123",
                localImagePath = "/tmp/screenshot.png",
            )

        assertEquals(2, parts.length())
        assertEquals("text", parts.getJSONObject(0).getString("type"))
        assertEquals("Describe this", parts.getJSONObject(0).getString("text"))

        val attachment = parts.getJSONObject(1)
        assertEquals("file", attachment.getString("type"))
        assertEquals("image/png", attachment.getString("mime"))
        assertEquals("screenshot.png", attachment.getString("filename"))
        assertEquals("data:image/png;base64,abc123", attachment.getString("url"))
    }

    @Test
    fun promptPartsFallbackToFileUrlWhenImageCannotBeInlined() {
        val parts =
            buildOpenCodePromptParts(
                text = "",
                localImagePath = "/tmp/camera-shot.webp",
            )

        assertEquals(1, parts.length())
        val attachment = parts.getJSONObject(0)
        assertEquals("file", attachment.getString("type"))
        assertEquals("image/webp", attachment.getString("mime"))
        assertEquals("camera-shot.webp", attachment.getString("filename"))
        assertTrue(attachment.getString("url").startsWith("file:/"))
    }

    @Test
    fun savedServerPersistencePayloadOmitsCredentials() {
        val payload =
            buildSavedServersPersistencePayload(
                listOf(
                    SavedServer(
                        id = "manual-opencode",
                        name = "OpenCode",
                        host = "127.0.0.1",
                        port = 4096,
                        source = "manual",
                        backendKind = BackendKind.OPENCODE.rawValue(),
                        hasCodexServer = false,
                        username = "opencode",
                        password = "secret",
                        directory = "/workspace/demo",
                    ),
                ),
            )

        val saved = payload.getJSONObject(0)
        assertFalse(saved.has("username"))
        assertFalse(saved.has("password"))
        assertEquals("/workspace/demo", saved.getString("directory"))
    }

    @Test
    fun savedServerPersistencePayloadIncludesCurrentCredentialsInFallbackMode() {
        val payload =
            buildSavedServersPersistencePayload(
                savedServers =
                    listOf(
                        SavedServer(
                            id = "manual-opencode",
                            name = "OpenCode",
                            host = "127.0.0.1",
                            port = 4096,
                            source = "manual",
                            backendKind = BackendKind.OPENCODE.rawValue(),
                            hasCodexServer = false,
                            username = "updated-user",
                            password = "updated-secret",
                            directory = "/workspace/demo",
                        ),
                    ),
                includeCredentials = true,
            )

        val saved = payload.getJSONObject(0)
        assertEquals("updated-user", saved.getString("username"))
        assertEquals("updated-secret", saved.getString("password"))
    }

    @Test
    fun savedServerPersistencePayloadWritesNullsWhenFallbackCredentialsCleared() {
        val payload =
            buildSavedServersPersistencePayload(
                savedServers =
                    listOf(
                        SavedServer(
                            id = "manual-opencode",
                            name = "OpenCode",
                            host = "127.0.0.1",
                            port = 4096,
                            source = "manual",
                            backendKind = BackendKind.OPENCODE.rawValue(),
                            hasCodexServer = false,
                            username = null,
                            password = null,
                            directory = "/workspace/demo",
                        ),
                    ),
                includeCredentials = true,
            )

        val saved = payload.getJSONObject(0)
        assertTrue(saved.has("username"))
        assertTrue(saved.has("password"))
        assertEquals(true, saved.isNull("username"))
        assertEquals(true, saved.isNull("password"))
    }
}
