import Foundation

enum CodexError: Error {
    case startFailed(Int32)
    case alreadyRunning
    case unavailable
}

actor CodexBridge {
    static let shared = CodexBridge()
    static var isAvailable: Bool { OnDeviceCodexFeature.compiledIn }
    private var port: UInt16 = 0
    private var channel: CodexChannel?
    private var isRunning = false

    private init() {}

    /// Start the local codex server via WebSocket (legacy path).
    func ensureStarted() throws -> UInt16 {
        guard Self.isAvailable, OnDeviceCodexFeature.isEnabled else {
            throw CodexError.unavailable
        }
        if isRunning {
            return port
        }
#if LITTER_DISABLE_ON_DEVICE_CODEX
        throw CodexError.unavailable
#else
        var p: UInt16 = 0
        let result = codex_start_server(&p)
        guard result == 0 else { throw CodexError.startFailed(result) }
        port = p
        isRunning = true
        return p
#endif
    }

    /// Start the local codex server via in-process channel (no TCP, no WebSocket).
    /// The initialize handshake is performed internally by Rust.
    func ensureChannelStarted() async throws -> CodexChannel {
        guard Self.isAvailable, OnDeviceCodexFeature.isEnabled else {
            throw CodexError.unavailable
        }
        if let channel {
            if await channel.isConnected {
                return channel
            }
            self.channel = nil
        }
#if LITTER_DISABLE_ON_DEVICE_CODEX
        throw CodexError.unavailable
#else
        let ch = CodexChannel()
        try await ch.open()
        self.channel = ch
        isRunning = true
        return ch
#endif
    }

    func currentPort() -> UInt16 {
        port
    }

    func disconnectChannelIfCurrent(_ candidate: CodexChannel) async {
        if let channel, channel === candidate {
            self.channel = nil
            isRunning = false
        }
        await candidate.close()
    }

    func stop() async {
#if !LITTER_DISABLE_ON_DEVICE_CODEX
        if let channel {
            self.channel = nil
            await channel.close()
        }
        codex_stop_server()
#endif
        isRunning = false
    }
}
