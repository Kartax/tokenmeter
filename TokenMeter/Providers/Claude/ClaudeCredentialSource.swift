import CryptoKit
import Foundation
import Security

/// Reads Claude Code's own login (ADR 0001): its Keychain item, or `<config dir>/.credentials.json`
/// when there is no item. Read fresh on every fetch; never saved, copied, refreshed or logged.
struct ClaudeCredentialSource: CredentialSource {
    /// Claude Code's default config directory (`CLAUDE_CONFIG_DIR` unset).
    static var defaultConfigDirectory: String { NSHomeDirectory() + "/.claude" }

    /// Claude Code's Keychain service: `Claude Code-credentials` for the default login, plus
    /// `-<first 8 hex chars of sha256(config dir)>` for a `CLAUDE_CONFIG_DIR` login.
    static func keychainService(configDirectory: String?) -> String {
        guard let configDirectory else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Config directory whose `.credentials.json` is the fallback.
    static func configDirectory(of account: Account) -> String {
        account.claudeConfigDirectory ?? defaultConfigDirectory
    }

    /// True when Claude Code's item for this login exists. Reads attributes only, so macOS shows
    /// no Keychain prompt; the token itself is not touched.
    static func hasLogin(configDirectory: String?) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService(configDirectory: configDirectory),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        let file = (configDirectory ?? defaultConfigDirectory) + "/.credentials.json"
        return FileManager.default.fileExists(atPath: file)
    }

    /// Reads the item's value by service (the account attribute is the macOS user name, not
    /// filtered on). Injected so the file fallback can be exercised without the Keychain.
    var keychainItem: @Sendable (_ service: String) throws -> Data? = ClaudeCredentialSource.readKeychainItem

    func load(for account: Account) -> Result<ClaudeCredentials, ReadingFailure> {
        let service = Self.keychainService(configDirectory: account.claudeConfigDirectory)
        let data: Data
        do {
            if let item = try keychainItem(service) {
                data = item
            } else {
                let file = URL(fileURLWithPath: Self.configDirectory(of: account))
                    .appendingPathComponent(".credentials.json")
                guard let contents = try? Data(contentsOf: file) else {
                    return .failure(.loginExpired(hint: ClaudeProvider.loginHint))
                }
                data = contents
            }
        } catch let failure as KeychainStore.Failure where failure.isAccessDenied {
            return .failure(.unavailable("Keychain access denied — allow TokenMeter in the prompt"))
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
        guard let credentials = Self.parse(data) else {
            return .failure(.loginExpired(hint: ClaudeProvider.loginHint))
        }
        return .success(credentials)
    }

    /// Never called: Claude credentials are never rotated by TokenMeter (ADR 0001).
    func save(_ credentials: ClaudeCredentials, for account: Account) throws {}

    /// Nothing to delete: Claude Code owns its login, and TokenMeter stores no Claude secret.
    func delete(for account: Account) throws {}

    /// `{"claudeAiOauth": {"accessToken", "expiresAt" (ms), "subscriptionType", "rateLimitTier"}}`.
    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt,
                                 subscriptionType: oauth["subscriptionType"] as? String,
                                 rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    /// The first time, macOS asks whether TokenMeter may use Claude Code's item.
    @Sendable static func readKeychainItem(service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainStore.Failure(status: status)
        }
    }
}

private extension KeychainStore.Failure {
    /// The user denied (or cancelled) the Keychain prompt.
    var isAccessDenied: Bool {
        status == errSecAuthFailed || status == errSecUserCanceled
    }
}
