import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH

actor SSHSessionManager {
    static let shared = SSHSessionManager()
    private var client: SSHClient?
    private var connectedHost: String?
    private var forwardedListener: Channel?
    private var forwardedLocalPort: UInt16?
    private var forwardedRemotePort: UInt16?
    private var forwardedRemoteHost: String?
    private var launchedServerPID: Int?
    private let defaultRemotePort: UInt16 = 8390

    private enum ServerLaunchCommand {
        case codex(executable: String)
        case codexAppServer(executable: String)
    }

    private struct LaunchAttempt {
        let description: String
        let shellCommand: String
    }

    var isConnected: Bool { client != nil }

    func connect(host: String, port: Int = 22, credentials: SSHCredentials) async throws {
        await disconnect()

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

    func establishLocalPortForward(remotePort: UInt16) async throws -> UInt16 {
        guard let client else { throw SSHError.notConnected }

        let remoteHost = remoteLoopbackHost()
        if forwardedRemotePort == remotePort,
           forwardedRemoteHost == remoteHost,
           let forwardedLocalPort,
           let forwardedListener,
           forwardedListener.isActive {
            return forwardedLocalPort
        }

        await closeLocalPortForward()

        let clientBox = SSHClientBox(client)
        let originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let remoteTargetHost = remoteHost
        let remoteTargetPort = Int(remotePort)

        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { localChannel in
                localChannel.eventLoop.makeCompletedFuture {
                    let localAsync = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: localChannel
                    )

                    Task {
                        do {
                            let remoteChannel = try await clientBox.client.createDirectTCPIPChannel(
                                using: SSHChannelType.DirectTCPIP(
                                    targetHost: remoteTargetHost,
                                    targetPort: remoteTargetPort,
                                    originatorAddress: originatorAddress
                                )
                            ) { channel in
                                channel.eventLoop.makeSucceededFuture(())
                            }
                            let remoteAsync = try await remoteChannel.eventLoop.flatSubmit {
                                remoteChannel.eventLoop.makeCompletedFuture(
                                    Result {
                                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                                            wrappingChannelSynchronously: remoteChannel
                                        )
                                    }
                                )
                            }.get()
                            try await proxyTraffic(between: localAsync, and: remoteAsync)
                        } catch {
                            NSLog("[SSH_PORT_FORWARD] local tunnel failed: %@", error.localizedDescription)
                            try? await localChannel.close().get()
                        }
                    }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        guard let port = listener.localAddress?.port,
              let localPort = UInt16(exactly: port) else {
            try? await listener.close().get()
            throw SSHError.portForwardFailed(message: "SSH tunnel bound without a usable localhost port")
        }

        forwardedListener = listener
        forwardedLocalPort = localPort
        forwardedRemotePort = remotePort
        forwardedRemoteHost = remoteHost
        return localPort
    }

    func startRemoteServer() async throws -> UInt16 {
        guard let client else { throw SSHError.notConnected }
        let wantsIPv6 = (connectedHost ?? "").contains(":")

        guard let launchCommand = try await resolveServerLaunchCommand(client: client) else {
            throw SSHError.serverBinaryMissing
        }
        if let supportsWebsocketTransport = try await supportsWebsocketTransport(
            client: client,
            command: launchCommand
        ), !supportsWebsocketTransport {
            throw SSHError.serverStartFailed(
                message: "Remote Codex is too old for websocket app-server transport. Update Codex on the Mac and try again."
            )
        }

        var lastFailure = "Timed out waiting for remote server to start."
        for port in candidatePorts() {
            let listenAddr = wantsIPv6 ? "[::]:\(port)" : "0.0.0.0:\(port)"
            let logPath = "/tmp/codex-ios-app-server-\(port).log"

            // Check if already running on this port (not launched by us)
            if let listening = try? await isPortListening(client: client, port: port), listening {
                launchedServerPID = nil
                return port
            }

            var sawUnsupportedWebsocketCLI = false
            for launchAttempt in launchAttempts(for: launchCommand, listenAddr: listenAddr, logPath: logPath) {
                let launchOutput = String(
                    buffer: try await client.executeCommand(launchAttempt.shellCommand)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let launchedPID = Int(launchOutput)

                var shouldTryNextVariant = false

                // Poll until reachable.
                for attempt in 0..<60 {
                    try await Task.sleep(for: .milliseconds(500))
                    if let listening = try? await isPortListening(client: client, port: port), listening {
                        launchedServerPID = launchedPID
                        return port
                    }
                    if let pid = launchedPID, let alive = try? await isProcessAlive(client: client, pid: pid), !alive {
                        let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
                        if detail.localizedCaseInsensitiveContains("address already in use") {
                            lastFailure = detail
                            shouldTryNextVariant = false
                            break
                        }
                        if detail.localizedCaseInsensitiveContains("unexpected argument")
                            || detail.localizedCaseInsensitiveContains("unrecognized option")
                            || detail.localizedCaseInsensitiveContains("for more information, try '--help'") {
                            lastFailure = detail.isEmpty ? "Unsupported app-server launch form: \(launchAttempt.description)" : detail
                            sawUnsupportedWebsocketCLI = true
                            shouldTryNextVariant = true
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
                        launchedServerPID = launchedPID
                        return port
                    }
                }

                let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
                if detail.localizedCaseInsensitiveContains("address already in use") {
                    lastFailure = detail
                    shouldTryNextVariant = false
                    break
                }
                if shouldTryNextVariant {
                    continue
                }
                if !detail.isEmpty {
                    lastFailure = detail
                }
                break
            }

            if lastFailure.localizedCaseInsensitiveContains("address already in use") {
                continue
            }
            if sawUnsupportedWebsocketCLI {
                lastFailure = "Remote Codex is too old for websocket app-server transport. Update Codex on the Mac and try again."
            }
            break
        }
        throw SSHError.serverStartFailed(
            message: lastFailure
        )
    }

    private func candidatePorts() -> [UInt16] {
        var ports: [UInt16] = [defaultRemotePort, 9234]
        ports.append(contentsOf: (1...20).compactMap { UInt16(exactly: Int(defaultRemotePort) + $0) })
        var seen = Set<UInt16>()
        return ports.filter { seen.insert($0).inserted }
    }

    private func loginShell(_ script: String) -> String {
        let base64 = Data(script.utf8).base64EncodedString()
        // Source .zshrc/.bashrc explicitly since non-interactive login shells
        // only load .zprofile, missing tools installed via nvm/sdkman/etc.
        let rcSource = """
        [ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc" 2>/dev/null; \
        [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc" 2>/dev/null;
        """
        let wrappedBase64 = Data((rcSource + script).utf8).base64EncodedString()
        return "$SHELL -l -c \"$(echo \(wrappedBase64) | base64 -d)\""
    }

    private func resolveServerLaunchCommand(client: SSHClient) async throws -> ServerLaunchCommand? {
        let marker = "LITTER_RESOLVE:"
        let script = """
        codex_path="$(command -v codex 2>/dev/null || true)"
        if [ -n "$codex_path" ] && [ -f "$codex_path" ] && [ -x "$codex_path" ]; then
          printf '\(marker)codex:%s' "$codex_path"
        elif [ -x "$HOME/.bun/bin/codex" ]; then
          printf '\(marker)codex:%s' "$HOME/.bun/bin/codex"
        elif [ -x "$HOME/.volta/bin/codex" ]; then
          printf '\(marker)codex:%s' "$HOME/.volta/bin/codex"
        elif [ -x "$HOME/.cargo/bin/codex" ]; then
          printf '\(marker)codex:%s' "$HOME/.cargo/bin/codex"
        elif [ -x "$HOME/.nvm/versions/node/$(cat "$HOME/.nvm/alias/default" 2>/dev/null)/bin/codex" ]; then
          printf '\(marker)codex:%s' "$HOME/.nvm/versions/node/$(cat "$HOME/.nvm/alias/default" 2>/dev/null)/bin/codex"
        elif nvm_codex="$(find "$HOME/.nvm/versions/node" -maxdepth 2 -name codex -type f 2>/dev/null | head -1)" && [ -x "$nvm_codex" ]; then
          printf '\(marker)codex:%s' "$nvm_codex"
        else
          app_server_path="$(command -v codex-app-server 2>/dev/null || true)"
          if [ -n "$app_server_path" ] && [ -f "$app_server_path" ] && [ -x "$app_server_path" ]; then
            printf '\(marker)codex-app-server:%s' "$app_server_path"
          elif [ -x "$HOME/.cargo/bin/codex-app-server" ]; then
            printf '\(marker)codex-app-server:%s' "$HOME/.cargo/bin/codex-app-server"
          fi
        fi
        """
        let rawOutput = String(buffer: try await client.executeCommand(loginShell(script)))
        // Extract the marker line to ignore shell noise (MOTD, nvm messages, etc.)
        let output: String
        if let markerRange = rawOutput.range(of: marker) {
            output = String(rawOutput[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !output.isEmpty else { return nil }
        let parts = output.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "codex": return .codex(executable: parts[1])
        case "codex-app-server": return .codexAppServer(executable: parts[1])
        default: return nil
        }
    }

    private func launchAttempts(for command: ServerLaunchCommand, listenAddr: String, logPath: String) -> [LaunchAttempt] {
        let listenArg = shellQuote("ws://\(listenAddr)")
        let launches: [LaunchAttempt]
        switch command {
        case .codex(let executable):
            launches = [
                LaunchAttempt(
                    description: "codex app-server --listen",
                    shellCommand: backgroundedLaunch(
                        "\(shellQuote(executable)) app-server --listen \(listenArg)",
                        logPath: logPath
                    )
                ),
                LaunchAttempt(
                    description: "codex app-server serve --listen",
                    shellCommand: backgroundedLaunch(
                        "\(shellQuote(executable)) app-server serve --listen \(listenArg)",
                        logPath: logPath
                    )
                ),
                LaunchAttempt(
                    description: "codex app-server <url>",
                    shellCommand: backgroundedLaunch(
                        "\(shellQuote(executable)) app-server \(listenArg)",
                        logPath: logPath
                    )
                )
            ]
        case .codexAppServer(let executable):
            launches = [
                LaunchAttempt(
                    description: "codex-app-server --listen",
                    shellCommand: backgroundedLaunch(
                        "\(shellQuote(executable)) --listen \(listenArg)",
                        logPath: logPath
                    )
                ),
                LaunchAttempt(
                    description: "codex-app-server serve --listen",
                    shellCommand: backgroundedLaunch(
                        "\(shellQuote(executable)) serve --listen \(listenArg)",
                        logPath: logPath
                    )
                )
            ]
        }
        return launches
    }

    private func supportsWebsocketTransport(client: SSHClient, command: ServerLaunchCommand) async throws -> Bool? {
        let helpCommand: String
        switch command {
        case .codex(let executable):
            helpCommand = "\(shellQuote(executable)) app-server --help 2>&1 || true"
        case .codexAppServer(let executable):
            helpCommand = "\(shellQuote(executable)) --help 2>&1 || true"
        }

        let helpText = String(buffer: try await client.executeCommand(loginShell(helpCommand)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !helpText.isEmpty else { return nil }

        let normalized = helpText.lowercased()
        if normalized.contains("--listen") || normalized.contains("ws://") {
            return true
        }
        if normalized.contains("app-server") {
            return false
        }
        return nil
    }

    private func backgroundedLaunch(_ launch: String, logPath: String) -> String {
        loginShell("nohup \(launch) </dev/null >\(shellQuote(logPath)) 2>&1 & echo $!")
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

    func discoverWakeMACAddress() async -> String? {
        guard let client else { return nil }
        let script = """
        iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
        if [ -z "$iface" ]; then iface="en0"; fi
        mac="$(ifconfig "$iface" 2>/dev/null | awk '/ether /{print $2; exit}')"
        if [ -z "$mac" ]; then
          mac="$(ifconfig en0 2>/dev/null | awk '/ether /{print $2; exit}')"
        fi
        if [ -z "$mac" ]; then
          mac="$(ifconfig 2>/dev/null | awk '/ether /{print $2; exit}')"
        fi
        printf '%s' "$mac"
        """
        guard let output = try? await client.executeCommand(script) else { return nil }
        let raw = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscoveredServer.normalizeWakeMAC(raw)
    }

    func stopRemoteServer() async {
        guard let client, let pid = launchedServerPID else { return }
        _ = try? await client.executeCommand("kill \(pid) 2>/dev/null")
        launchedServerPID = nil
    }

    func disconnect() async {
        await closeLocalPortForward()
        try? await client?.close()
        client = nil
        connectedHost = nil
    }

    private func closeLocalPortForward() async {
        if let forwardedListener {
            try? await forwardedListener.close().get()
        }
        forwardedListener = nil
        forwardedLocalPort = nil
        forwardedRemotePort = nil
        forwardedRemoteHost = nil
    }

    private func remoteLoopbackHost() -> String {
        (connectedHost ?? "").contains(":") ? "::1" : "127.0.0.1"
    }
}

enum SSHError: LocalizedError {
    case notConnected
    case serverStartTimeout
    case serverBinaryMissing
    case serverStartFailed(message: String)
    case unsupportedKeyType
    case connectionFailed(host: String, port: Int, underlying: Error)
    case portForwardFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH not connected"
        case .serverStartTimeout: return "Timed out waiting for remote server to start"
        case .serverBinaryMissing: return "Remote host is missing `codex` (for `codex app-server`) and `codex-app-server` in PATH"
        case .serverStartFailed(let message): return message
        case .unsupportedKeyType: return "Unsupported SSH key type (only RSA and ED25519 are supported)"
        case .connectionFailed(let host, let port, _):
            return "Could not connect to \(host):\(port) — check that SSH is running and the host is reachable"
        case .portForwardFailed(let message):
            return message
        }
    }
}

private final class SSHClientBox: @unchecked Sendable {
    let client: SSHClient

    init(_ client: SSHClient) {
        self.client = client
    }
}

private func proxyTraffic(
    between local: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    and remote: NIOAsyncChannel<ByteBuffer, ByteBuffer>
) async throws {
    try await local.executeThenClose { localInbound, localOutbound in
        try await remote.executeThenClose { remoteInbound, remoteOutbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await buffer in localInbound {
                        try await remoteOutbound.write(buffer)
                    }
                }
                group.addTask {
                    for try await buffer in remoteInbound {
                        try await localOutbound.write(buffer)
                    }
                }

                defer { group.cancelAll() }
                try await group.next()
            }
        }
    }
}
