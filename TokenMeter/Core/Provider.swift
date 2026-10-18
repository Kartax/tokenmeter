import Foundation

/// Seam A: turns an Account plus its credentials into a Reading or a ReadingFailure.
///
/// Credentials are passed in (never looked up here) and HTTP goes through the injected
/// `session`, so tests replay recorded responses through a stubbed `URLProtocol`.
protocol Provider: Sendable {
    associatedtype Credentials: Sendable

    func read(account: Account, credentials: Credentials, session: URLSession, now: Date) async
        -> ProviderReading<Credentials>

    /// Like `read`, but rotated credentials are handed to `persist` *before* they are used, so a
    /// single-use refresh token is never lost (Codex, Nous). Still returns them in the result.
    func read(account: Account, credentials: Credentials, session: URLSession, now: Date,
              persist: @Sendable (Credentials) -> Void) async -> ProviderReading<Credentials>
}

extension Provider {
    /// Providers whose credentials don't rotate: persist whatever `read` returned, afterwards.
    func read(account: Account, credentials: Credentials, session: URLSession, now: Date,
              persist: @Sendable (Credentials) -> Void) async -> ProviderReading<Credentials> {
        let result = await read(account: account, credentials: credentials, session: session, now: now)
        if let rotated = result.rotatedCredentials { persist(rotated) }
        return result
    }
}

/// Result of one `Provider.read`; `rotatedCredentials` is set when a token refresh rotated them,
/// and the caller must persist it.
struct ProviderReading<Credentials: Sendable>: Sendable {
    var outcome: Result<Reading, ReadingFailure>
    var rotatedCredentials: Credentials?

    init(_ outcome: Result<Reading, ReadingFailure>, rotatedCredentials: Credentials? = nil) {
        self.outcome = outcome
        self.rotatedCredentials = rotatedCredentials
    }
}

/// Loads and saves a Provider's credentials (TokenMeter's Keychain, or Claude Code's store).
/// Not part of seam A.
protocol CredentialSource: Sendable {
    associatedtype Credentials: Sendable

    /// The Account's credentials, or the failure to show when there are none.
    func load(for account: Account) -> Result<Credentials, ReadingFailure>
    func save(_ credentials: Credentials, for account: Account) throws
    /// Deletes every secret TokenMeter stored for the Account.
    func delete(for account: Account) throws
}

/// Type-erased "read this Account" used by `AccountStore`: credential source + Provider.
protocol AccountReader: Sendable {
    func read(_ account: Account, session: URLSession, now: Date) async -> Result<Reading, ReadingFailure>
    /// Deletes every secret TokenMeter stored for the Account (called when it is removed).
    func deleteSecrets(for account: Account) throws
}

/// Loads credentials, calls the Provider, and saves rotated credentials before they are used.
struct CredentialedReader<P: Provider, S: CredentialSource>: AccountReader
where P.Credentials == S.Credentials {
    let provider: P
    let source: S

    func read(_ account: Account, session: URLSession, now: Date) async -> Result<Reading, ReadingFailure> {
        let credentials: P.Credentials
        switch source.load(for: account) {
        case .success(let loaded): credentials = loaded
        case .failure(let failure): return .failure(failure)
        }
        let source = source
        let result = await provider.read(account: account, credentials: credentials, session: session, now: now) { rotated in
            do {
                try source.save(rotated, for: account)
            } catch {
                coreLog.error("Saving rotated credentials for \(account.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return result.outcome
    }

    func deleteSecrets(for account: Account) throws {
        try source.delete(for: account)
    }
}
