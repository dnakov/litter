import XCTest
@testable import Litter

@MainActor
final class ConversationPlanSemanticsTests: XCTestCase {
    func testResumedPlanItemDecodesAsProposedPlan() throws {
        let data = """
        {
          "type": "plan",
          "id": "plan-1",
          "text": "# Final plan\\n- first\\n- second\\n"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(ResumedThreadItem.self, from: data)

        guard case .proposedPlan(let content, _) = item else {
            return XCTFail("Expected proposed plan item")
        }
        XCTAssertEqual(content, "# Final plan\n- first\n- second\n")
    }

    func testResumedTodoListDecodesChecklistEntries() throws {
        let data = """
        {
          "type": "todo-list",
          "id": "todo-1",
          "plan": [
            { "step": "Inspect renderer", "status": "completed" },
            { "step": "Patch iOS client", "status": "in_progress" }
          ]
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(ResumedThreadItem.self, from: data)

        guard case .todoList(let entries, _) = item else {
            return XCTFail("Expected todo list item")
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].step, "Inspect renderer")
        XCTAssertEqual(entries[0].status, "completed")
        XCTAssertEqual(entries[1].step, "Patch iOS client")
        XCTAssertEqual(entries[1].status, "in_progress")
    }

}
