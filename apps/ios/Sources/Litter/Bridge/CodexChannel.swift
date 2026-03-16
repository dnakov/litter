import Foundation

/// In-process channel transport for the local on-device codex bridge.
/// Replaces WebSocket for local connections — no TCP, no frame masking.
/// The remote WebSocket path (JSONRPCClient) is completely unaffected.
actor CodexChannel {
    private var handle: UnsafeMutableRawPointer?
    private var callbackReceiver: CallbackReceiver?
    private var callbackCtx: UnsafeMutableRawPointer?
    private var nextId: Int = 1
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var notificationHandler: ((String, Data) -> Void)?
    private var requestHandler: ((_ id: String, _ method: String, _ data: Data) -> Void)?
    private var disconnectHandler: (() -> Void)?

    deinit {
        if let handle {
            codex_channel_close(handle)
        }
    }

    func open() throws {
        let receiver = CallbackReceiver(channel: self)
        callbackReceiver = receiver

        var outHandle: UnsafeMutableRawPointer?
        let ctx = Unmanaged.passRetained(receiver).toOpaque()
        callbackCtx = ctx
        let rc = codex_channel_open(channelMessageCallback, ctx, &outHandle)

        guard rc == 0, let h = outHandle else {
            Unmanaged<CallbackReceiver>.fromOpaque(ctx).release()
            callbackReceiver = nil
            callbackCtx = nil
            throw CodexError.startFailed(rc)
        }
        handle = h
    }

    func close() {
        if let handle {
            codex_channel_close(handle)
            self.handle = nil
        }
        if let ctx = callbackCtx {
            Unmanaged<CallbackReceiver>.fromOpaque(ctx).release()
            callbackCtx = nil
            callbackReceiver = nil
        }
        for (_, cont) in pending {
            cont.resume(throwing: CancellationError())
        }
        pending = [:]
        disconnectHandler?()
    }

    var isConnected: Bool { handle != nil }

    // MARK: - Handler setters (same interface as JSONRPCClient)

    func setNotificationHandler(_ handler: @escaping (String, Data) -> Void) {
        notificationHandler = handler
    }

    func setRequestHandler(_ handler: @escaping (_ id: String, _ method: String, _ data: Data) -> Void) {
        requestHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping () -> Void) {
        disconnectHandler = handler
    }

    func setHealthChangeHandler(_ handler: @escaping (Bool) -> Void) {
        // Channel is always "healthy" while open — no heartbeat needed.
    }

    // MARK: - Sending

    func sendRequest<P: Encodable, R: Decodable>(
        method: String,
        params: P,
        responseType: R.Type
    ) async throws -> R {
        guard let handle else { throw URLError(.notConnectedToInternet) }

        let id = "\(nextId)"
        nextId += 1

        let req = JSONRPCRequest(id: id, method: method, params: AnyEncodable(params))
        let data = try JSONEncoder().encode(req)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                pending[id] = cont

                data.withUnsafeBytes { buf in
                    guard let ptr = buf.baseAddress else {
                        if let c = pending.removeValue(forKey: id) {
                            c.resume(throwing: URLError(.badURL))
                        }
                        return
                    }
                    let rc = codex_channel_send(
                        handle,
                        ptr.assumingMemoryBound(to: CChar.self),
                        buf.count
                    )
                    if rc != 0 {
                        if let c = pending.removeValue(forKey: id) {
                            c.resume(throwing: CodexError.startFailed(rc))
                        }
                    }
                }
            }
            .decoded(as: responseType)
        } onCancel: {
            Task {
                if let c = await self.removePending(id: id) {
                    c.resume(throwing: CancellationError())
                }
            }
        }
    }

    func sendResult(id: String, result: Any) {
        guard let handle else { return }
        let idValue: Any = Int(id).map { $0 as Any } ?? id
        let response: [String: Any] = ["jsonrpc": "2.0", "id": idValue, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            _ = codex_channel_send(handle, ptr.assumingMemoryBound(to: CChar.self), buf.count)
        }
    }

    // MARK: - Receiving (called from callback)

    nonisolated func receiveMessage(_ data: Data) {
        Task { await handleIncomingData(data) }
    }

    private func handleIncomingData(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let hasId = obj["id"] != nil
        let hasMethod = obj["method"] is String
        let hasResult = obj["result"] != nil
        let hasError = obj["error"] != nil

        if hasId && hasMethod && !hasResult && !hasError {
            let method = obj["method"] as! String
            let idValue = obj["id"]!
            let idStr: String
            if let s = idValue as? String { idStr = s }
            else if let i = idValue as? Int { idStr = "\(i)" }
            else { return }
            requestHandler?(idStr, method, data)
            return
        }

        if hasId && (hasResult || hasError) {
            if let resp = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) {
                let idStr: String
                switch resp.id {
                case .string(let s): idStr = s
                case .int(let i): idStr = "\(i)"
                }
                if let cont = pending.removeValue(forKey: idStr) {
                    if let error = resp.error {
                        cont.resume(throwing: JSONRPCClientError.serverError(code: error.code, message: error.message))
                    } else {
                        cont.resume(returning: data)
                    }
                }
            }
            return
        }

        if hasMethod && !hasId {
            if let notif = try? JSONDecoder().decode(JSONRPCNotification.self, from: data) {
                notificationHandler?(notif.method, data)
            }
            return
        }
    }

    private func removePending(id: String) -> CheckedContinuation<Data, Error>? {
        pending.removeValue(forKey: id)
    }
}

// MARK: - C Callback Bridge

/// Bridging object that receives messages from the Rust tokio thread
/// and forwards them to the CodexChannel actor.
private final class CallbackReceiver: @unchecked Sendable {
    let channel: CodexChannel

    init(channel: CodexChannel) {
        self.channel = channel
    }
}

/// C callback function invoked from Rust background threads.
private func channelMessageCallback(
    ctx: UnsafeMutableRawPointer?,
    json: UnsafePointer<CChar>?,
    jsonLen: Int
) {
    guard let ctx, let json else { return }
    let data = Data(bytes: json, count: jsonLen)
    let receiver = Unmanaged<CallbackReceiver>.fromOpaque(ctx).takeUnretainedValue()
    receiver.channel.receiveMessage(data)
}
