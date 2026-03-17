import Foundation
import Observation
import SwiftUI

enum ConnectionHealth: Equatable {
    case disconnected
    case connecting
    case connected
    case unresponsive

    var settingsLabel: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unresponsive: "Unresponsive"
        }
    }

    var settingsColor: Color {
        switch self {
        case .connected: LitterTheme.accent
        case .connecting, .unresponsive: .orange
        case .disconnected: LitterTheme.textSecondary
        }
    }
}

@MainActor
@Observable
final class ServerConnection: Identifiable {
    private static let defaultSandboxMode = "workspace-write"
    private static let localSandboxMode = "danger-full-access"
    private static let fallbackSandboxMode = "danger-full-access"

    let id: String
    let server: DiscoveredServer
    let target: ConnectionTarget

    var connectionHealth: ConnectionHealth = .disconnected
    var isConnected: Bool { connectionHealth == .connected }
    var connectionPhase: String = ""
    var authStatus: AuthStatus = .unknown
    var oauthURL: URL? = nil
    var loginCompleted = false {
        didSet {
            guard loginCompleted else { return }
            onLoginCompleted?()
        }
    }
    var models: [CodexModel] = []
    var modelsLoaded = false
    var rateLimits: RateLimitSnapshot?

    @ObservationIgnored let client = JSONRPCClient()
    @ObservationIgnored private(set) var channelClient: CodexChannel?
    @ObservationIgnored private var serverURL: URL?
    @ObservationIgnored private var pendingLoginId: String?

    @ObservationIgnored var onNotification: ((String, Data) -> Void)?
    @ObservationIgnored var onServerRequest: ((_ requestId: String, _ method: String, _ data: Data) -> Bool)?
    @ObservationIgnored var onDisconnect: (() -> Void)?
    @ObservationIgnored var onLoginCompleted: (() -> Void)?

    init(server: DiscoveredServer, target: ConnectionTarget) {
        self.id = server.id
        self.server = server
        self.target = target
    }

    private struct ConnectionRetryPolicy {
        let maxAttempts: Int
        let retryDelay: Duration
        let initializeTimeout: Duration
        let attemptTimeout: Duration
    }

    func connect() async {
        guard connectionHealth != .connected else { return }
        connectionHealth = .connecting
        connectionPhase = "start"
        do {
            switch target {
            case .local:
                guard OnDeviceCodexFeature.isEnabled else {
                    connectionPhase = OnDeviceCodexFeature.compiledIn ? "local-disabled" : "local-unavailable"
                    connectionHealth = .disconnected
                    return
                }
                connectionPhase = "local-channel-starting"
                let channel = try await CodexBridge.shared.ensureChannelStarted()
                channelClient = channel
                connectionPhase = "local-channel-setup"
                await setupChannelNotifications(channel)
                await setupChannelDisconnect(channel)
                // Initialize handshake already done by Rust in_process::start
                connectionHealth = .connected
                connectionPhase = "ready"
                Task { [weak self] in
                    await self?.checkAuth()
                    await self?.fetchRateLimits()
                }
                return
            case .remote(let host, let port):
                guard let url = websocketURL(host: host, port: port) else {
                    connectionPhase = "invalid-url"
                    connectionHealth = .disconnected
                    return
                }
                serverURL = url
                connectionPhase = "remote-url"
            case .remoteURL(let url):
                serverURL = url
                connectionPhase = "remote-url"
            case .sshThenRemote:
                connectionPhase = "sshThenRemote-not-supported"
                connectionHealth = .disconnected
                return
            }
            guard serverURL != nil else {
                connectionPhase = "no-url"
                connectionHealth = .disconnected
                return
            }
            connectionPhase = "setup-notifications"
            await setupNotifications()
            await setupDisconnectHandler()
            await setupHealthHandler()
            connectionPhase = "connect-and-initialize"
            try await connectAndInitialize()
            connectionHealth = .connected
            connectionPhase = "ready"
            Task { [weak self] in
                await self?.checkAuth()
                await self?.fetchRateLimits()
            }
        } catch {
            connectionPhase = "error: \(error.localizedDescription)"
            connectionHealth = .disconnected
        }
    }

