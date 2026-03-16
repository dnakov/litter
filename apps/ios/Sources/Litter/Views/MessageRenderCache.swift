import Foundation
import UIKit

@MainActor
final class MessageRenderCache {
    struct AssistantSegment: Identifiable {
        enum Kind {
            case markdown(String, Int)
            case image(UIImage)
        }

        let id: String
        let kind: Kind
    }

    struct RevisionKey: Hashable {
        let messageId: String
        let revisionToken: Int
        let serverId: String
        let agentDirectoryVersion: Int
    }

    static let shared = MessageRenderCache()

    private static let decodedImageCache = NSCache<NSString, UIImage>()
    private static let inlineImagePattern = "!\\[[^\\]]*\\]\\(data:image/[^;]+;base64,([A-Za-z0-9+/=\\s]+)\\)|(?<![\\(])data:image/[^;]+;base64,([A-Za-z0-9+/=\\s]+)"
    private static let inlineImageRegex = try? NSRegularExpression(pattern: inlineImagePattern, options: [])

    private let maxEntries = 1024
    private let trimTarget = 768

    private var assistantCache: [RevisionKey: [AssistantSegment]] = [:]
    private var systemCache: [RevisionKey: ToolCallParseResult] = [:]
    private var assistantAccessOrder: [RevisionKey] = []
    private var systemAccessOrder: [RevisionKey] = []

    var assistantEntryCount: Int { assistantCache.count }
    var systemEntryCount: Int { systemCache.count }

    func assistantSegments(
        for message: ChatMessage,
        key: RevisionKey
    ) -> [AssistantSegment] {
        assistantSegments(
            text: message.text,
            messageId: message.id.uuidString,
            key: key
        )
    }

    func assistantSegments(
        text: String,
        messageId: String,
        key: RevisionKey
    ) -> [AssistantSegment] {
        if let cached = assistantCache[key] {
            touch(&assistantAccessOrder, key: key)
            return cached
        }

        let parsed = extractInlineSegments(from: text, messageId: messageId, key: key)
        assistantCache[key] = parsed
        touch(&assistantAccessOrder, key: key)
        trimIfNeeded(&assistantCache, accessOrder: &assistantAccessOrder)
        return parsed
    }

    func systemParseResult(
        for message: ChatMessage,
        key: RevisionKey,
        resolveTargetLabel: ((String) -> String?)?
    ) -> ToolCallParseResult {
        if let cached = systemCache[key] {
            touch(&systemAccessOrder, key: key)
            return cached
        }

        let parsed = ToolCallMessageParser.parse(
            message: message,
            resolveTargetLabel: resolveTargetLabel
        )
        systemCache[key] = parsed
        touch(&systemAccessOrder, key: key)
        trimIfNeeded(&systemCache, accessOrder: &systemAccessOrder)
        return parsed
    }

    func reset() {
        assistantCache.removeAll(keepingCapacity: false)
        systemCache.removeAll(keepingCapacity: false)
        assistantAccessOrder.removeAll(keepingCapacity: false)
        systemAccessOrder.removeAll(keepingCapacity: false)
    }

    static func makeRevisionKey(
        for message: ChatMessage,
        serverId: String?,
        agentDirectoryVersion: Int,
        isStreaming: Bool
    ) -> RevisionKey {
        RevisionKey(
            messageId: message.id.uuidString,
            revisionToken: stableRevisionToken(for: message, isStreaming: isStreaming),
            serverId: serverId ?? "<nil>",
            agentDirectoryVersion: agentDirectoryVersion
        )
    }

    static func makeRevisionKey(
        for item: ConversationItem,
        serverId: String?,
        agentDirectoryVersion: Int,
        isStreaming: Bool
    ) -> RevisionKey {
        RevisionKey(
            messageId: item.id,
            revisionToken: stableRevisionToken(for: item, isStreaming: isStreaming),
            serverId: serverId ?? "<nil>",
            agentDirectoryVersion: agentDirectoryVersion
        )
    }

