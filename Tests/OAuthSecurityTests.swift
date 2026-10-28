import XCTest
@testable import PhotoVault

final class OAuthSecurityTests: XCTestCase {

    // MARK: - Base64url

    func testBase64URLEncodingUsesURLSafeAlphabet() {
        // Standard base64 of these bytes is "+//+"
        XCTAssertEqual(OAuthSecurity.base64URLEncodedString(Data([0xFB, 0xFF, 0xFE])), "-__-")
    }

    func testBase64URLEncodingStripsPadding() {
        // Standard base64 of 0xFF is "/w=="
        XCTAssertEqual(OAuthSecurity.base64URLEncodedString(Data([0xFF])), "_w")
    }

    // MARK: - PKCE

    func testCodeChallengeMatchesRFC7636TestVector() {
        // RFC 7636, Appendix B
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            OAuthSecurity.codeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testCodeVerifierIsValidAndUnique() throws {
        let first = try OAuthSecurity.makeCodeVerifier()
        let second = try OAuthSecurity.makeCodeVerifier()

        XCTAssertEqual(first.count, 43)
        XCTAssertTrue(OAuthSecurity.isValidCodeVerifier(first))
        XCTAssertTrue(OAuthSecurity.isValidCodeVerifier(second))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("="))
    }

    func testCodeVerifierValidation() {
        XCTAssertFalse(OAuthSecurity.isValidCodeVerifier(String(repeating: "a", count: 42)))
        XCTAssertTrue(OAuthSecurity.isValidCodeVerifier(String(repeating: "a", count: 43)))
        XCTAssertTrue(OAuthSecurity.isValidCodeVerifier(String(repeating: "a", count: 128)))
        XCTAssertFalse(OAuthSecurity.isValidCodeVerifier(String(repeating: "a", count: 129)))
        XCTAssertTrue(OAuthSecurity.isValidCodeVerifier(String(repeating: "-._~", count: 11)))
        XCTAssertFalse(OAuthSecurity.isValidCodeVerifier(String(repeating: "a", count: 42) + "+"))
        XCTAssertFalse(OAuthSecurity.isValidCodeVerifier(String(repeating: "a", count: 42) + "="))
    }

    func testCodeChallengeIsUnpaddedBase64URLOfSHA256() throws {
        let challenge = OAuthSecurity.codeChallenge(for: try OAuthSecurity.makeCodeVerifier())
        // 32-byte digest -> 43 characters without padding
        XCTAssertEqual(challenge.count, 43)
        XCTAssertNil(challenge.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    // MARK: - State

    func testStateIsHighEntropyAndUnique() throws {
        let states = try (0..<100).map { _ in try OAuthSecurity.makeState() }
        XCTAssertEqual(Set(states).count, states.count)
        for state in states {
            XCTAssertEqual(state.count, 43)  // 32 random bytes
            XCTAssertNil(state.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        }
    }

    func testAuthorizationAttemptsAreIndependent() throws {
        let first = try OAuthAuthorizationAttempt.make()
        let second = try OAuthAuthorizationAttempt.make()
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
        XCTAssertNotEqual(first.state, first.codeVerifier)
        XCTAssertEqual(first.codeChallenge, OAuthSecurity.codeChallenge(for: first.codeVerifier))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(OAuthSecurity.constantTimeEquals("abc", "abc"))
        XCTAssertTrue(OAuthSecurity.constantTimeEquals("", ""))
        XCTAssertFalse(OAuthSecurity.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(OAuthSecurity.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(OAuthSecurity.constantTimeEquals("abc", ""))
    }

    // MARK: - Loopback Callback

    private let state = "Zm9vYmFyLXN0YXRlLXZhbHVlLWZvci10ZXN0aW5nLTE"

    private func request(_ target: String, method: String = "GET") -> String {
        "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:52847\r\n\r\n"
    }

    func testCallbackWithMatchingStateIsAuthorized() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=\(state)&code=4%2F0Abc-123&scope=email"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .authorized(code: "4/0Abc-123", state: state))
    }

    func testCallbackWithWrongStateIsRejected() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=attacker&code=injected"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .rejected(status: 400))
    }

    func testCallbackWithoutStateIsRejected() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?code=injected"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .rejected(status: 400))
    }

    func testCallbackWithDuplicateStateIsRejected() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=\(state)&state=other&code=abc"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .rejected(status: 400))
    }

    func testCallbackWithDuplicateCodeIsRejected() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=\(state)&code=abc&code=def"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .rejected(status: 400))
    }

