package com.litter.android.ui.home

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedAssistantMessageData
import uniffi.codex_mobile_client.HydratedCommandActionData
import uniffi.codex_mobile_client.HydratedCommandActionKind
import uniffi.codex_mobile_client.HydratedCommandExecutionData
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HydratedDynamicToolCallData
import uniffi.codex_mobile_client.HydratedFileChangeData
import uniffi.codex_mobile_client.HydratedFileChangeEntryData
import uniffi.codex_mobile_client.HydratedMcpToolCallData
import uniffi.codex_mobile_client.HydratedUserMessageData
import uniffi.codex_mobile_client.HydratedWebSearchData

class HomeDashboardSupportTest {

    // ─────── fixtures ───────

    private fun item(
        id: String,
        content: HydratedConversationItemContent,
        turn: String? = "turn-1",
        ts: Double? = 1_000.0,
    ): HydratedConversationItem = HydratedConversationItem(
        id = id,
        content = content,
        sourceTurnId = turn,
        sourceTurnIndex = null,
        timestamp = ts,
        isFromUserTurnBoundary = false,
    )

    private fun command(
        command: String = "ls",
        status: AppOperationStatus = AppOperationStatus.COMPLETED,
        actions: List<HydratedCommandActionKind> = emptyList(),
    ): HydratedConversationItemContent.CommandExecution =
        HydratedConversationItemContent.CommandExecution(
            HydratedCommandExecutionData(
                command = command,
                cwd = "/tmp",
                status = status,
                output = null,
                exitCode = null,
                durationMs = null,
                processId = null,
                actions = actions.map {
                HydratedCommandActionData(
                    kind = it,
                    command = "",
                    name = null,
                    path = null,
                    query = null,
                )
            },
            ),
        )

    private fun assistant(text: String): HydratedConversationItemContent.Assistant =
        HydratedConversationItemContent.Assistant(
            HydratedAssistantMessageData(
                text = text,
                agentNickname = null,
                agentRole = null,
                phase = null,
            ),
        )

    private fun user(text: String): HydratedConversationItemContent.User =
        HydratedConversationItemContent.User(
            HydratedUserMessageData(text = text, imageDataUris = emptyList()),
        )

    private fun mcp(
        tool: String,
        status: AppOperationStatus = AppOperationStatus.COMPLETED,
    ): HydratedConversationItemContent.McpToolCall =
        HydratedConversationItemContent.McpToolCall(
            HydratedMcpToolCallData(
                server = "srv",
                tool = tool,
                status = status,
                durationMs = null,
                argumentsJson = null,
                contentSummary = null,
                structuredContentJson = null,
                rawOutputJson = null,
                errorMessage = null,
                progressMessages = emptyList(),
                computerUse = null,
            ),
        )

    private fun dynamic(
        tool: String,
        status: AppOperationStatus = AppOperationStatus.COMPLETED,
    ): HydratedConversationItemContent.DynamicToolCall =
        HydratedConversationItemContent.DynamicToolCall(
            HydratedDynamicToolCallData(
                tool = tool,
                status = status,
                durationMs = null,
                success = null,
                argumentsJson = null,
                contentSummary = null,
            ),
        )

    private fun fileChange(
        status: AppOperationStatus = AppOperationStatus.COMPLETED,
        paths: List<String> = listOf("src/main.kt"),
    ): HydratedConversationItemContent.FileChange =
        HydratedConversationItemContent.FileChange(
            HydratedFileChangeData(
                status = status,
                changes = paths.map {
                    HydratedFileChangeEntryData(
                        path = it,
                        kind = "modify",
                        diff = "",
                        additions = 0u,
                        deletions = 0u,
                    )
                },
            ),
        )

    private fun webSearch(
        query: String,
        inProgress: Boolean = false,
    ): HydratedConversationItemContent.WebSearch =
        HydratedConversationItemContent.WebSearch(
            HydratedWebSearchData(
                query = query,
                actionJson = null,
                isInProgress = inProgress,
            ),
        )

    // ─────── isToolCallRunning ───────

    @Test
    fun `isToolCallRunning is false on empty items`() {
        assertFalse(isToolCallRunning(emptyList()))
    }

    @Test
    fun `isToolCallRunning reports latest in-progress command`() {
        val items = listOf(
            item("a", command(status = AppOperationStatus.COMPLETED)),
            item("b", command(status = AppOperationStatus.IN_PROGRESS)),
        )
        assertTrue(isToolCallRunning(items))
    }

