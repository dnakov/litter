import Foundation

@MainActor
final class ServerConnection: ObservableObject, Identifiable {
    private static let defaultSandboxMode = "workspace-write"
    private static let fallbackSandboxMode = "danger-full-access"

    let id: String
    let server: DiscoveredServer
    let target: ConnectionTarget

    @Published var isConnected = false
    @Published var connectionPhase: String = ""
    @Published var authStatus: AuthStatus = .unknown
    @Published var oauthURL: URL? = nil
    @Published var loginCompleted = false
    @Published var models: [CodexModel] = []
    @Published var modelsLoaded = false

    let client = JSONRPCClient()
    private var serverURL: URL?
    private var pendingLoginId: String?

    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: (() -> Void)?

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
        guard !isConnected else { return }
        connectionPhase = "start"
        do {
            switch target {
            case .local:
                guard OnDeviceCodexFeature.isEnabled else {
                    connectionPhase = OnDeviceCodexFeature.compiledIn ? "local-disabled" : "local-unavailable"
                    return
                }
                connectionPhase = "local-starting"
                let port = try await CodexBridge.shared.ensureStarted()
                serverURL = URL(string: "ws://127.0.0.1:\(port)")!
                connectionPhase = "local-url"
            case .remote(let host, let port):
                guard let url = websocketURL(host: host, port: port) else {
                    connectionPhase = "invalid-url"
                    return
                }
                serverURL = url
                connectionPhase = "remote-url"
            case .sshThenRemote:
                connectionPhase = "sshThenRemote-not-supported"
                return
            }
            guard serverURL != nil else {
                connectionPhase = "no-url"
                return
            }
            connectionPhase = "setup-notifications"
            await setupNotifications()
            await setupDisconnectHandler()
            connectionPhase = "connect-and-initialize"
            try await connectAndInitialize()
            isConnected = true
            connectionPhase = "ready"
            Task { [weak self] in
                await self?.checkAuth()
            }
        } catch {
            connectionPhase = "error: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        Task { await client.disconnect() }
        isConnected = false
        serverURL = nil
    }

    // MARK: - RPC Methods

    func listThreads(cwd: String? = nil, cursor: String? = nil, limit: Int? = 20) async throws -> ThreadListResponse {
        try await client.sendRequest(
            method: "thread/list",
            params: ThreadListParams(cursor: cursor, limit: limit, sortKey: "updated_at", cwd: cwd),
            responseType: ThreadListResponse.self
        )
    }

    func startThread(cwd: String, model: String? = nil) async throws -> ThreadStartResponse {
        do {
            return try await startThread(cwd: cwd, model: model, sandbox: Self.defaultSandboxMode)
        } catch {
            guard shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await startThread(cwd: cwd, model: model, sandbox: Self.fallbackSandboxMode)
        }
    }

    func resumeThread(threadId: String, cwd: String) async throws -> ThreadResumeResponse {
        do {
            return try await resumeThread(threadId: threadId, cwd: cwd, sandbox: Self.defaultSandboxMode)
        } catch {
            guard shouldRetryWithoutLinuxSandbox(error) else { throw error }
            return try await resumeThread(threadId: threadId, cwd: cwd, sandbox: Self.fallbackSandboxMode)
        }
    }

    private func startThread(cwd: String, model: String?, sandbox: String) async throws -> ThreadStartResponse {
        try await client.sendRequest(
            method: "thread/start",
            params: ThreadStartParams(model: model, cwd: cwd, approvalPolicy: "never", sandbox: sandbox),
            responseType: ThreadStartResponse.self
        )
    }

    private func resumeThread(threadId: String, cwd: String, sandbox: String) async throws -> ThreadResumeResponse {
        try await client.sendRequest(
            method: "thread/resume",
            params: ThreadResumeParams(threadId: threadId, cwd: cwd, approvalPolicy: "never", sandbox: sandbox),
            responseType: ThreadResumeResponse.self
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

    func sendTurn(threadId: String, text: String, model: String? = nil, effort: String? = nil) async throws {
        let _: TurnStartResponse = try await client.sendRequest(
            method: "turn/start",
            params: TurnStartParams(threadId: threadId, input: [UserInput(type: "text", text: text)], model: model, effort: effort),
            responseType: TurnStartResponse.self
        )
    }

    func interrupt(threadId: String) async {
        struct Empty: Decodable {}
        _ = try? await client.sendRequest(
            method: "turn/interrupt",
            params: TurnInterruptParams(threadId: threadId),
            responseType: Empty.self
        )
    }

    func listModels() async throws -> ModelListResponse {
        try await client.sendRequest(
            method: "model/list",
            params: ModelListParams(limit: 50, includeHidden: false),
            responseType: ModelListResponse.self
        )
    }

    func execCommand(_ command: [String], cwd: String? = nil) async throws -> CommandExecResponse {
        try await client.sendRequest(
            method: "command/exec",
            params: CommandExecParams(command: command, cwd: cwd),
            responseType: CommandExecResponse.self
        )
    }

    // MARK: - Auth

    func checkAuth() async {
        do {
            let resp: GetAccountResponse = try await withThrowingTaskGroup(of: GetAccountResponse.self) { group in
                group.addTask {
                    try await self.client.sendRequest(
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

    func loginWithChatGPT() async {
        do {
            let resp: LoginStartResponse = try await client.sendRequest(
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
            let _: LoginStartResponse = try await client.sendRequest(
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
        _ = try? await client.sendRequest(
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
        _ = try? await client.sendRequest(
            method: "account/login/cancel",
            params: CancelLoginParams(loginId: loginId),
            responseType: Empty.self
        )
        pendingLoginId = nil
        oauthURL = nil
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
        default:
            break
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
        case .remote:
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
                    params: InitializeParams(clientInfo: .init(name: "Litter", version: "1.0", title: nil)),
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
                guard let self, self.isConnected else { return }
                self.isConnected = false
                self.onDisconnect?()
                do {
                    try await self.connectAndInitialize()
                    self.isConnected = true
                } catch {}
            }
        }
    }

    private func setupNotifications() async {
        await client.addNotificationHandler { [weak self] method, data in
            Task { @MainActor [weak self] in
                self?.onNotification?(method, data)
            }
        }
        await client.addRequestHandler { [weak self] id, method, data in
            Task { @MainActor [weak self] in
                self?.handleServerRequest(id: id, method: method)
            }
        }
    }

    private func handleServerRequest(id: String, method: String) {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            Task { await client.sendResult(id: id, result: ["decision": "accept"]) }
        default:
            Task { await client.sendResult(id: id, result: [:] as [String: String]) }
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