    func disconnect() {
        if let channelClient {
            Task { await CodexBridge.shared.disconnectChannelIfCurrent(channelClient) }
            self.channelClient = nil
        }
        Task { await client.disconnect() }
        connectionHealth = .disconnected
        serverURL = nil
        rateLimits = nil
    }

    func forwardOAuthCallback(_ url: URL) {
        switch target {
        case .local:
            Task { _ = try? await URLSession.shared.data(from: url) }
        case .remote, .remoteURL:
            Task {
                _ = try? await execCommand(["curl", "-s", "-4", "-L", "--max-time", "10", url.absoluteString])
            }
        case .sshThenRemote:
            break
        }
    }

    // MARK: - RPC Methods

    func listThreads(cwd: String? = nil, cursor: String? = nil, limit: Int? = 20) async throws -> ThreadListResponse {
        try await routedSendRequest(
            method: "thread/list",
            params: ThreadListParams(cursor: cursor, limit: limit, sortKey: "updated_at", cwd: cwd),
            responseType: ThreadListResponse.self
        )
    }

    func startThread(
        cwd: String,
        model: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil,
        dynamicTools: [DynamicToolSpec]? = nil
    ) async throws -> ThreadStartResponse {
        let preferredSandbox = sandboxMode ?? (target == .local ? Self.localSandboxMode : Self.defaultSandboxMode)
        do {
            return try await startThread(
                cwd: cwd,
                model: model,
                approvalPolicy: approvalPolicy,
                sandbox: preferredSandbox,
                dynamicTools: dynamicTools
            )
        } catch {
            guard sandboxMode == nil, preferredSandbox == Self.defaultSandboxMode, shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await startThread(
                cwd: cwd,
                model: model,
                approvalPolicy: approvalPolicy,
                sandbox: Self.fallbackSandboxMode,
                dynamicTools: dynamicTools
            )
        }
    }

