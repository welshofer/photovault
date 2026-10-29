import Foundation
import CryptoKit
import Security

// MARK: - OAuth Flow Errors

enum OAuthFlowError: LocalizedError, Equatable {
    case randomGenerationFailed(OSStatus)
    case invalidAuthorizationURL
    case noPendingAuthorization
    case stateMismatch
    case authorizationDenied(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            return "Could not generate secure random data for sign-in (status \(status))"
        case .invalidAuthorizationURL:
            return "Could not build the Google sign-in URL"
        case .noPendingAuthorization:
            return "No sign-in is in progress. Please try signing in again."
        case .stateMismatch:
            return "The sign-in response did not match this sign-in attempt. Please try again."
        case .authorizationDenied(let reason):
            return "Google sign-in was not completed (\(reason))"
        case .timedOut:
            return "Timed out waiting for Google sign-in. Please try again."
        }
    }
}

// MARK: - OAuth Security Helpers

/// Helpers for the OAuth 2.0 `state` parameter (RFC 6749 §10.12) and
/// Proof Key for Code Exchange with the S256 method (RFC 7636).
enum OAuthSecurity {

    /// Number of random bytes behind each `state` value and PKCE code verifier.
    /// 32 bytes encode to 43 base64url characters, the RFC 7636 minimum length.
    static let randomByteCount = 32

    /// Returns `count` bytes from the system's cryptographically secure generator.
    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OAuthFlowError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }

    /// Base64url encoding without padding (RFC 4648 §5, as RFC 7636 requires).
    static func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A fresh, unguessable `state` value for one sign-in attempt.
    static func makeState() throws -> String {
        base64URLEncodedString(try randomBytes(count: randomByteCount))
    }

    /// A fresh PKCE code verifier: 32 random bytes, base64url without padding (43 characters).
    static func makeCodeVerifier() throws -> String {
        base64URLEncodedString(try randomBytes(count: randomByteCount))
    }

    /// Characters RFC 7636 §4.1 allows in a code verifier: ALPHA / DIGIT / "-" / "." / "_" / "~".
    private static let codeVerifierCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Whether `verifier` has a length of 43–128 and only RFC 7636 unreserved characters.
    static func isValidCodeVerifier(_ verifier: String) -> Bool {
        let scalars = verifier.unicodeScalars
        guard (43...128).contains(scalars.count) else { return false }
        return scalars.allSatisfy { codeVerifierCharacters.contains($0) }
    }

    /// The S256 code challenge: base64url(SHA256(ASCII(verifier))), without padding.
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncodedString(Data(digest))
    }

    /// Compares two strings without returning early on the first differing byte.
    /// Only the length can leak, and `state` values have a fixed, public length.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

// MARK: - Authorization Attempt

/// The secrets for one sign-in attempt. Created when the authorization URL is built,
/// consumed (and discarded) by the token exchange.
struct OAuthAuthorizationAttempt: Sendable {
    let state: String
    let codeVerifier: String

    var codeChallenge: String {
        OAuthSecurity.codeChallenge(for: codeVerifier)
    }

    static func make() throws -> OAuthAuthorizationAttempt {
        OAuthAuthorizationAttempt(
            state: try OAuthSecurity.makeState(),
            codeVerifier: try OAuthSecurity.makeCodeVerifier()
        )
    }
}

// MARK: - Loopback Callback Parsing

/// Decides what to do with one HTTP request that reached the loopback redirect server.
enum OAuthLoopbackCallback {

    enum Outcome: Equatable {
        /// Google redirected back for this attempt with an authorization code.
        case authorized(code: String, state: String)
        /// Google redirected back for this attempt with an error (e.g. the user cancelled).
        case denied(error: String)
        /// Not the expected callback (wrong method, path or state, or malformed).
        /// Answer with this HTTP status, discard the request and keep waiting.
        case rejected(status: Int)
    }

    /// The only path the redirect URI `http://127.0.0.1:<port>` can produce.
    static let expectedPath = "/"

    /// Evaluates the head of an HTTP request, e.g. `GET /?state=…&code=…&scope=… HTTP/1.1`.
    /// Only a `GET` to `expectedPath` carrying exactly one `state` equal to `expectedState`
    /// is accepted; everything else is rejected so it can never end the sign-in.
    static func evaluate(requestHead: String, expectedState: String) -> Outcome {
        guard let requestLine = requestHead.components(separatedBy: "\r\n").first else {
            return .rejected(status: 400)
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            return .rejected(status: 400)
        }
        guard parts[0] == "GET" else {
            return .rejected(status: 405)
        }

        let target = String(parts[1])
        guard target.hasPrefix("/"),
              let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return .rejected(status: 400)
        }
        guard components.percentEncodedPath == expectedPath else {
            return .rejected(status: 404)
        }

        let items = components.queryItems ?? []
        func values(_ name: String) -> [String] {
            items.filter { $0.name == name }.map { $0.value ?? "" }
        }

        let states = values("state")
        guard !expectedState.isEmpty,
              states.count == 1,
              OAuthSecurity.constantTimeEquals(states[0], expectedState) else {
            return .rejected(status: 400)
        }

        let errors = values("error")
        let codes = values("code")
        if !errors.isEmpty {
            guard errors.count == 1, codes.isEmpty, !errors[0].isEmpty else {
                return .rejected(status: 400)
            }
            return .denied(error: errors[0])
        }
        guard codes.count == 1, !codes[0].isEmpty else {
            return .rejected(status: 400)
        }
        return .authorized(code: codes[0], state: states[0])
    }
}
