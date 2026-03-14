import Foundation

// MARK: - Dynamic Tool Spec (sent on thread/start)

struct DynamicToolSpec: Encodable {
    let name: String
    let description: String
    let inputSchema: AnyEncodable

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }
}

// MARK: - Dynamic Tool Call Request (server → client via item/tool/call)

struct DynamicToolCallParams {
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

// MARK: - Dynamic Tool Call Response (client → server)

struct DynamicToolCallResponse {
    let contentItems: [[String: Any]]
    let success: Bool

    var asDictionary: [String: Any] {
        ["contentItems": contentItems, "success": success]
    }

    static func text(_ text: String) -> DynamicToolCallResponse {
        DynamicToolCallResponse(
            contentItems: [["type": "inputText", "text": text]],
            success: true
        )
    }

    static func error(_ message: String) -> DynamicToolCallResponse {
        DynamicToolCallResponse(
            contentItems: [["type": "inputText", "text": message]],
            success: false
        )
    }
}
