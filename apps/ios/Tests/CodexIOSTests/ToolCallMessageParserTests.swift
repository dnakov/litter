import XCTest
@testable import Litter

final class ToolCallMessageParserTests: XCTestCase {
    func testParsesAllToolKinds() {
        let fixtures: [(String, ToolCallKind)] = [
            ("### Command Execution\nStatus: completed\n\nCommand:\n```bash\necho hello\n```", .commandExecution),
            ("### Command Output\n```text\nchunk\n```", .commandOutput),
            ("### File Change\nStatus: completed\n\nPath: /tmp/a.txt\nKind: update\n\n```diff\n@@ -1 +1 @@\n-a\n+b\n```", .fileChange),
            ("### File Diff\n```diff\n@@ -1 +1 @@\n-a\n+b\n```", .fileDiff),
            ("### MCP Tool Call\nStatus: completed\nTool: web/search", .mcpToolCall),
            ("### MCP Tool Progress\nIndexing workspace", .mcpToolProgress),
            ("### Web Search\nQuery: codex parser", .webSearch),
            ("### Collaboration\nStatus: inProgress\nTool: ask_agent", .collaboration),
            ("### Image View\nPath: /tmp/screenshot.png", .imageView)
        ]

        for (text, expectedKind) in fixtures {
            let model = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: text)))
            XCTAssertEqual(model.kind, expectedKind)
        }
    }

    func testWebSearchWithoutStatusDefaultsToCompleted() {
        let text = """
        ### Web Search
        Query: codex parser
        """
        let model = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: text)))
        XCTAssertEqual(model.kind, .webSearch)
        XCTAssertEqual(model.status, .completed)
        XCTAssertEqual(model.summary, "codex parser")
    }

    func testWebSearchTypeAliasesDecodeInResumedItems() throws {
        let aliases = ["webSearch", "web_search", "web-search", "websearch"]

        for alias in aliases {
            let json = """
            {
              "type": "\(alias)",
              "query": "swift async",
              "action": { "type": "search", "source": "web" }
            }
            """
            let item = try JSONDecoder().decode(ResumedThreadItem.self, from: Data(json.utf8))

            guard case .webSearch(let query, let action) = item else {
                XCTFail("Expected .webSearch for alias \(alias)")
                continue
            }

            XCTAssertEqual(query, "swift async")
            XCTAssertNotNil(action)
        }
    }

    func testMalformedFenceFallsBackToTextSection() {
        let text = """
        ### Command Output
        Output:
        ```text
        partial line
        """
        let model = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: text)))
        XCTAssertEqual(model.kind, .commandOutput)
        XCTAssertTrue(model.sections.contains { section in
            if case .text(let label, _) = section {
                return label == "Output"
            }
            return false
        })
    }

    func testMissingHeadingReturnsUnrecognized() {
        let text = """
        Command Execution
        Status: completed
        """
        XCTAssertEqual(
            ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: text)),
            .unrecognized
        )
    }

    func testFileChangeMultipleEntriesParsesRepeatedSections() {
        let text = """
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
        """
        let model = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: text)))
        XCTAssertEqual(model.summary, "a.txt +1 files")
        let changeMetadataCount = model.sections.filter {
            if case .kv(let label, _) = $0 {
                return label.hasPrefix("Change ")
            }
            return false
        }.count
        XCTAssertEqual(changeMetadataCount, 2)
    }

    func testMcpWithoutArgumentsStillRecognized() {
        let text = """
        ### MCP Tool Call
        Status: inProgress
        Tool: fs/read
        """
        let model = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: text)))
        XCTAssertEqual(model.kind, .mcpToolCall)
        XCTAssertEqual(model.status, .inProgress)
        XCTAssertEqual(model.summary, "fs/read (in progress)")
    }

    func testScalarAndInvalidJsonHandling() {
        let scalar = """
        ### Web Search
        Query: numbers

        Action:
        42
        """
        let scalarModel = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: scalar)))
        XCTAssertTrue(scalarModel.sections.contains { section in
            if case .json(let label, let content) = section {
                return label == "Action" && content == "42"
            }
            return false
        })

        let invalid = """
        ### MCP Tool Call
        Status: completed
        Tool: server/tool

        Result:
        { this is not valid json
        """
        let invalidModel = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: invalid)))
        XCTAssertTrue(invalidModel.sections.contains { section in
            if case .text(let label, _) = section {
                return label == "Result"
            }
            return false
        })
    }

    func testFailedCardsDefaultExpandedAndSectionOrder() {
        let text = """
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
        """
        let model = unwrap(ToolCallMessageParser.parse(message: ChatMessage(role: .system, text: text)))
        XCTAssertEqual(model.status, .failed)
        XCTAssertTrue(model.defaultExpanded)

        let labels = model.sections.compactMap(sectionLabel)
        XCTAssertEqual(labels.first, "Metadata")
        XCTAssertLessThan(labels.firstIndex(of: "Command") ?? .max, labels.firstIndex(of: "Output") ?? .max)
        XCTAssertLessThan(labels.firstIndex(of: "Output") ?? .max, labels.firstIndex(of: "Progress") ?? .max)
    }

    private func unwrap(
        _ result: ToolCallParseResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ToolCallCardModel {
        guard case .recognized(let model) = result else {
            XCTFail("Expected recognized parse result", file: file, line: line)
            return ToolCallCardModel(
                kind: .commandExecution,
                title: "",
                summary: "",
                status: .unknown,
                duration: nil,
                sections: []
            )
        }
        return model
    }

    private func sectionLabel(_ section: ToolCallSection) -> String? {
        switch section {
        case .kv(let label, _): return label
        case .code(let label, _, _): return label
        case .json(let label, _): return label
        case .diff(let label, _): return label
        case .text(let label, _): return label
        case .list(let label, _): return label
        case .progress(let label, _): return label
        }
    }
}
