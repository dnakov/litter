import Foundation

actor PushProxyClient {
    static let baseURL = URL(string: "https://push.sigkitten.com")!

    struct RegisterBody: Encodable {
        let platform: String
        let pushToken: String
        let apnsEnvironment: String
        let intervalSeconds: Int
        let ttlSeconds: Int
    }

    struct RegisterResponse: Decodable {
        let id: String
    }

    func register(pushToken: String, interval: Int = 30, ttl: Int = 7200) async throws -> String {
        LLog.info(
            "push",
            "push proxy register request",
            fields: ["intervalSeconds": interval, "ttlSeconds": ttl]
        )
        let apnsEnv = Self.apnsEnvironment
        LLog.info("push", "detected APNS environment", fields: ["environment": apnsEnv])
        let body = RegisterBody(platform: "ios", pushToken: pushToken, apnsEnvironment: apnsEnv, intervalSeconds: interval, ttlSeconds: ttl)
        let data = try await post(path: "/register", body: body)
        return try JSONDecoder().decode(RegisterResponse.self, from: data).id
    }

    func deregister(registrationId: String) async throws {
        LLog.info("push", "push proxy deregister request", fields: ["registrationId": registrationId])
        _ = try await post(path: "/\(registrationId)/deregister", body: Empty())
    }

    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return "sandbox"
        }
        return "production"
        #endif
    }

    private struct Empty: Encodable {}

    private func post<T: Encodable>(path: String, body: T) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        LLog.trace("push", "push proxy HTTP request", fields: ["path": path])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        LLog.info("push", "push proxy HTTP response", fields: ["path": path, "status": status])
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
