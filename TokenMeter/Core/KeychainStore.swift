import Foundation
import Security

/// TokenMeter's own secrets: generic passwords with service `org.kartax.TokenMeter` and
/// account `<Account id>`. The value is a Provider-specific JSON blob.
/// Secrets live only here — never in the config file or logs.
struct KeychainStore: Sendable {
    static let service = "org.kartax.TokenMeter"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain: \(message)"
        }
    }

    var service: String = KeychainStore.service

    func data(for accountID: UUID) throws -> Data? {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Failure(status: status)
        }
    }

    func set(_ data: Data, for accountID: UUID) throws {
        let query = baseQuery(accountID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "TokenMeter"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    func delete(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func baseQuery(_ accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }
}

/// Credential source for Providers whose secrets TokenMeter owns (Ollama, Codex, Nous, Venice):
/// JSON-encodes `Credentials` into the Account's Keychain item.
struct KeychainCredentialSource<Credentials: Codable & Sendable>: CredentialSource {
    var keychain = KeychainStore()
    /// Hint shown when the item is missing or unreadable, e.g. "Check API key" or "Sign in again".
    var missingHint: String

    func load(for account: Account) -> Result<Credentials, ReadingFailure> {
        #if DEBUG
        // Debug insecure stub (never in release).
        if let insecure = insecureLoad(for: account) { return insecure }
        #endif
        do {
            guard let data = try keychain.data(for: account.id),
                  let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else {
                return .failure(.loginExpired(hint: missingHint))
            }
            return .success(credentials)
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
    }

    func save(_ credentials: Credentials, for account: Account) throws {
        #if DEBUG
        // Debug insecure stub (never in release).
        if DebugInsecureSecrets.isEnabled { insecureSave(credentials, for: account); return }
        #endif
        try keychain.set(try JSONEncoder().encode(credentials), for: account.id)
    }

    func delete(for account: Account) throws {
        #if DEBUG
        // Debug insecure stub (never in release).
        if DebugInsecureSecrets.isEnabled { insecureDelete(for: account); return }
        #endif
        try keychain.delete(for: account.id)
    }
}

#if DEBUG
// MARK: Debug insecure stub
// Smoke-run escape hatch: when `TOKENMETER_DEBUG_INSECURE_SECRETS=1` **and** a
// `CFFIXED_USER_HOME` is set, secrets persist as files under that home instead of the
// Keychain (which would trigger a macOS consent prompt for the user). Never in release;
// tests may assert Keychain behaviour separately.
enum DebugInsecureSecrets {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TOKENMETER_DEBUG_INSECURE_SECRETS"] == "1"
            && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
    }

    static func url(for accountID: UUID) -> URL {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        return URL(fileURLWithPath: home)
            .appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent(accountID.uuidString + ".json")
    }
}

extension KeychainCredentialSource {
    /// Debug insecure stub: reads from the file when enabled, else nil (use the Keychain).
    func insecureLoad(for account: Account) -> Result<Credentials, ReadingFailure>? {
        guard DebugInsecureSecrets.isEnabled else { return nil }
        let url = DebugInsecureSecrets.url(for: account.id)
        guard let data = try? Data(contentsOf: url),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return .failure(.loginExpired(hint: missingHint))
        }
        return .success(credentials)
    }

    /// Debug insecure stub: writes the file when enabled, else does nothing (Keychain path).
    func insecureSave(_ credentials: Credentials, for account: Account) {
        guard DebugInsecureSecrets.isEnabled else { return }
        let url = DebugInsecureSecrets.url(for: account.id)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(credentials).write(to: url, options: .atomic)
        } catch {
            coreLog.error("Debug insecure secret save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Debug insecure stub: removes the file when enabled, else does nothing (Keychain path).
    func insecureDelete(for account: Account) {
        guard DebugInsecureSecrets.isEnabled else { return }
        try? FileManager.default.removeItem(at: DebugInsecureSecrets.url(for: account.id))
    }
}
#endif
