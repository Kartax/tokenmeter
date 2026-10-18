import Foundation

/// TokenMeter's own ChatGPT tokens for a Codex Account (ADR 0003), stored as JSON in the
/// Account's Keychain item. Never read from or written to the Codex CLI's `auth.json`.
struct CodexCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String

    /// Claims of the id token: the ChatGPT account id (`ChatGPT-Account-Id` header) and email.
    var identity: CodexIDToken { CodexIDToken(idToken) }
}

/// What TokenMeter reads from the Codex id token.
struct CodexIDToken: Equatable, Sendable {
    /// `chatgpt_account_id` of the `https://api.openai.com/auth` claim.
    var accountID: String?
    /// The `email` claim (or the `https://api.openai.com/profile` claim's email).
    var email: String?

    init(_ token: String) {
        let claims = JWTClaims(token)
        let auth = claims?.object("https://api.openai.com/auth")
        let profile = claims?.object("https://api.openai.com/profile")
        accountID = (auth?["chatgpt_account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        email = claims?.string("email") ?? (profile?["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
