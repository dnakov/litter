package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenCodeStateModelsTest {
    @Test
    fun activeOpenCodeMetadataUsesActiveServer() {
        val slash = SlashEntry(id = "command:review", kind = SlashKind.COMMAND, name = "review", displayName = "/review")
        val agent = OpenCodeAgentOption(name = "build", description = "Default")
        val state =
            AppState(
                activeServerId = "opencode",
                slashByServerId = mapOf("opencode" to listOf(slash)),
                agentOptionsByServerId = mapOf("opencode" to listOf(agent)),
                selectedAgentByServerId = mapOf("opencode" to "build"),
            )

        assertEquals(listOf(slash), state.activeSlashEntries)
        assertEquals(listOf(agent), state.activeAgentOptions)
        assertEquals("build", state.activeAgentName)
    }

    @Test
    fun mergeOpenCodeSlashEntriesAddsMobileActions() {
        val merged =
            mergeOpenCodeSlashEntries(
                listOf(
                    SlashEntry(id = "command:init", kind = SlashKind.COMMAND, name = "init", displayName = "/init"),
                    SlashEntry(id = "command:review", kind = SlashKind.COMMAND, name = "review", displayName = "/review"),
                ),
            )

        val names = merged.map { it.name }

        assertTrue(names.contains("init"))
        assertTrue(names.contains("review"))
        assertTrue(names.contains("new"))
        assertTrue(names.contains("sessions"))
        assertTrue(names.contains("models"))
        assertTrue(names.contains("skills"))
    }

    @Test
    fun mergeOpenCodeSlashEntriesPrefersRemoteNameConflicts() {
        val remote =
            SlashEntry(
                id = "command:status",
                kind = SlashKind.COMMAND,
                name = "status",
                description = "Custom status command",
                displayName = "/status",
            )

        val merged = mergeOpenCodeSlashEntries(listOf(remote))
        val status = merged.filter { it.name == "status" }

        assertEquals(1, status.size)
        assertEquals(SlashKind.COMMAND, status.single().kind)
    }
}