    func testCallbackWithoutCodeIsRejected() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=\(state)"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .rejected(status: 400))
    }

    func testEmptyExpectedStateNeverMatches() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=&code=abc"),
            expectedState: ""
        )
        XCTAssertEqual(outcome, .rejected(status: 400))
    }

    func testCallbackOnOtherPathIsRejected() {
        XCTAssertEqual(
            OAuthLoopbackCallback.evaluate(
                requestHead: request("/favicon.ico"),
                expectedState: state
            ),
            .rejected(status: 404)
        )
        XCTAssertEqual(
            OAuthLoopbackCallback.evaluate(
                requestHead: request("/callback?state=\(state)&code=abc"),
                expectedState: state
            ),
            .rejected(status: 404)
        )
        // A path that looks like an authority must never be treated as the callback
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("//evil.example/?state=\(state)&code=abc"),
            expectedState: state
        )
        guard case .rejected = outcome else {
            return XCTFail("Expected rejection, got \(outcome)")
        }
    }

    func testCallbackWithOtherMethodIsRejected() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=\(state)&code=abc", method: "POST"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .rejected(status: 405))
    }

    func testMalformedRequestIsRejected() {
        XCTAssertEqual(
            OAuthLoopbackCallback.evaluate(requestHead: "", expectedState: state),
            .rejected(status: 400)
        )
        XCTAssertEqual(
            OAuthLoopbackCallback.evaluate(requestHead: "garbage\r\n\r\n", expectedState: state),
            .rejected(status: 400)
        )
        XCTAssertEqual(
            OAuthLoopbackCallback.evaluate(
                requestHead: "GET http://127.0.0.1/?state=\(state)&code=abc HTTP/1.1\r\n\r\n",
                expectedState: state
            ),
            .rejected(status: 400)
        )
    }

    func testErrorWithMatchingStateIsDenied() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=\(state)&error=access_denied"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .denied(error: "access_denied"))
    }

    func testErrorWithWrongStateIsRejected() {
        let outcome = OAuthLoopbackCallback.evaluate(
            requestHead: request("/?state=attacker&error=access_denied"),
            expectedState: state
        )
        XCTAssertEqual(outcome, .rejected(status: 400))
    }

    // MARK: - GoogleDriveClient

    func testAuthorizationRequestCarriesStateAndS256Challenge() async throws {
        let client = GoogleDriveClient(clientID: "test-client", clientSecret: "test-secret")
        await client.setRedirectPort(52847)

        let authRequest = try await client.makeAuthorizationRequest()
        let components = try XCTUnwrap(URLComponents(url: authRequest.url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(value("state"), authRequest.state)
        XCTAssertEqual(authRequest.state.count, 43)
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge")?.count, 43)
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:52847")
        XCTAssertNil(value("code_verifier"), "The verifier must never be sent on the authorization request")
        XCTAssertNil(value("client_secret"))

        let second = try await client.makeAuthorizationRequest()
        XCTAssertNotEqual(second.state, authRequest.state)
    }

    func testTokenExchangeRejectsMismatchedStateAndIsSingleUse() async throws {
        let client = GoogleDriveClient(clientID: "test-client", clientSecret: "test-secret")
        await client.setRedirectPort(52847)
        let authRequest = try await client.makeAuthorizationRequest()

        // Wrong state: rejected before any network call
        do {
            try await client.exchangeCodeForTokens(code: "injected", state: "attacker")
            XCTFail("Expected state mismatch")
        } catch let error as OAuthFlowError {
            XCTAssertEqual(error, .stateMismatch)
        }

        // The attempt was consumed, so even the right state can't be replayed
        do {
            try await client.exchangeCodeForTokens(code: "code", state: authRequest.state)
            XCTFail("Expected no pending authorization")
        } catch let error as OAuthFlowError {
            XCTAssertEqual(error, .noPendingAuthorization)
        }
    }

    func testTokenExchangeWithoutAuthorizationRequestIsRejected() async throws {
        let client = GoogleDriveClient(clientID: "test-client", clientSecret: "test-secret")
        do {
            try await client.exchangeCodeForTokens(code: "code", state: "state")
            XCTFail("Expected no pending authorization")
        } catch let error as OAuthFlowError {
            XCTAssertEqual(error, .noPendingAuthorization)
        }
    }

    func testCancelPendingAuthorizationClearsAttempt() async throws {
        let client = GoogleDriveClient(clientID: "test-client", clientSecret: "test-secret")
        let authRequest = try await client.makeAuthorizationRequest()
        await client.cancelPendingAuthorization()
        do {
            try await client.exchangeCodeForTokens(code: "code", state: authRequest.state)
            XCTFail("Expected no pending authorization")
        } catch let error as OAuthFlowError {
            XCTAssertEqual(error, .noPendingAuthorization)
        }
    }
}
