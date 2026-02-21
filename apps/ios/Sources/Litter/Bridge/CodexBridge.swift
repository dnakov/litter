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
    private var isRunning = false

    private init() {}

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

    func currentPort() -> UInt16 {
        port
    }

    func stop() {
#if !LITTER_DISABLE_ON_DEVICE_CODEX
        codex_stop_server()
#endif
        isRunning = false
    }
}
