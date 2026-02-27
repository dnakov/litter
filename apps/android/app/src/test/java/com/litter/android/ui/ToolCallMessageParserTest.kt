package com.litter.android.ui

import com.litter.android.state.ChatMessage
import com.litter.android.state.MessageRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolCallMessageParserTest {
    @Test
    fun parsesAllToolKinds() {
        val fixtures =
            listOf(
                "### Command Execution\nStatus: completed\n\nCommand:\n```bash\necho hello\n```" to ToolCallKind.COMMAND_EXECUTION,
                "### Command Output\n```text\nchunk\n```" to ToolCallKind.COMMAND_OUTPUT,
                "### File Change\nStatus: completed\n\nPath: /tmp/a.txt\nKind: update\n\n```diff\n@@ -1 +1 @@\n-a\n+b\n```" to ToolCallKind.FILE_CHANGE,
                "### File Diff\n```diff\n@@ -1 +1 @@\n-a\n+b\n```" to ToolCallKind.FILE_DIFF,
                "### MCP Tool Call\nStatus: completed\nTool: web/search" to ToolCallKind.MCP_TOOL_CALL,
                "### MCP Tool Progress\nIndexing workspace" to ToolCallKind.MCP_TOOL_PROGRESS,
                "### Web Search\nQuery: codex parser" to ToolCallKind.WEB_SEARCH,
                "### Collaboration\nStatus: inProgress\nTool: ask_agent" to ToolCallKind.COLLABORATION,
                "### Image View\nPath: /tmp/screenshot.png" to ToolCallKind.IMAGE_VIEW,
            )

        fixtures.forEach { (text, expectedKind) ->
            val model = unwrap(ToolCallMessageParser.parse(systemMessage(text)))
            assertEquals(expectedKind, model.kind)
        }
    }

    @Test
    fun malformedFenceFallsBackToTextSection() {
        val text =
            """
            ### Command Output
            Output:
            ```text
            partial line
            """.trimIndent()

        val model = unwrap(ToolCallMessageParser.parse(systemMessage(text)))
        assertEquals(ToolCallKind.COMMAND_OUTPUT, model.kind)
        assertTrue(
            model.sections.any { section ->
                section is ToolCallSection.Text && section.label == "Output"
            },
        )
    }

    @Test
    fun missingHeadingReturnsUnrecognized() {
        val text =
            """
            Command Execution
            Status: completed
            """.trimIndent()
        assertTrue(ToolCallMessageParser.parse(systemMessage(text)) is ToolCallParseResult.Unrecognized)
    }

    @Test
    fun fileChangeMultipleEntriesParsesRepeatedSections() {
        val text =
            """
            ### File Change
            Status: completed

            Path: /tmp/a.txt
            Kind: update

            ```diff
            @@ -1 +1 @@
            -a
            +b
            ```

            ---

            Path: /tmp/b.txt
            Kind: delete

            ```text
            old content
            ```
            """.trimIndent()

        val model = unwrap(ToolCallMessageParser.parse(systemMessage(text)))
        assertEquals("a.txt +1 files", model.summary)
        val changeMetadataCount =
            model.sections.count { section ->
                section is ToolCallSection.KeyValue && section.label.startsWith("Change ")
            }
        assertEquals(2, changeMetadataCount)
    }

    @Test
    fun mcpWithoutArgumentsStillRecognized() {
        val text =
            """
            ### MCP Tool Call
            Status: inProgress
            Tool: fs/read
            """.trimIndent()
        val model = unwrap(ToolCallMessageParser.parse(systemMessage(text)))
        assertEquals(ToolCallKind.MCP_TOOL_CALL, model.kind)
        assertEquals(ToolCallStatus.IN_PROGRESS, model.status)
        assertEquals("fs/read (in progress)", model.summary)
    }

    @Test
    fun scalarAndInvalidJsonHandling() {
        val scalar =
            """
            ### Web Search
            Query: numbers

            Action:
            42
            """.trimIndent()
        val scalarModel = unwrap(ToolCallMessageParser.parse(systemMessage(scalar)))
        assertTrue(
            scalarModel.sections.any { section ->
                section is ToolCallSection.Json && section.label == "Action" && section.content == "42"
            },
        )

        val invalid =
            """
            ### MCP Tool Call
            Status: completed
            Tool: server/tool

            Result:
            { this is not valid json
            """.trimIndent()
        val invalidModel = unwrap(ToolCallMessageParser.parse(systemMessage(invalid)))
        assertTrue(
            invalidModel.sections.any { section ->
                section is ToolCallSection.Text && section.label == "Result"
            },
        )
    }

    @Test
    fun failedCardsDefaultExpandedAndSectionOrder() {
        val text =
            """
            ### Command Execution
            Status: failed
            Duration: 12 ms
            Directory: /tmp

            Command:
            ```bash
            ls
            ```

            Output:
            ```text
            nope
            ```

            Progress:
            step one
            """.trimIndent()

        val model = unwrap(ToolCallMessageParser.parse(systemMessage(text)))
        assertEquals(ToolCallStatus.FAILED, model.status)
        assertTrue(model.defaultExpanded)

        val labels =
            model.sections.mapNotNull { section ->
                when (section) {
                    is ToolCallSection.KeyValue -> section.label
                    is ToolCallSection.Code -> section.label
                    is ToolCallSection.Json -> section.label
                    is ToolCallSection.Diff -> section.label
                    is ToolCallSection.Text -> section.label
                    is ToolCallSection.ListSection -> section.label
                    is ToolCallSection.Progress -> section.label
                }
            }

        assertEquals("Metadata", labels.first())
        assertTrue(labels.indexOf("Command") < labels.indexOf("Output"))
        assertTrue(labels.indexOf("Output") < labels.indexOf("Progress"))
    }

    private fun systemMessage(text: String): ChatMessage =
        ChatMessage(role = MessageRole.SYSTEM, text = text)

    private fun unwrap(result: ToolCallParseResult): ToolCallCardModel =
        when (result) {
            is ToolCallParseResult.Recognized -> result.model
            ToolCallParseResult.Unrecognized -> error("Expected recognized parse result")
        }
}
