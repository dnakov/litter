import Foundation
import OSLog
import UIKit

enum LLog {
    private static let subsystemRoot = Bundle.main.bundleIdentifier ?? "com.sigkitten.litter"
    private static let queue = DispatchQueue(label: "com.sigkitten.litter.logging", qos: .utility)
    private nonisolated(unsafe) static var bootstrapped = false

    private static var logs: Logs {
        LogsHolder.shared
    }

    static func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let codexHome = resolveCodexHome()
        FileManager.default.createFile(atPath: codexHome.path, contents: nil)
        setenv("CODEX_HOME", codexHome.path, 1)

        // Propagate collector config from Info.plist → env vars so Rust picks them up directly
        if let v = Bundle.main.infoDictionary?["LogCollectorURL"] as? String, !v.isEmpty {
            setenv("LOG_COLLECTOR_URL", v, 0) // don't overwrite if already set
        }

        // Seed device identity so Rust config can fill in defaults
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let deviceName = UIDevice.current.name
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

        logs.configure(
            config: LogConfig(
                enabled: false, // Rust will enable based on env vars
                collectorUrl: nil,
                minLevel: .debug,
                deviceId: deviceId,
                deviceName: deviceName,
                appVersion: appVersion,
                build: build
            )
        )
    }

    static func trace(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .trace, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func debug(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .debug, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func info(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .info, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func warn(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .warn, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func error(_ subsystem: String, _ message: String, error: Error? = nil, fields: [String: Any] = [:], payloadJson: String? = nil) {
        var allFields = fields
        if let error {
            allFields["error"] = error.localizedDescription
        }
        emit(level: .error, subsystem: subsystem, message: message, fields: allFields, payloadJson: payloadJson)
    }

    private static func emit(level: LogLevel, subsystem: String, message: String, fields: [String: Any], payloadJson: String?) {
        let logger = Logger(subsystem: subsystemRoot, category: subsystem)
        switch level {
        case .trace, .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warn:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        queue.async {
            logs.log(
                event: LogEvent(
                    timestampMs: nil,
                    level: level,
                    source: .ios,
                    subsystem: subsystem,
                    category: subsystem,
                    message: message,
                    sessionId: nil,
                    serverId: nil,
                    threadId: nil,
                    requestId: nil,
                    payloadJson: payloadJson,
                    fieldsJson: jsonString(from: fields)
                )
            )
        }
    }

    private static func resolveCodexHome() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let codexHome = base.appendingPathComponent("codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        return codexHome
    }

    private static func jsonString(from fields: [String: Any]) -> String? {
        guard !fields.isEmpty, JSONSerialization.isValidJSONObject(fields) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private enum LogsHolder {
    static let shared = Logs()
}
