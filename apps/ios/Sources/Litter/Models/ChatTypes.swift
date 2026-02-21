import Foundation

enum MessageRole {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    var text: String
    var images: [ChatImage] = []
    let timestamp = Date()
}

struct ChatImage: Identifiable {
    let id = UUID()
    let data: Data
}

enum ConversationStatus {
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
