import Foundation
import Network
import CryptoKit
import Security

actor JSONRPCClient {
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "Litter.JSONRPCClient.Network")
    private var readBuffer = Data()
    private var nextId: Int = 1
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var notificationHandlers: [(String, Data) -> Void] = []
    private var requestHandlers: [(String, String, Data) -> Void] = []
    private var onDisconnect: (() -> Void)?

    func connect(url: URL) async throws {
        guard url.scheme == "ws", let host = url.host else {
            throw URLError(.unsupportedURL)
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw URLError(.badURL)
        }

        disconnect()

        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection = conn

        do {
            try await waitUntilReady(conn)
            try await performHandshake(on: conn, url: url)
        } catch {
            conn.cancel()
            connection = nil
            throw error
        }

        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.startReceiving(on: conn)
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        readBuffer = Data()
        for (_, cont) in pending {
            cont.resume(throwing: CancellationError())
        }
        pending = [:]
    }

    func addNotificationHandler(_ handler: @escaping (String, Data) -> Void) {
        notificationHandlers.append(handler)
    }

    func addRequestHandler(_ handler: @escaping (_ id: String, _ method: String, _ data: Data) -> Void) {
        requestHandlers.append(handler)
    }

    func setDisconnectHandler(_ handler: @escaping () -> Void) {
        onDisconnect = handler
    }

    func sendResult(id: String, result: Any) {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let str = String(data: data, encoding: .utf8) else { return }
        Task { try? await self.sendText(str) }
    }

    func sendRequest<P: Encodable, R: Decodable>(
        method: String,
        params: P,
        responseType: R.Type
    ) async throws -> R {
        let id = "\(nextId)"
        nextId += 1

        let req = JSONRPCRequest(id: id, method: method, params: AnyEncodable(params))
        let data = try JSONEncoder().encode(req)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                pending[id] = cont
                Task {
                    do {
                        try await self.sendText(String(data: data, encoding: .utf8)!)
                    } catch {
                        if let c = await self.removePending(id: id) {
                            c.resume(throwing: error)
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

    private func removePending(id: String) -> CheckedContinuation<Data, Error>? {
        pending.removeValue(forKey: id)
    }

    private func waitUntilReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resolved = false
            conn.stateUpdateHandler = { state in
                guard !resolved else { return }
                switch state {
                case .ready:
                    resolved = true
                    conn.stateUpdateHandler = nil
                    cont.resume(returning: ())
                case .failed(let err):
                    resolved = true
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: err)
                case .cancelled:
                    resolved = true
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: URLError(.networkConnectionLost))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func performHandshake(on conn: NWConnection, url: URL) async throws {
        let key = randomWebSocketKey()
        let path = websocketPath(from: url)
        let hostHeader = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        let request = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "",
            ""
        ].joined(separator: "\r\n")
        try await sendRaw(Data(request.utf8), on: conn)

        var headerBytes = Data()
        while true {
            if let range = headerBytes.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = headerBytes[..<range.upperBound]
                readBuffer = Data(headerBytes[range.upperBound...])
                try validateHandshakeResponse(headerData: Data(headerData), key: key)
                return
            }
            guard let chunk = try await receiveRaw(on: conn) else {
                throw URLError(.networkConnectionLost)
            }
            headerBytes.append(chunk)
            if headerBytes.count > 65_536 {
                throw URLError(.cannotParseResponse)
            }
        }
    }

    private func websocketPath(from url: URL) -> String {
        let base = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            return "\(base)?\(query)"
        }
        return base
    }

    private func randomWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private func validateHandshakeResponse(headerData: Data, key: String) throws {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let status = lines.first, status.contains(" 101 ") else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let expected = Data(Insecure.SHA1.hash(data: Data("\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8))).base64EncodedString()
        guard headers["sec-websocket-accept"] == expected else {
            throw URLError(.badServerResponse)
        }
    }

    private func startReceiving(on conn: NWConnection) async {
        do {
            while !Task.isCancelled {
                guard let chunk = try await receiveRaw(on: conn) else {
                    throw URLError(.networkConnectionLost)
                }
                if chunk.isEmpty { continue }
                readBuffer.append(chunk)
                try await drainFrames(on: conn)
            }
        } catch {
            onDisconnect?()
        }
    }

    private func drainFrames(on conn: NWConnection) async throws {
        while let frame = parseFrame(from: &readBuffer) {
            switch frame.opcode {
            case 0x1:
                guard let text = String(data: frame.payload, encoding: .utf8) else { continue }
                handleIncomingData(Data(text.utf8))
            case 0x8:
                throw URLError(.networkConnectionLost)
            case 0x9:
                try await sendFrame(opcode: 0xA, payload: frame.payload, on: conn)
            case 0xA:
                break
            default:
                break
            }
        }
    }

    private func parseFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }

        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0

        var index = 2
        var payloadLen = Int(b1 & 0x7F)
        if payloadLen == 126 {
            guard buffer.count >= index + 2 else { return nil }
            payloadLen = Int(buffer[index]) << 8 | Int(buffer[index + 1])
            index += 2
        } else if payloadLen == 127 {
            guard buffer.count >= index + 8 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 {
                len = (len << 8) | UInt64(buffer[index + i])
            }
            guard len <= UInt64(Int.max) else { return nil }
            payloadLen = Int(len)
            index += 8
        }

        var maskKey = Data()
        if masked {
            guard buffer.count >= index + 4 else { return nil }
            maskKey = buffer.subdata(in: index..<(index + 4))
            index += 4
        }

        guard buffer.count >= index + payloadLen else { return nil }
        var payload = buffer.subdata(in: index..<(index + payloadLen))
        buffer.removeSubrange(0..<(index + payloadLen))

        if masked {
            let mask = [UInt8](maskKey)
            var bytes = [UInt8](payload)
            for i in bytes.indices {
                bytes[i] ^= mask[i % 4]
            }
            payload = Data(bytes)
        }
        return (opcode: opcode, payload: payload)
    }

    private func sendText(_ text: String) async throws {
        guard let conn = connection else { throw URLError(.networkConnectionLost) }
        try await sendFrame(opcode: 0x1, payload: Data(text.utf8), on: conn)
    }

    private func sendFrame(opcode: UInt8, payload: Data, on conn: NWConnection) async throws {
        var frame = Data()
        frame.append(0x80 | opcode)

        let maskBit: UInt8 = 0x80
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask)
        frame.append(contentsOf: mask)

        for (idx, byte) in payload.enumerated() {
            frame.append(byte ^ mask[idx % 4])
        }

        try await sendRaw(frame, on: conn)
    }

    private func sendRaw(_ data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: ()) }
            })
        }
    }

    private func receiveRaw(on conn: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                if isComplete && (data == nil || data?.isEmpty == true) {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let hasId = obj["id"] != nil
        let hasMethod = obj["method"] is String
        let hasResult = obj["result"] != nil
        let hasError = obj["error"] != nil

        if hasId && hasMethod && !hasResult && !hasError {
            // Server-initiated request (needs a response from us)
            let method = obj["method"] as! String
            let idValue = obj["id"]!
            let idStr: String
            if let s = idValue as? String { idStr = s }
            else if let i = idValue as? Int { idStr = "\(i)" }
            else { return }
            for handler in requestHandlers {
                handler(idStr, method, data)
            }
            return
        }

        if hasId && (hasResult || hasError) {
            // Response to a client-initiated request
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
            // Notification (no id, no response expected)
            if let notif = try? JSONDecoder().decode(JSONRPCNotification.self, from: data) {
                for handler in notificationHandlers {
                    handler(notif.method, data)
                }
            }
        }
    }
}

enum JSONRPCClientError: LocalizedError {
    case serverError(code: Int, message: String)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .serverError(_, let message): return message
        case .decodingFailed(let error): return error.localizedDescription
        }
    }
}

private extension Data {
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        // The response data contains the full JSON-RPC response; extract "result"
        if let obj = try? JSONSerialization.jsonObject(with: self) as? [String: Any],
           let result = obj["result"] {
            let resultData = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(T.self, from: resultData)
        }
        return try JSONDecoder().decode(T.self, from: self)
    }
}
