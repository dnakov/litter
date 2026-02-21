import Foundation
import Citadel
import Crypto

actor SSHSessionManager {
    static let shared = SSHSessionManager()
    private var client: SSHClient?
    private var connectedHost: String?
    private let defaultRemotePort: UInt16 = 8390

    private enum ServerLaunchCommand {
        case codex(executable: String)
        case codexAppServer(executable: String)
    }

    var isConnected: Bool { client != nil }

    func connect(host: String, port: Int = 22, credentials: SSHCredentials) async throws {
        var normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
        if !normalizedHost.contains(":"), let pct = normalizedHost.firstIndex(of: "%") {
            normalizedHost = String(normalizedHost[..<pct])
        }

        let auth: SSHAuthenticationMethod
        switch credentials {
        case .password(let username, let password):
            auth = .passwordBased(username: username, password: password)
        case .key(let username, let privateKeyPEM, let passphrase):
            let decryptionKey = passphrase?.data(using: .utf8)
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: privateKeyPEM)
            switch keyType {
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: privateKeyPEM, decryptionKey: decryptionKey)
                auth = .rsa(username: username, privateKey: key)
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: privateKeyPEM, decryptionKey: decryptionKey)
                auth = .ed25519(username: username, privateKey: key)
            default:
                throw SSHError.unsupportedKeyType
            }
        }

        do {
            client = try await SSHClient.connect(
                host: normalizedHost,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            connectedHost = normalizedHost
        } catch {
            throw SSHError.connectionFailed(host: normalizedHost, port: port, underlying: error)
        }
    }

    func startRemoteServer() async throws -> UInt16 {
        guard let client else { throw SSHError.notConnected }
        let wantsIPv6 = (connectedHost ?? "").contains(":")

        guard let launchCommand = try await resolveServerLaunchCommand(client: client) else {
            throw SSHError.serverBinaryMissing
        }

        var lastFailure = "Timed out waiting for remote server to start."
        for port in candidatePorts() {
            let listenAddr = wantsIPv6 ? "[::]:\(port)" : "0.0.0.0:\(port)"
            let logPath = "/tmp/codex-ios-app-server-\(port).log"

            // Check if already running on this port
            if let listening = try? await isPortListening(client: client, port: port), listening {
                return port
            }

            // Start server in background on selected port.
            let launchOutput = String(
                buffer: try await client.executeCommand(
                    startServerCommand(for: launchCommand, listenAddr: listenAddr, logPath: logPath)
                )
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let launchedPID = Int(launchOutput)

            // Poll until reachable.
            for attempt in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                if let listening = try? await isPortListening(client: client, port: port), listening {
                    return port
                }
                if let pid = launchedPID, let alive = try? await isProcessAlive(client: client, pid: pid), !alive {
                    let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
                    if detail.localizedCaseInsensitiveContains("address already in use") {
                        lastFailure = detail
                        break
                    }
                    throw SSHError.serverStartFailed(
                        message: detail.isEmpty ? "Server process exited immediately." : detail
                    )
                }
                // If probing is inconclusive but process is alive, let the app try connecting.
                if attempt >= 8,
                   let pid = launchedPID,
                   let alive = try? await isProcessAlive(client: client, pid: pid),
                   alive {
                    return port
                }
            }
            let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
            if detail.localizedCaseInsensitiveContains("address already in use") {
                lastFailure = detail
                continue
            }
            lastFailure = detail.isEmpty ? lastFailure : detail
            break
        }
        throw SSHError.serverStartFailed(
            message: lastFailure
        )
    }

    private func candidatePorts() -> [UInt16] {
        var ports: [UInt16] = [defaultRemotePort]
        ports.append(contentsOf: (1...20).compactMap { UInt16(exactly: Int(defaultRemotePort) + $0) })
        return ports
    }

    private func resolveServerLaunchCommand(client: SSHClient) async throws -> ServerLaunchCommand? {
        let script = """
        for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do
          [ -f "$f" ] && . "$f" 2>/dev/null
        done
        if command -v codex >/dev/null 2>&1; then
          printf 'codex:%s' "$(command -v codex)"
        elif [ -x "$HOME/.volta/bin/codex" ]; then
          printf 'codex:%s' "$HOME/.volta/bin/codex"
        elif [ -x "$HOME/.cargo/bin/codex" ]; then
          printf 'codex:%s' "$HOME/.cargo/bin/codex"
        elif command -v codex-app-server >/dev/null 2>&1; then
          printf 'codex-app-server:%s' "$(command -v codex-app-server)"
        elif [ -x "$HOME/.cargo/bin/codex-app-server" ]; then
          printf 'codex-app-server:%s' "$HOME/.cargo/bin/codex-app-server"
        fi
        """
        let output = String(buffer: try await client.executeCommand(script))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        let parts = output.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "codex": return .codex(executable: parts[1])
        case "codex-app-server": return .codexAppServer(executable: parts[1])
        default: return nil
        }
    }

    private func startServerCommand(for command: ServerLaunchCommand, listenAddr: String, logPath: String) -> String {
        let listenArg = shellQuote("ws://\(listenAddr)")
        let launch: String
        switch command {
        case .codex(let executable):
            launch = "\(shellQuote(executable)) app-server --listen \(listenArg)"
        case .codexAppServer(let executable):
            launch = "\(shellQuote(executable)) --listen \(listenArg)"
        }
        let profileInit = "for f in \"$HOME/.profile\" \"$HOME/.bash_profile\" \"$HOME/.bashrc\" \"$HOME/.zprofile\" \"$HOME/.zshrc\"; do [ -f \"$f\" ] && . \"$f\" 2>/dev/null; done;"
        return "\(profileInit) nohup \(launch) </dev/null >\(shellQuote(logPath)) 2>&1 & echo $!"
    }

    private func isPortListening(client: SSHClient, port: UInt16) async throws -> Bool {
        let out = try await client.executeCommand(
            "lsof -nP -iTCP:\(port) -sTCP:LISTEN -t 2>/dev/null | head -n 1"
        )
        return !String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func isProcessAlive(client: SSHClient, pid: Int) async throws -> Bool {
        let out = try await client.executeCommand("kill -0 \(pid) >/dev/null 2>&1 && echo alive || echo dead")
        return String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines) == "alive"
    }

    private func fetchServerLogTail(client: SSHClient, logPath: String) async throws -> String {
        let out = try await client.executeCommand("tail -n 25 \(shellQuote(logPath)) 2>/dev/null")
        return String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func executeCommand(_ command: String) async throws -> String {
        guard let client else { throw SSHError.notConnected }
        let result = try await client.executeCommand(command)
        return String(buffer: result)
    }

    func disconnect() async {
        try? await client?.close()
        client = nil
        connectedHost = nil
    }
}

enum SSHError: LocalizedError {
    case notConnected
    case serverStartTimeout
    case serverBinaryMissing
    case serverStartFailed(message: String)
    case unsupportedKeyType
    case connectionFailed(host: String, port: Int, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH not connected"
        case .serverStartTimeout: return "Timed out waiting for remote server to start"
        case .serverBinaryMissing: return "Remote host is missing `codex` (for `codex app-server`) and `codex-app-server` in PATH"
        case .serverStartFailed(let message): return message
        case .unsupportedKeyType: return "Unsupported SSH key type (only RSA and ED25519 are supported)"
        case .connectionFailed(let host, let port, _):
            return "Could not connect to \(host):\(port) — check that SSH is running and the host is reachable"
        }
    }
}
