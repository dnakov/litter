import Foundation

struct SkillMentionSelection: Equatable {
    let name: String
    let path: String
}

enum AgentLabelFormatter {
    static func format(
        nickname: String?,
        role: String?,
        fallbackIdentifier: String? = nil
    ) -> String? {
        let cleanNickname = sanitized(nickname)
        let cleanRole = sanitized(role)
        switch (cleanNickname, cleanRole) {
        case let (nickname?, role?):
            return "\(nickname) [\(role)]"
        case let (nickname?, nil):
            return nickname
        case let (nil, role?):
            return "[\(role)]"
        default:
            return sanitized(fallbackIdentifier)
        }
    }

    static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func looksLikeDisplayLabel(_ raw: String?) -> Bool {
        guard let value = sanitized(raw),
              value.hasSuffix("]"),
              let openBracket = value.lastIndex(of: "[") else {
            return false
        }
        let nickname = value[..<openBracket].trimmingCharacters(in: .whitespacesAndNewlines)
        let roleStart = value.index(after: openBracket)
        let roleEnd = value.index(before: value.endIndex)
        let role = value[roleStart..<roleEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return !nickname.isEmpty && !role.isEmpty
    }
}