    func resumeThread(
        threadId: String,
        cwd: String,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadResumeResponse {
        let preferredSandbox = sandboxMode ?? (target == .local ? Self.localSandboxMode : Self.defaultSandboxMode)
        do {
            return try await resumeThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: preferredSandbox
            )
        } catch {
            guard sandboxMode == nil, preferredSandbox == Self.defaultSandboxMode, shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await resumeThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: Self.fallbackSandboxMode
            )
        }
    }

    func forkThread(
        threadId: String,
        cwd: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadForkResponse {
        let preferredSandbox = sandboxMode ?? (target == .local ? Self.localSandboxMode : Self.defaultSandboxMode)
        do {
            return try await forkThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: preferredSandbox
            )
        } catch {
            guard sandboxMode == nil, preferredSandbox == Self.defaultSandboxMode, shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await forkThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: Self.fallbackSandboxMode
            )
        }
    }

    private func startThread(cwd: String, model: String?, approvalPolicy: String, sandbox: String, dynamicTools: [DynamicToolSpec]? = nil) async throws -> ThreadStartResponse {
        let instructions = target == .local ? Self.localSystemInstructions : nil
        return try await routedSendRequest(
            method: "thread/start",
            params: ThreadStartParams(model: model, cwd: cwd, approvalPolicy: approvalPolicy, sandbox: sandbox, dynamicTools: dynamicTools, developerInstructions: instructions),
            responseType: ThreadStartResponse.self
        )
    }

    func readThread(threadId: String) async throws -> ThreadReadResponse {
        try await routedSendRequest(
            method: "thread/read",
            params: ThreadReadParams(threadId: threadId),
            responseType: ThreadReadResponse.self
        )
    }

    private func resumeThread(
        threadId: String,
        cwd: String,
        approvalPolicy: String,
        sandbox: String
    ) async throws -> ThreadResumeResponse {
        let instructions = target == .local ? Self.localSystemInstructions : nil
        return try await routedSendRequest(
            method: "thread/resume",
            params: ThreadResumeParams(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: sandbox,
                developerInstructions: instructions
            ),
            responseType: ThreadResumeResponse.self
        )
    }

    private func forkThread(
        threadId: String,
        cwd: String?,
        approvalPolicy: String,
        sandbox: String
    ) async throws -> ThreadForkResponse {
        let instructions = target == .local ? Self.localSystemInstructions : nil
        return try await routedSendRequest(
            method: "thread/fork",
            params: ThreadForkParams(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandbox: sandbox,
                developerInstructions: instructions
            ),
            responseType: ThreadForkResponse.self
        )
    }

    private func shouldRetryWithoutLinuxSandbox(_ error: Error) -> Bool {
        guard case let JSONRPCClientError.serverError(_, message) = error else {
            return false
        }
        let lower = message.lowercased()
        return lower.contains("codex-linux-sandbox was required but not provided") ||
            lower.contains("missing codex-linux-sandbox executable path")
    }

    @discardableResult
    func sendTurn(
        threadId: String,
        text: String,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        additionalInput: [UserInput] = []
    ) async throws -> TurnStartResponse {
        var inputs: [UserInput] = [UserInput(type: "text", text: text)]
        inputs.append(contentsOf: additionalInput)
        return try await routedSendRequest(
            method: "turn/start",
            params: TurnStartParams(
                threadId: threadId,
                input: inputs,
                approvalPolicy: approvalPolicy,
                sandboxPolicy: TurnSandboxPolicy(mode: sandboxMode),
                model: model,
                effort: effort
            ),
            responseType: TurnStartResponse.self
        )
    }

    func interrupt(threadId: String, turnId: String) async {
        struct Empty: Decodable {}
        _ = try? await routedSendRequest(
            method: "turn/interrupt",
            params: TurnInterruptParams(threadId: threadId, turnId: turnId),
            responseType: Empty.self
        )
    }

    func rollbackThread(threadId: String, numTurns: Int) async throws -> ThreadRollbackResponse {
        try await routedSendRequest(
            method: "thread/rollback",
            params: ThreadRollbackParams(threadId: threadId, numTurns: numTurns),
            responseType: ThreadRollbackResponse.self
        )
    }

    func archiveThread(threadId: String) async throws {
        let _: ThreadArchiveResponse = try await routedSendRequest(
            method: "thread/archive",
            params: ThreadArchiveParams(threadId: threadId),
            responseType: ThreadArchiveResponse.self
        )
    }

    func listModels() async throws -> ModelListResponse {
        try await routedSendRequest(
            method: "model/list",
            params: ModelListParams(limit: 50, includeHidden: false),
            responseType: ModelListResponse.self
        )
    }

    func execCommand(_ command: [String], cwd: String? = nil) async throws -> CommandExecResponse {
        try await routedSendRequest(
            method: "command/exec",
            params: CommandExecParams(command: command, cwd: cwd),
            responseType: CommandExecResponse.self
        )
    }

    func fuzzyFileSearch(query: String, roots: [String], cancellationToken: String?) async throws -> FuzzyFileSearchResponse {
        try await routedSendRequest(
            method: "fuzzyFileSearch",
            params: FuzzyFileSearchParams(query: query, roots: roots, cancellationToken: cancellationToken),
            responseType: FuzzyFileSearchResponse.self
        )
    }

    func listSkills(cwds: [String]?, forceReload: Bool = false) async throws -> SkillsListResponse {
        try await routedSendRequest(
            method: "skills/list",
            params: SkillsListParams(cwds: cwds, forceReload: forceReload),
            responseType: SkillsListResponse.self
        )
    }

    func respondToServerRequest(id: String, result: [String: Any]) {
        Task {
            routedSendResult(id: id, result: result)
        }
    }

    func listExperimentalFeatures(cursor: String? = nil, limit: Int? = 100) async throws -> ExperimentalFeatureListResponse {
        try await routedSendRequest(
            method: "experimentalFeature/list",
            params: ExperimentalFeatureListParams(cursor: cursor, limit: limit),
            responseType: ExperimentalFeatureListResponse.self
        )
    }

    func readConfig(cwd: String?) async throws -> ConfigReadResponse {
        try await routedSendRequest(
            method: "config/read",
            params: ConfigReadParams(includeLayers: false, cwd: cwd),
            responseType: ConfigReadResponse.self
        )
    }

    func writeConfigValue<Value: Encodable>(
        keyPath: String,
        value: Value,
        mergeStrategy: String = "upsert"
    ) async throws -> ConfigWriteResponse {
        try await routedSendRequest(
            method: "config/value/write",
            params: ConfigValueWriteParams(keyPath: keyPath, value: value, mergeStrategy: mergeStrategy, filePath: nil, expectedVersion: nil),
            responseType: ConfigWriteResponse.self
        )
    }

    func setThreadName(threadId: String, name: String) async throws {
        let _: ThreadSetNameResponse = try await routedSendRequest(
            method: "thread/name/set",
            params: ThreadSetNameParams(threadId: threadId, name: name),
            responseType: ThreadSetNameResponse.self
        )
    }

    func startReview(threadId: String) async throws -> ReviewStartResponse {
        try await routedSendRequest(
            method: "review/start",
            params: ReviewStartParams(threadId: threadId, target: .uncommittedChanges, delivery: "inline"),
            responseType: ReviewStartResponse.self
        )
    }

    // MARK: - Auth

    func checkAuth() async {
        do {
            let resp: GetAccountResponse = try await withThrowingTaskGroup(of: GetAccountResponse.self) { group in
                group.addTask {
                    try await self.routedSendRequest(
                        method: "account/read",
                        params: GetAccountParams(refreshToken: false),
                        responseType: GetAccountResponse.self
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(4))
                    throw URLError(.timedOut)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            if let account = resp.account {
                switch account.type {
                case "chatgpt": authStatus = .chatgpt(email: account.email ?? "")
                case "apiKey":  authStatus = .apiKey
                default:        authStatus = .notLoggedIn
                }
            } else {
                authStatus = .notLoggedIn
            }
        } catch {
            authStatus = .notLoggedIn
        }
    }

    func getAuthToken() async -> (method: String?, token: String?) {
        do {
            let resp: GetAuthStatusResponse = try await routedSendRequest(
                method: "getAuthStatus",
                params: GetAuthStatusParams(includeToken: true, refreshToken: false),
                responseType: GetAuthStatusResponse.self
            )
            return (resp.authMethod, resp.authToken)
        } catch {
            return (nil, nil)
        }
    }

    func loginWithChatGPT() async {
        do {
            let resp: LoginStartResponse = try await routedSendRequest(
                method: "account/login/start",
                params: LoginStartChatGPTParams(),
                responseType: LoginStartResponse.self
            )
            guard resp.type == "chatgpt",
                  let urlStr = resp.authUrl,
                  let url = URL(string: urlStr) else { return }
            pendingLoginId = resp.loginId
            oauthURL = url
        } catch {}
    }

    func loginWithApiKey(_ key: String) async {
        do {
            let _: LoginStartResponse = try await routedSendRequest(
                method: "account/login/start",
                params: LoginStartApiKeyParams(apiKey: key),
                responseType: LoginStartResponse.self
            )
            await checkAuth()
        } catch {}
    }

    func logout() async {
        struct Empty: Decodable {}
        struct EmptyParams: Encodable {}
        _ = try? await routedSendRequest(
            method: "account/logout",
            params: EmptyParams(),
            responseType: Empty.self
        )
        authStatus = .notLoggedIn
        oauthURL = nil
        pendingLoginId = nil
    }

    func cancelLogin() async {
        guard let loginId = pendingLoginId else { return }
        struct Empty: Decodable {}
        _ = try? await routedSendRequest(
            method: "account/login/cancel",
            params: CancelLoginParams(loginId: loginId),
            responseType: Empty.self
        )
        pendingLoginId = nil
        oauthURL = nil
    }

    // MARK: - Rate Limits

    func fetchRateLimits() async {
        struct EmptyParams: Encodable {}
        guard let resp = try? await routedSendRequest(
            method: "account/rateLimits/read",
            params: EmptyParams(),
            responseType: GetAccountRateLimitsResponse.self
        ) else { return }
        rateLimits = resp.rateLimits
    }

    // MARK: - Account Notifications

    func handleAccountNotification(method: String, data: Data) {
        switch method {
        case "account/login/completed":
            if let notif = try? JSONDecoder().decode(AccountLoginCompletedNotification.self, from: extractParams(data)),
               notif.success {
                oauthURL = nil
                pendingLoginId = nil
                loginCompleted = true
                Task { await self.checkAuth() }
            }
        case "account/updated":
            Task { await self.checkAuth() }
        case "account/rateLimits/updated":
            if let notif = try? JSONDecoder().decode(AccountRateLimitsUpdatedNotification.self, from: extractParams(data)) {
                rateLimits = notif.rateLimits
            }
        default:
            break
        }
    }

    // MARK: - Local System Instructions

    private static let localSystemInstructions = """
    You are running on an iOS device with limited shell capabilities via ios_system.

    Environment:
    - Working directory: /home/codex (inside the app's sandboxed filesystem — persistent across app launches)
    - Filesystem layout: ~/Documents acts as root with /home/codex, /tmp, /var/log, /etc
    - Shell: ios_system (in-process, not a full POSIX shell — no fork/exec)
    - If you need a shell wrapper, the executable itself must be `sh`.
    - Use `sh -c '...'` directly. Do NOT emit `/bin/bash`, `bash`, `/bin/zsh`, `zsh`, `/bin/sh -lc`, or nested wrappers like `/bin/bash -lc "sh -c '...'"`.
    - /bin/sh runs in-process — compound commands (&&, ||, pipes) work

    Available tools:
    - Shell: ls, cat, echo, touch, cp, mv, rm, mkdir, rmdir, pwd, chmod, ln, du, df, env, date, uname, whoami, which, true, false, yes, printenv, basename, dirname, realpath, readlink
    - Text: grep, sed, awk, wc, sort, uniq, head, tail, tr, tee, cut, paste, comm, diff, expand, unexpand, fold, fmt, nl, rev, strings
    - Files: find, stat, tar, xargs
    - Network: curl (full HTTP client), ssh, scp, sftp
    - Git: lg2 (libgit2 CLI — use `lg2` instead of `git`, supports clone, init, add, commit, push, pull, status, log, diff, branch, checkout, merge, remote, tag, stash)
    - Other: bc (calculator)

    Limitations:
    - apply_patch may fail with "Operation not permitted" — fall back to echo/cat with redirection.
    - Use RELATIVE paths, not absolute /var/mobile/Containers/... paths.
    - Container UUID changes between installs — absolute paths from previous sessions are invalid.
    - No package managers (npm, pip, brew) and no Python/Node.
    - Use `lg2` not `git` for git operations.
    - Commands run synchronously — avoid long-running operations.

    Best practices:
    - Use relative paths for all file operations.
    - Prefer direct argv commands like `pwd`, `find`, `ls`, `rg`, `sed`.
    - Only wrap with `sh -c '...'` when shell syntax is actually required.
    - Never prepend `sh -c` with `bash -lc` or `zsh -lc`.
    - Prefer simple, single commands over complex pipelines.
    - For file creation: try apply_patch first, fall back to echo/cat redirection.
    - For scripting: use shell scripts or awk.
    - Be concise — this is a mobile device.
    """

    // MARK: - Transport Routing

    /// Routes sendRequest to the channel client (local) or WebSocket client (remote).
    private func routedSendRequest<P: Encodable, R: Decodable>(
        method: String, params: P, responseType: R.Type
    ) async throws -> R {
        if let channelClient {
            return try await channelClient.sendRequest(method: method, params: params, responseType: responseType)
        }
        return try await client.sendRequest(method: method, params: params, responseType: responseType)
    }

    /// Routes sendResult to the appropriate client.
    private func routedSendResult(id: String, result: Any) {
        if let channelClient {
            Task { await channelClient.sendResult(id: id, result: result) }
        } else {
            Task { await self.client.sendResult(id: id, result: result) }
        }
    }

    private func setupChannelNotifications(_ channel: CodexChannel) async {
        await channel.setNotificationHandler { [weak self] method, data in
            Task { @MainActor [weak self] in
                self?.onNotification?(method, data)
            }
        }
        await channel.setRequestHandler { [weak self] id, method, data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let handled = self.onServerRequest?(id, method, data) ?? false
                if !handled {
                    self.routedSendResult(id: id, result: [:] as [String: String])
                }
            }
        }
    }

    private func setupChannelDisconnect(_ channel: CodexChannel) async {
        await channel.setDisconnectHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionHealth == .connected || self.connectionHealth == .unresponsive else { return }
                NSLog("[channel] disconnected, id=%@", self.id)
                self.connectionHealth = .disconnected
                self.onDisconnect?()
            }
        }
    }

    // MARK: - Connection Internals

    private func websocketURL(host: String, port: UInt16) -> URL? {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if !normalized.contains(":"), let pct = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<pct])
        }
        if normalized.contains(":") {
            let unbracketed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let escapedScope = unbracketed.replacingOccurrences(of: "%25", with: "%")
                .replacingOccurrences(of: "%", with: "%25")
            return URL(string: "ws://[\(escapedScope)]:\(port)")
        }
        return URL(string: "ws://\(normalized):\(port)")
    }

    private func connectAndInitialize() async throws {
        guard let url = serverURL else { throw URLError(.badURL) }
        let policy = retryPolicy()
        var lastError: Error = URLError(.cannotConnectToHost)
        for attempt in 0..<policy.maxAttempts {
            connectionPhase = "attempt \(attempt + 1)/\(policy.maxAttempts)"
            if attempt > 0 {
                try await Task.sleep(for: policy.retryDelay)
            }
            await client.disconnect()
            do {
                try await connectAndInitializeOnce(
                    url: url,
                    initializeTimeout: policy.initializeTimeout,
                    attemptTimeout: policy.attemptTimeout
                )
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func retryPolicy() -> ConnectionRetryPolicy {
        switch target {
        case .remote, .remoteURL:
            return ConnectionRetryPolicy(
                maxAttempts: 3,
                retryDelay: .milliseconds(300),
                initializeTimeout: .seconds(4),
                attemptTimeout: .seconds(5)
            )
        default:
            return ConnectionRetryPolicy(
                maxAttempts: 30,
                retryDelay: .milliseconds(800),
                initializeTimeout: .seconds(6),
                attemptTimeout: .seconds(12)
            )
        }
    }

    private func connectAndInitializeOnce(
        url: URL,
        initializeTimeout: Duration,
        attemptTimeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await MainActor.run { self.connectionPhase = "client-connect" }
                try await self.client.connect(url: url)
                await MainActor.run { self.connectionPhase = "initialize" }
                try await self.sendInitialize(timeout: initializeTimeout)
                await MainActor.run { self.connectionPhase = "initialized" }
            }
            group.addTask {
                try await Task.sleep(for: attemptTimeout)
                throw URLError(.timedOut)
            }
            _ = try await group.next()!
            group.cancelAll()
        }
    }

    private func sendInitialize(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: InitializeResponse.self) { group in
            group.addTask {
                try await self.client.sendRequest(
                    method: "initialize",
                    params: InitializeParams(
                        clientInfo: .init(name: "Litter", version: "1.0", title: nil),
                        capabilities: .init(experimentalApi: true)
                    ),
                    responseType: InitializeResponse.self
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            _ = try await group.next()!
            group.cancelAll()
        }
    }

    private func setupDisconnectHandler() async {
        await client.setDisconnectHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionHealth == .connected || self.connectionHealth == .unresponsive else {
                    NSLog("[ws] disconnect handler: already disconnected id=%@", self?.id ?? "?")
                    return
                }
                NSLog("[ws] socket died, auto-reconnecting id=%@", self.id)
                self.connectionHealth = .connecting
                self.onDisconnect?()
                do {
                    try await self.connectAndInitialize()
                    self.connectionHealth = .connected
                    NSLog("[ws] auto-reconnect SUCCESS id=%@", self.id)
                } catch {
                    self.connectionHealth = .disconnected
                    NSLog("[ws] auto-reconnect FAILED id=%@ err=%@", self.id, error.localizedDescription)
                }
            }
        }
    }

    private func setupHealthHandler() async {
        await client.setHealthChangeHandler { [weak self] healthy in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if healthy {
                    if self.connectionHealth == .unresponsive {
                        self.connectionHealth = .connected
                    }
                } else {
                    if self.connectionHealth == .connected {
                        self.connectionHealth = .unresponsive
                    }
                }
            }
        }
    }

    private func setupNotifications() async {
        await client.setNotificationHandler { [weak self] method, data in
            Task { @MainActor [weak self] in
                self?.onNotification?(method, data)
            }
        }
        await client.setRequestHandler { [weak self] id, method, data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let handled = self.onServerRequest?(id, method, data) ?? false
                if !handled {
                    self.routedSendResult(id: id, result: [:] as [String: String])
                }
            }
        }
    }

    private func extractParams(_ data: Data) -> Data {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let params = obj["params"] {
            return (try? JSONSerialization.data(withJSONObject: params)) ?? data
        }
        return data
    }
}