    static func stableRevisionToken(for message: ChatMessage, isStreaming: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(message.renderDigest)
        hasher.combine(isStreaming)
        return hasher.finalize()
    }

    static func stableRevisionToken(for item: ConversationItem, isStreaming: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(item.renderDigest)
        hasher.combine(isStreaming)
        return hasher.finalize()
    }

    private func touch<Key: Hashable>(_ accessOrder: inout [Key], key: Key) {
        if let existingIndex = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: existingIndex)
        }
        accessOrder.append(key)
    }

    private func trimIfNeeded<Key: Hashable, Value>(
        _ cache: inout [Key: Value],
        accessOrder: inout [Key]
    ) {
        guard cache.count > maxEntries else { return }
        while cache.count > trimTarget, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func extractInlineSegments(
        from text: String,
        messageId: String,
        key: RevisionKey
    ) -> [AssistantSegment] {
        if !text.contains("data:image/") {
            return [AssistantSegment(
                id: "text-0-\(text.count)",
                kind: .markdown(text, key.revisionToken)
            )]
        }

        guard let regex = Self.inlineImageRegex else {
            return [AssistantSegment(
                id: "text-0-\(text.count)",
                kind: .markdown(text, key.revisionToken)
            )]
        }

        var segments: [AssistantSegment] = []
        var lastEnd = text.startIndex
        let nsRange = NSRange(text.startIndex..., in: text)

        for match in regex.matches(in: text, range: nsRange) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let matchLower = text.distance(from: text.startIndex, to: matchRange.lowerBound)
            let matchUpper = text.distance(from: text.startIndex, to: matchRange.upperBound)

            if lastEnd < matchRange.lowerBound {
                let preceding = String(text[lastEnd..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preceding.isEmpty {
                    let fragmentId = "assistant-\(matchLower)-\(matchUpper)"
                    segments.append(
                        AssistantSegment(
                            id: "text-\(text.distance(from: text.startIndex, to: lastEnd))-\(matchLower)",
                            kind: .markdown(
                                preceding,
                                stableFragmentIdentity(key: key, fragmentId: fragmentId)
                            )
                        )
                    )
                }
            }

            let base64String: String?
            if match.range(at: 1).location != NSNotFound, let range = Range(match.range(at: 1), in: text) {
                base64String = String(text[range])
            } else if match.range(at: 2).location != NSNotFound, let range = Range(match.range(at: 2), in: text) {
                base64String = String(text[range])
            } else {
                base64String = nil
            }

            if let base64String,
               let data = Data(
                   base64Encoded: base64String.filter { !$0.isWhitespace },
                   options: .ignoreUnknownCharacters
               ),
               let image = Self.decodedImage(
                   from: data,
                   cacheKey: "assistant-\(messageId)-\(matchLower)-\(matchUpper)"
               ) {
                segments.append(
                    AssistantSegment(
                        id: "image-\(matchLower)-\(matchUpper)",
                        kind: .image(image)
                    )
                )
            }

            lastEnd = matchRange.upperBound
        }

        if lastEnd < text.endIndex {
            let remaining = String(text[lastEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                let startOffset = text.distance(from: text.startIndex, to: lastEnd)
                let fragmentId = "assistant-tail-\(startOffset)-\(text.count)"
                segments.append(
                    AssistantSegment(
                        id: "text-\(startOffset)-\(text.count)",
                        kind: .markdown(
                            remaining,
                            stableFragmentIdentity(key: key, fragmentId: fragmentId)
                        )
                    )
                )
            }
        }

        return segments.isEmpty
            ? [AssistantSegment(
                id: "text-0-\(text.count)",
                kind: .markdown(text, key.revisionToken)
            )]
            : segments
    }

    private func stableFragmentIdentity(key: RevisionKey, fragmentId: String) -> Int {
        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(fragmentId)
        return hasher.finalize()
    }

    private static func decodedImage(from data: Data, cacheKey: String) -> UIImage? {
        let key = cacheKey as NSString
        if let cached = decodedImageCache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(data: data) else {
            return nil
        }
        decodedImageCache.setObject(image, forKey: key)
        return image
    }
}
