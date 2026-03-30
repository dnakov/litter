import Foundation

// MARK: - Dynamic Tool Spec (sent on thread/start)

struct DynamicToolSpecParams: Encodable {
    let name: String
    let description: String
    let inputSchema: AnyEncodable

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }

    func rpcSpec(deferLoading: Bool = false) throws -> AppDynamicToolSpec {
        try AppDynamicToolSpec(
            name: name,
            description: description,
            inputSchema: JsonValue(encodable: inputSchema),
            deferLoading: deferLoading
        )
    }
}

// MARK: - Dynamic Tool Call Helpers

/// Parsed dynamic tool call from raw JSON server request params.
struct ParsedDynamicToolCall {
    let threadId: String
    let turnId: String
    let callId: String
    let tool: String
    let arguments: [String: Any]

    init?(from dict: [String: Any]) {
        guard let threadId = dict["threadId"] as? String,
              let turnId = dict["turnId"] as? String,
              let callId = dict["callId"] as? String,
              let tool = dict["tool"] as? String else {
            return nil
        }
        self.threadId = threadId
        self.turnId = turnId
        self.callId = callId
        self.tool = tool
        self.arguments = dict["arguments"] as? [String: Any] ?? [:]
    }
}

/// Convenience builder for dynamic tool call responses sent back to the server.
struct DynamicToolResult {
    let contentItems: [[String: Any]]
    let success: Bool

    var asDictionary: [String: Any] {
        ["contentItems": contentItems, "success": success]
    }

    static func text(_ text: String) -> DynamicToolResult {
        DynamicToolResult(
            contentItems: [["type": "inputText", "text": text]],
            success: true
        )
    }

    static func error(_ message: String) -> DynamicToolResult {
        DynamicToolResult(
            contentItems: [["type": "inputText", "text": message]],
            success: false
        )
    }
}
