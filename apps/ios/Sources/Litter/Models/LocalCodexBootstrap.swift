#if targetEnvironment(macCatalyst)
import Foundation
import UIKit

/// Bootstraps a local `codex app-server` on the host Mac when running on
/// the unsandboxed (direct-distribution) Catalyst lane. Sandboxed Catalyst
/// (Mac App Store) and iOS skip this entirely — they have no permission to
/// spawn child processes.
@MainActor
final class LocalCodexBootstrap {
    static let shared = LocalCodexBootstrap()

    /// Reserved server id used for the bundled "Local Mac" entry. Matches
    /// the pre-existing convention in `SavedServerStore.reconnectRecords`.
    static let serverId = "local-mac"

    /// The codex app-server WebSocket port. Hard-coded for now; the
    /// onboarding plan also pins this for the iPhone↔Mac pairing flow.
    static let port: UInt16 = 8390

    private let appClient = AppClient()

    /// Strong reference to the spawned process handle. Kept alive for the
    /// lifetime of the app so the child is not orphaned.
    private var processHandle: LocalServerProcessHandle?

    /// Connected server id returned by the Rust transport layer. Empty
    /// until `attachOrSpawn()` succeeds.
    private(set) var connectedServerId: String?

    private var bootstrapTask: Task<Void, Never>?

    private init() {}

    /// Kick off attach-or-spawn in the background and connect the result
    /// as a first-class server. Safe to call multiple times — subsequent
    /// calls are no-ops while a previous attempt is in flight or has
    /// already produced a `connectedServerId`.
    func startIfNeeded(appModel: AppModel) {
        guard LitterPlatform.isDirectDistMac else { return }
        guard connectedServerId == nil, bootstrapTask == nil else { return }

        let id = Self.serverId
        let port = Self.port

        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            defer { self.bootstrapTask = nil }
            do {
                let result = try await self.appClient.attachOrSpawnLocalServer(
                    port: port,
                    codexHome: nil
                )
                self.processHandle = result.handle
                LLog.info(
                    "local-codex",
                    "attach-or-spawn succeeded",
                    fields: [
                        "port": Int(result.port),
                        "attached": result.attachedToExisting,
                        "spawnedPid": result.handle != nil ? "yes" : "no",
                        "codexPath": result.codexPath ?? "(unknown)"
                    ]
                )

                let displayName = Self.displayName()
                let connectedId = try await appModel.serverBridge.connectRemoteServer(
                    serverId: id,
                    displayName: displayName,
                    host: result.host,
                    port: result.port
                )
                self.connectedServerId = connectedId
                await appModel.refreshSnapshot()
            } catch {
                LLog.error(
                    "local-codex",
                    "attach-or-spawn failed",
                    error: error
                )
            }
        }
    }

    /// Stop the spawned codex child (no-op when we attached to an
    /// externally-started process).
    func stop() async {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        if let handle = processHandle {
            processHandle = nil
            await handle.stop()
        }
    }

    /// Synchronous best-effort termination, safe to call from
    /// `applicationWillTerminate` where awaiting an async task can
    /// deadlock the main thread. Detaches the handle off the main actor
    /// and lets it terminate on the tokio runtime; we then sleep briefly
    /// (off-main where possible) for SIGTERM to take effect.
    nonisolated func stopBlocking(timeout: TimeInterval) {
        // The MainActor-isolated state is the bootstrapTask + handle. We
        // need to grab the handle on the main actor without re-entering
        // it from the calling thread (which IS the main thread during
        // willTerminate). DispatchQueue.main.sync would deadlock; instead
        // we grab `processHandle` directly via an unchecked nonisolated
        // accessor (safe because we're on the main thread already).
        let handle = MainActor.assumeIsolated { () -> LocalServerProcessHandle? in
            self.bootstrapTask?.cancel()
            self.bootstrapTask = nil
            let h = self.processHandle
            self.processHandle = nil
            return h
        }
        guard let handle else { return }

        // Spin off the actual stop on a detached Task so the tokio
        // runtime hosting `stop()` is free to run, then wait on a
        // semaphore. The Task does NOT touch the main actor, so this
        // does not deadlock with main-thread blocking.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await handle.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private static func displayName() -> String {
        // UIDevice.current.name on Catalyst returns the Mac's user-facing
        // computer name (e.g. "Daniel's MacBook Pro"). Mirrors the label
        // used by AppModel.resolvedLocalServerDisplayName.
        let device = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return device.isEmpty ? "Local Mac" : device
    }
}
#endif