    @Test
    fun `isToolCallRunning returns false when last tool item is complete`() {
        val items = listOf(
            item("a", command(status = AppOperationStatus.IN_PROGRESS)),
            item("b", command(status = AppOperationStatus.COMPLETED)),
        )
        assertFalse(isToolCallRunning(items))
    }

    @Test
    fun `isToolCallRunning treats pending fileChange as running`() {
        val items = listOf(item("a", fileChange(status = AppOperationStatus.PENDING)))
        assertTrue(isToolCallRunning(items))
    }

    @Test
    fun `isToolCallRunning skips non-tool items to find last tool`() {
        val items = listOf(
            item("a", command(status = AppOperationStatus.IN_PROGRESS)),
            item("b", assistant("thinking...")),
            item("c", user("hi")),
        )
        assertTrue(isToolCallRunning(items))
    }

    @Test
    fun `isToolCallRunning checks mcp and dynamic tool calls`() {
        assertTrue(
            isToolCallRunning(
                listOf(item("a", mcp("srv", AppOperationStatus.IN_PROGRESS))),
            ),
        )
        assertTrue(
            isToolCallRunning(
                listOf(item("a", dynamic("srv", AppOperationStatus.IN_PROGRESS))),
            ),
        )
    }

    // ─────── lastTurnBounds ───────

    @Test
    fun `lastTurnBounds returns null when no source turn id`() {
        val items = listOf(item("a", assistant("x"), turn = null))
        assertNull(lastTurnBounds(items, isActive = false))
    }

    @Test
    fun `lastTurnBounds picks latest turn id and its min+max timestamps`() {
        val items = listOf(
            item("a", assistant("x"), turn = "t1", ts = 100.0),
            item("b", assistant("y"), turn = "t1", ts = 200.0),
            item("c", assistant("z"), turn = "t2", ts = 300.0),
            item("d", assistant("w"), turn = "t2", ts = 500.0),
        )
        val bounds = lastTurnBounds(items, isActive = false)
        assertNotNull(bounds)
        assertEquals(300.0, bounds!!.startSeconds, 0.0)
        assertEquals(500.0, bounds.endSeconds!!, 0.0)
    }

    @Test
    fun `lastTurnBounds end is null when isActive`() {
        val items = listOf(
            item("a", assistant("x"), turn = "t1", ts = 100.0),
            item("b", assistant("y"), turn = "t1", ts = 200.0),
        )
        val bounds = lastTurnBounds(items, isActive = true)
        assertNotNull(bounds)
        assertEquals(100.0, bounds!!.startSeconds, 0.0)
        assertNull(bounds.endSeconds)
    }

    // ─────── hydratedToolRows ───────

    @Test
    fun `hydratedToolRows groups consecutive exploration commands`() {
        val items = listOf(
            item(
                "a",
                command(
                    status = AppOperationStatus.COMPLETED,
                    actions = listOf(HydratedCommandActionKind.READ),
                ),
            ),
            item(
                "b",
                command(
                    status = AppOperationStatus.COMPLETED,
                    actions = listOf(HydratedCommandActionKind.SEARCH),
                ),
            ),
            item("c", command(command = "cargo build", status = AppOperationStatus.COMPLETED)),
        )
        val rows = hydratedToolRows(items, limit = 10)
        assertEquals(2, rows.size)
        assertTrue(rows[0] is HomeToolRow.Exploration)
        assertEquals("Explored 1 file, 1 search", (rows[0] as HomeToolRow.Exploration).summary)
        assertTrue(rows[1] is HomeToolRow.Tool)
        assertEquals("$", (rows[1] as HomeToolRow.Tool).icon)
        assertEquals("cargo build", (rows[1] as HomeToolRow.Tool).detail)
    }

    @Test
    fun `hydratedToolRows uses Exploring prefix when any exploration item in-progress`() {
        val items = listOf(
            item(
                "a",
                command(
                    status = AppOperationStatus.IN_PROGRESS,
                    actions = listOf(HydratedCommandActionKind.READ),
                ),
            ),
            item(
                "b",
                command(
                    status = AppOperationStatus.COMPLETED,
                    actions = listOf(HydratedCommandActionKind.READ),
                ),
            ),
        )
        val rows = hydratedToolRows(items, limit = 5)
        assertEquals(1, rows.size)
        assertEquals(
            "Exploring 2 files",
            (rows[0] as HomeToolRow.Exploration).summary,
        )
    }

