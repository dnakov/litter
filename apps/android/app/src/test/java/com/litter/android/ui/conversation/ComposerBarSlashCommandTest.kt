package com.litter.android.ui.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class ComposerBarSlashCommandTest {
    @Test
    fun parseSlashCommandInvocationHandlesRenameArguments() {
        val invocation = parseSlashCommandInvocation("/rename Ship It")

        assertNotNull(invocation)
        assertEquals("rename", invocation?.command?.name)
        assertEquals("Ship It", invocation?.args)
    }

    @Test
    fun parseSlashCommandInvocationRecognizesAndroidParityCommands() {
        val commands = listOf("/skills", "/permissions", "/experimental")

        val parsed = commands.mapNotNull(::parseSlashCommandInvocation)

        assertEquals(listOf("skills", "permissions", "experimental"), parsed.map { it.command.name })
    }

    @Test
    fun parseSlashCommandInvocationRejectsUnknownCommands() {
        assertNull(parseSlashCommandInvocation("/definitely-not-real"))
    }
}
