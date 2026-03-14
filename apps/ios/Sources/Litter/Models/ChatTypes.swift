import Foundation

enum MessageRole: Equatable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Equatable {
    var id = UUID()
    let role: MessageRole
    var text: String
    var images: [ChatImage] = []
    var sourceTurnId: String? = nil
    var sourceTurnIndex: Int? = nil
    var isFromUserTurnBoundary: Bool = false
    var agentNickname: String? = nil
    var agentRole: String? = nil
    var widgetState: WidgetState? = nil
    let timestamp = Date()
}

struct WidgetState: Equatable {
    let callId: String
    var title: String
    var widgetHTML: String
    var width: CGFloat
    var height: CGFloat
    var isFinalized: Bool = false

    static func fromArguments(_ args: [String: Any], callId: String, widgetHTML: String = "", isFinalized: Bool = false) -> WidgetState {
        WidgetState(
            callId: callId,
            title: (args["title"] as? String) ?? "Widget",
            widgetHTML: (args["widget_code"] as? String) ?? widgetHTML,
            width: CGFloat((args["width"] as? Double) ?? 800),
            height: CGFloat((args["height"] as? Double) ?? 600),
            isFinalized: isFinalized
        )
    }
}

struct ChatImage: Identifiable, Equatable {
    let id = UUID()
    let data: Data
}

enum ConversationStatus: Equatable {
    case idle
    case connecting
    case ready
    case thinking
    case error(String)
}

enum AuthStatus: Equatable {
    case unknown
    case notLoggedIn
    case apiKey
    case chatgpt(email: String)
}
