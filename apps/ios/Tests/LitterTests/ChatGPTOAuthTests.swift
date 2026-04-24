import XCTest
@testable import Litter

@MainActor
final class ChatGPTOAuthTests: XCTestCase {
    func testAuthorizeURLUsesFixedLocalhostRedirect() throws {
        let url = try ChatGPTOAuth.buildAuthorizeURL(
            state: "state-123",
            codeChallenge: "challenge-456",
            redirectURI: "http://localhost:1455/auth/callback"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(query["scope"], "openid profile email offline_access")
        XCTAssertEqual(query["codex_cli_simplified_flow"], "true")
    }

    func testValidateCallbackURLAcceptsLoopbackCallback() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1455/auth/callback?code=abc&state=xyz"))

        let components = try ChatGPTOAuth.validateCallbackURL(url)

        XCTAssertEqual(components.path, "/auth/callback")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })["code"],
            "abc"
        )
    }

    func testValidateCallbackURLRejectsCustomSchemeCallbacks() throws {
        let url = try XCTUnwrap(URL(string: "litterauth://auth/callback?code=abc&state=xyz"))

        XCTAssertThrowsError(try ChatGPTOAuth.validateCallbackURL(url))
    }

    func testTransientKeychainAvailabilityDetectionMatchesRelevantStatuses() {
        XCTAssertTrue(ChatGPTOAuthError.keychain(errSecInteractionNotAllowed).isTransientKeychainAvailabilityFailure)
        XCTAssertTrue(ChatGPTOAuthError.keychain(errSecNotAvailable).isTransientKeychainAvailabilityFailure)
        XCTAssertFalse(ChatGPTOAuthError.keychain(errSecItemNotFound).isTransientKeychainAvailabilityFailure)
        XCTAssertFalse(ChatGPTOAuthError.missingStoredTokens.isTransientKeychainAvailabilityFailure)
    }

    func testTokenBundlePreservesExistingRefreshTokenWhenRefreshResponseOmitsIt() throws {
        let idToken = jwt(claims: [
            "chatgpt_account_id": "acct_123",
            "chatgpt_plan_type": "plus"
        ])
        let accessToken = jwt(claims: [
            "chatgpt_account_id": "acct_123"
        ])

        let bundle = try ChatGPTOAuth.tokenBundle(
            from: [
                "access_token": accessToken,
                "id_token": idToken
            ],
            statusCode: 200,
            fallbackRefreshToken: "refresh_123"
        )

        XCTAssertEqual(bundle.refreshToken, "refresh_123")
        XCTAssertEqual(bundle.accountID, "acct_123")
        XCTAssertEqual(bundle.planType, "plus")
    }

    private func jwt(claims: [String: String]) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let encoder = JSONEncoder()
        let headerData = try! encoder.encode(header)
        let payloadData = try! encoder.encode(claims)
        return [
            headerData.base64URLEncodedString(),
            payloadData.base64URLEncodedString(),
            ""
        ].joined(separator: ".")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
