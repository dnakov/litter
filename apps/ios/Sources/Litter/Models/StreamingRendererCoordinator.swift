import Foundation
import HairballUI
import Hairball

/// Manages per-item `StreamingMarkdownRenderer` instances so streaming deltas
/// flow through `append()` and the continuous token reveal works from the first
/// token.
@MainActor
final class StreamingRendererCoordinator {
    static let shared = StreamingRendererCoordinator()

    private var renderers: [String: StreamingMarkdownRenderer] = [:]
    private var activeItemId: String?

    // MARK: - Delta feeding

    func appendDelta(_ delta: String, for itemId: String) {
        if activeItemId != itemId {
            if let oldId = activeItemId {
                renderers[oldId]?.finish()
            }
            activeItemId = itemId
        }
        let r = renderers[itemId] ?? makeRenderer(for: itemId)
        r.append(delta)
    }

    // MARK: - Renderer access

    func hasRenderer(for itemId: String) -> Bool {
        renderers[itemId] != nil
    }

    func existingRenderer(for itemId: String) -> StreamingMarkdownRenderer? {
        renderers[itemId]
    }

    func renderer(for itemId: String, currentText: String) -> StreamingMarkdownRenderer {
        if let existing = renderers[itemId] {
            return existing
        }
        let r = makeRenderer(for: itemId)
        if !currentText.isEmpty {
            r.append(currentText)
        }
        return r
    }

    func finish(itemId: String) {
        if let r = renderers.removeValue(forKey: itemId) {
            r.finish()
        }
    }

    // MARK: - Streaming lifecycle

    func finishActive() {
        for (_, r) in renderers {
            if !r.isFinished { r.finish() }
        }
        activeItemId = nil
    }

    func reset() {
        for (_, r) in renderers { r.finish() }
        renderers.removeAll()
        activeItemId = nil
    }

    // MARK: - Private

    private func makeRenderer(for itemId: String) -> StreamingMarkdownRenderer {
        let r = StreamingMarkdownRenderer(
            processors: [LatexTransformer()],
            throttleInterval: 0.016
        )
        renderers[itemId] = r
        return r
    }
}
