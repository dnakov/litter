import Foundation
import Observation

/// Thin Swift wrapper over the Rust-side MessageRecorder.
/// Recording/serialization happens entirely in Rust using the upstream protocol
/// types (ServerNotification, ClientRequest) which already have serde.
/// Swift just manages file I/O and replay lifecycle.
@MainActor
@Observable
final class MessageRecorder {
    static let shared = MessageRecorder()

    private(set) var isRecording = false
    private(set) var isReplaying = false
    private var replayTask: Task<Void, Never>?

    // MARK: - Recording

    func startRecording(store: AppStore) {
        store.startRecording()
        isRecording = true
    }

    @discardableResult
    func stopRecording(store: AppStore) -> URL? {
        let json = store.stopRecording()
        isRecording = false
        guard !json.isEmpty, json != "[]" else { return nil }

        let dir = Self.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Replay

    func startReplay(url: URL, store: AppStore, targetKey: ThreadKey) {
        stopReplay()
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return }
        isReplaying = true
        replayTask = Task { [weak self] in
            do {
                try await store.startReplay(data: data, targetKey: targetKey)
            } catch {
                NSLog("[MessageRecorder] replay error: \(error)")
            }
            await MainActor.run { self?.isReplaying = false }
        }
    }

    func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        isReplaying = false
    }

    // MARK: - File management

    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings", isDirectory: true)
    }

    func listRecordings() -> [URL] {
        let dir = Self.recordingsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func deleteRecording(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