    @Test
    fun `hydratedToolRows enforces limit by taking suffix`() {
        val items = (1..6).map {
            item("cmd-$it", command(command = "echo $it"))
        }
        val rows = hydratedToolRows(items, limit = 3)
        assertEquals(3, rows.size)
        assertEquals("echo 4", (rows[0] as HomeToolRow.Tool).detail)
        assertEquals("echo 6", (rows[2] as HomeToolRow.Tool).detail)
    }

    @Test
    fun `hydratedToolRows maps file change to edit row with basenames`() {
        val items = listOf(
            item(
                "a",
                fileChange(paths = listOf("src/one.kt", "src/two.kt", "src/three.kt", "src/four.kt")),
            ),
        )
        val rows = hydratedToolRows(items, limit = 10)
        assertEquals(1, rows.size)
        val tool = rows[0] as HomeToolRow.Tool
        assertEquals("✎", tool.icon)
        assertEquals("one.kt, two.kt, three.kt +1", tool.detail)
    }

    @Test
    fun `hydratedToolRows maps web search with fallback detail`() {
        val items = listOf(
            item("a", webSearch(query = "")),
            item("b", webSearch(query = "kotlin coroutines")),
        )
        val rows = hydratedToolRows(items, limit = 10)
        assertEquals(2, rows.size)
        assertEquals("search", (rows[0] as HomeToolRow.Tool).detail)
        assertEquals("kotlin coroutines", (rows[1] as HomeToolRow.Tool).detail)
    }

    @Test
    fun `hydratedToolRows command uses first line trimmed`() {
        val items = listOf(item("a", command(command = "  echo hi  \nexit 0")))
        val rows = hydratedToolRows(items, limit = 1)
        assertEquals("echo hi", (rows[0] as HomeToolRow.Tool).detail)
    }

    // ─────── explorationSummary ───────

    @Test
    fun `explorationSummary counts each action kind`() {
        val items = listOf(
            item(
                "a",
                command(
                    actions = listOf(
                        HydratedCommandActionKind.READ,
                        HydratedCommandActionKind.READ,
                        HydratedCommandActionKind.SEARCH,
                        HydratedCommandActionKind.LIST_FILES,
                    ),
                ),
            ),
        )
        assertEquals("Explored 2 files, 1 search, 1 listing", explorationSummary(items, "Explored"))
    }

    @Test
    fun `explorationSummary falls back to step count when no actions`() {
        val items = listOf(
            item("a", command(actions = emptyList())),
            item("b", command(actions = emptyList())),
        )
        assertEquals("Explored 2 steps", explorationSummary(items, "Explored"))
    }

    @Test
    fun `explorationSummary singular step`() {
        val items = listOf(item("a", command(actions = emptyList())))
        assertEquals("Exploring 1 step", explorationSummary(items, "Exploring"))
    }

    // ─────── toolIconForName ───────

    @Test
    fun `toolIconForName maps known names`() {
        assertEquals("$", toolIconForName("Bash"))
        assertEquals("✎", toolIconForName("Edit"))
        assertEquals("mcp", toolIconForName("MCP"))
        assertEquals("tool", toolIconForName("Tool"))
    }

    @Test
    fun `toolIconForName returns name for unknown`() {
        assertEquals("Custom", toolIconForName("Custom"))
    }

    // ─────── displayedAssistantMessage ───────

    @Test
    fun `displayedAssistantMessage returns latest non-empty assistant`() {
        val items = listOf(
            item("a", assistant("first message")),
            item("b", assistant("second message")),
            item("c", assistant("   ")),
        )
        val m = displayedAssistantMessage(items)
        assertNotNull(m)
        assertEquals("b", m!!.id)
        assertEquals("second message", m.text)
    }

    @Test
    fun `displayedAssistantMessage returns null when all assistant items blank`() {
        val items = listOf(
            item("a", assistant("")),
            item("b", assistant("   ")),
        )
        assertNull(displayedAssistantMessage(items))
    }

    @Test
    fun `displayedAssistantMessage ignores non-assistant items`() {
        val items = listOf(
            item("u1", user("question")),
            item("a1", assistant("answer")),
            item("c1", command()),
        )
        val m = displayedAssistantMessage(items)
        assertEquals("a1", m?.id)
        assertEquals("answer", m?.text)
    }
}
