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

/// Credential source for Providers whose secrets TokenMeter owns (Ollama, Codex, Nous):
/// JSON-encodes `Credentials` into the Account's Keychain item.
struct KeychainCredentialSource<Credentials: Codable & Sendable>: CredentialSource {
    var keychain = KeychainStore()
    /// Hint shown when the item is missing or unreadable, e.g. "Check API key" or "Sign in again".
    var missingHint: String

    func load(for account: Account) -> Result<Credentials, ReadingFailure> {
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
        try keychain.set(try JSONEncoder().encode(credentials), for: account.id)
    }

    func delete(for account: Account) throws {
        try keychain.delete(for: account.id)
    }
}
