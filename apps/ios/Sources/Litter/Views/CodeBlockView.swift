import SwiftUI
import UIKit
import Highlightr

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(LitterTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(.caption2))
                        .foregroundColor(copied ? LitterTheme.accent : LitterTheme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if let highlighted = CodeBlockHighlighter.shared.highlight(code: code, language: language) {
                        Text(highlighted)
                            .textSelection(.enabled)
                    } else {
                        Text(code)
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(Color(hex: "#CCCCCC"))
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(hex: "#111111").opacity(0.8))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .modifier(GlassRectModifier(cornerRadius: 8))
    }
}

@MainActor
private final class CodeBlockHighlighter {
    static let shared = CodeBlockHighlighter()

    private let highlightr: Highlightr? = {
        let highlighter = Highlightr()
        highlighter?.setTheme(to: "atom-one-dark")
        return highlighter
    }()
    private var cache: [String: AttributedString] = [:]

    func highlight(code: String, language: String) -> AttributedString? {
        let key = cacheKey(code: code, language: language)
        if let cached = cache[key] {
            return cached
        }
        guard let highlightr else { return nil }
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = highlightr.highlight(code, as: normalized.isEmpty ? nil : normalized)
        guard let attributed else { return nil }
        guard let rendered = try? AttributedString(attributed, including: \.uiKit) else {
            return nil
        }
        cache[key] = rendered
        if cache.count > 256 {
            cache.removeAll(keepingCapacity: true)
        }
        return rendered
    }

    private func cacheKey(code: String, language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
        var hasher = Hasher()
        hasher.combine(normalized)
        hasher.combine(code)
        return "\(hasher.finalize())"
    }
}
