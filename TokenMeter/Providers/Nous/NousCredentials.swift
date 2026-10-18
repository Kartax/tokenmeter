import Foundation

/// TokenMeter's own Nous Portal tokens (ADR 0003), stored as JSON in the Account's Keychain
/// item. Refresh tokens are single-use and rotate on every refresh; the rotated pair is saved
/// to the Keychain before anything else is done with it. Never read from Hermes CLI's stores.
struct NousCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
}