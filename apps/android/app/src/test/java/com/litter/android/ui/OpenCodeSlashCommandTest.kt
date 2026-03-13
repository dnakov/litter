package com.litter.android.ui

import com.litter.android.state.SlashEntry
import com.litter.android.state.SlashKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OpenCodeSlashCommandTest {
    @Test
    fun filterOpenCodeSlashEntriesUsesAliasesAndHidesUnsupportedActions() {
        val entries =
            listOf(
                SlashEntry(
                    id = "action:session.list",
                    kind = SlashKind.ACTION,
                    name = "sessions",
                    aliases = listOf("resume"),
                    description = "Switch session",
                    displayName = "/sessions",
                    actionId = "session.list",
                ),
                SlashEntry(
                    id = "action:theme.switch",
                    kind = SlashKind.ACTION,
                    name = "themes",
                    description = "Switch theme",
                    displayName = "/themes",
                    actionId = "theme.switch",
                ),
                SlashEntry(
                    id = "command:review",
                    kind = SlashKind.COMMAND,
                    name = "review",
                    description = "Review changes",
                    displayName = "/review",
                ),
            )

        val filtered = filterOpenCodeSlashEntries(entries, "res")

        assertEquals(listOf("sessions"), filtered.map { it.name })
    }

    @Test
    fun parseOpenCodeSlashInvocationResolvesAliasesAndCommandArguments() {
        val entries =
            listOf(
                SlashEntry(
                    id = "action:session.list",
                    kind = SlashKind.ACTION,
                    name = "sessions",
                    aliases = listOf("resume"),
                    displayName = "/sessions",
                    actionId = "session.list",
                ),
                SlashEntry(
                    id = "command:review",
                    kind = SlashKind.COMMAND,
                    name = "review",
                    displayName = "/review",
                ),
            )

        val action = parseOpenCodeSlashInvocation("/resume", entries)
        val command = parseOpenCodeSlashInvocation("/review staged changes", entries)

        assertEquals("session.list", action?.entry?.actionId)
        assertEquals("review", command?.entry?.name)
        assertEquals("staged changes", command?.args)
    }

    @Test
    fun parseOpenCodeSlashInvocationRejectsUnsupportedActionIds() {
        val entries =
            listOf(
                SlashEntry(
                    id = "action:theme.switch",
                    kind = SlashKind.ACTION,
                    name = "themes",
                    displayName = "/themes",
                    actionId = "theme.switch",
                ),
            )

        val invocation = parseOpenCodeSlashInvocation("/themes", entries)

        assertNull(invocation)
    }
}
