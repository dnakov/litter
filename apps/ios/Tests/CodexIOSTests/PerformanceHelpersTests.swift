import XCTest
@testable import Litter

@MainActor
final class PerformanceHelpersTests: XCTestCase {
    func testTranscriptTurnBuilderCollapsesPreviousTurnOnceANewLiveTurnStarts() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(text: "Turn 1", turnId: "turn-1", turnIndex: 0, timestamp: baseTime),
                makeAssistantItem(text: "Reply 1", turnId: "turn-1", turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.3)),
                makeUserItem(text: "Turn 2", turnId: "turn-2", turnIndex: 1, timestamp: baseTime.addingTimeInterval(1)),
                makeAssistantItem(text: "Reply 2", turnId: "turn-2", turnIndex: 1, timestamp: baseTime.addingTimeInterval(1.6)),
                makeUserItem(text: "Turn 3", turnId: "turn-3", turnIndex: 2, timestamp: baseTime.addingTimeInterval(2)),
                makeCommandItem(command: "rg status", turnId: "turn-3", turnIndex: 2, timestamp: baseTime.addingTimeInterval(4.2)),
                makeAssistantItem(text: "Reply 3", turnId: "turn-3", turnIndex: 2, timestamp: baseTime.addingTimeInterval(5.2)),
                makeUserItem(text: "Turn 4", turnId: nil, turnIndex: nil, timestamp: baseTime.addingTimeInterval(6)),
                makeAssistantItem(text: "Streaming reply", turnId: nil, turnIndex: nil, timestamp: baseTime.addingTimeInterval(6.4))
            ],
            threadStatus: .thinking,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 4)
        XCTAssertTrue(turns[0].isCollapsedByDefault)
        XCTAssertTrue(turns[1].isCollapsedByDefault)
        XCTAssertTrue(turns[2].isCollapsedByDefault)
        XCTAssertTrue(turns[3].isLive)
        XCTAssertFalse(turns[3].isCollapsedByDefault)
        XCTAssertEqual(turns[2].preview.secondaryText, "Reply 3")
        XCTAssertEqual(turns[2].preview.toolCallCount, 1)
        XCTAssertEqual(turns[2].preview.durationText, "3.2s")
    }

    func testTranscriptTurnBuilderUsesUserToAssistantDuration() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(text: "Inspect repo", turnId: "turn-1", turnIndex: 0, timestamp: baseTime),
                makeCommandItem(command: "rg repo", turnId: "turn-1", turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.2), durationMs: 840),
                makeAssistantItem(text: "Done", turnId: "turn-1", turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.84))
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].preview.durationText, "840ms")
        XCTAssertEqual(turns[0].preview.toolCallCount, 1)
    }

    func testTranscriptTurnBuilderProducesUniqueIDsWhenSourceTurnIDRepeatsAcrossBoundarySplits() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let repeatedSourceTurnId = "turn-1"
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(id: "11111111-1111-1111-1111-111111111111", text: "First question", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime),
                makeAssistantItem(id: "11111111-1111-1111-1111-111111111112", text: "First answer", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.5)),
                makeUserItem(id: "11111111-1111-1111-1111-111111111113", text: "Follow-up", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime.addingTimeInterval(1)),
                makeAssistantItem(id: "11111111-1111-1111-1111-111111111114", text: "Follow-up answer", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime.addingTimeInterval(1.5))
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(Set(turns.map(\.id)).count, 2)
        XCTAssertNotEqual(turns[0].id, turns[1].id)
    }

    func testTranscriptTurnBuilderFallsBackToExplicitDurationForRestoredHistory() {
        let restoredAt = Date(timeIntervalSince1970: 200)
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(text: "Inspect repo", turnId: "turn-1", turnIndex: 0, timestamp: restoredAt),
                makeCommandItem(command: "rg repo", turnId: "turn-1", turnIndex: 0, timestamp: restoredAt.addingTimeInterval(0.01), durationMs: 840),
                makeAssistantItem(text: "Done", turnId: "turn-1", turnIndex: 0, timestamp: restoredAt.addingTimeInterval(0.02))
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].preview.durationText, "840ms")
    }

    func testResumedThreadItemDecodesTimestamp() throws {
        let data = Data(
            """
            {
              "type": "agentMessage",
              "text": "Done",
              "timestamp": "2025-01-05T12:00:00Z"
            }
            """.utf8
        )

        let item = try JSONDecoder().decode(ResumedThreadItem.self, from: data)
        let timestamp = try XCTUnwrap(item.timestamp)
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1_736_078_400, accuracy: 0.001)
    }

    func testResumedThreadItemDecodesCreatedAtMillisecondsTimestamp() throws {
        let data = Data(
            """
            {
              "type": "agentMessage",
              "text": "Done",
              "created_at": 1736078400000
            }
            """.utf8
        )

        let item = try JSONDecoder().decode(ResumedThreadItem.self, from: data)
        let timestamp = try XCTUnwrap(item.timestamp)
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1_736_078_400, accuracy: 0.001)
    }

    func testMessageRenderCacheReusesStableAssistantRevisionKey() {
        let cache = MessageRenderCache()
        let base64Pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn8Vf0AAAAASUVORK5CYII="
        let messageText = "Hello ![](data:image/png;base64,\(base64Pixel))"
        var message = ChatMessage(role: .assistant, text: messageText)

        let key = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        XCTAssertEqual(cache.assistantEntryCount, 0)

        _ = cache.assistantSegments(for: message, key: key)
        XCTAssertEqual(cache.assistantEntryCount, 1)
        XCTAssertEqual(cache.markdownEntryCount, 1)

        _ = cache.assistantSegments(for: message, key: key)
        XCTAssertEqual(cache.assistantEntryCount, 1)
        XCTAssertEqual(cache.markdownEntryCount, 1)

        message.text += "\nMore"
        let changedKey = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        _ = cache.assistantSegments(for: message, key: changedKey)
        XCTAssertEqual(cache.assistantEntryCount, 2)
        XCTAssertEqual(cache.markdownEntryCount, 3)
    }

    func testMessageRenderCacheScopesSystemEntriesByAgentDirectoryRevision() {
        let cache = MessageRenderCache()
        let message = ChatMessage(
            role: .system,
            text: """
            ### Collaboration
            Status: completed
            Tool: ask_agent
            Targets: thread-alpha
            """
        )

        let key0 = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        let key1 = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 1,
            isStreaming: false
        )

        _ = cache.systemParseResult(for: message, key: key0, resolveTargetLabel: { _ in "Planner [lead]" })
        XCTAssertEqual(cache.systemEntryCount, 1)

        _ = cache.systemParseResult(for: message, key: key0, resolveTargetLabel: { _ in "Planner [lead]" })
        XCTAssertEqual(cache.systemEntryCount, 1)

        _ = cache.systemParseResult(for: message, key: key1, resolveTargetLabel: { _ in "Builder [worker]" })
        XCTAssertEqual(cache.systemEntryCount, 2)
    }

    func testChatMessageRenderDigestChangesWhenMarkdownChanges() {
        var message = ChatMessage(role: .assistant, text: "# Title")
        let originalDigest = message.renderDigest

        message.text = """
        # Title

        ```swift
        print("updated")
        ```
        """

        XCTAssertNotEqual(message.renderDigest, originalDigest)
    }

    private func makeUserItem(
        id: String? = nil,
        text: String,
        turnId: String?,
        turnIndex: Int?,
        timestamp: Date
    ) -> ConversationItem {
        ConversationItem(
            id: id ?? UUID().uuidString,
            content: .user(ConversationUserMessageData(text: text, images: [])),
            sourceTurnId: turnId,
            sourceTurnIndex: turnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: true
        )
    }

    private func makeAssistantItem(
        id: String? = nil,
        text: String,
        turnId: String?,
        turnIndex: Int?,
        timestamp: Date
    ) -> ConversationItem {
        ConversationItem(
            id: id ?? UUID().uuidString,
            content: .assistant(ConversationAssistantMessageData(text: text, agentNickname: nil, agentRole: nil)),
            sourceTurnId: turnId,
            sourceTurnIndex: turnIndex,
            timestamp: timestamp
        )
    }

    private func makeCommandItem(
        command: String,
        turnId: String?,
        turnIndex: Int?,
        timestamp: Date,
        durationMs: Int? = nil
    ) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            content: .commandExecution(
                ConversationCommandExecutionData(
                    command: command,
                    cwd: "/tmp",
                    status: .completed,
                    output: nil,
                    exitCode: 0,
                    durationMs: durationMs,
                    processId: nil,
                    actions: []
                )
            ),
            sourceTurnId: turnId,
            sourceTurnIndex: turnIndex,
            timestamp: timestamp
        )
    }
}
