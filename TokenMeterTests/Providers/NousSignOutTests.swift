import XCTest
@testable import TokenMeter

/// Sign-out for a Nous Account without removing it: secrets deleted, Reading forgotten,
/// loginExpired shown — the same `AccountStore.signOut` mechanism Codex uses.
@MainActor
final class NousSignOutTests: XCTestCase {
    private final class MemorySource: CredentialSource, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: NousCredentials?
        init(_ credentials: NousCredentials?) { stored = credentials }
        var credentials: NousCredentials? { lock.withLock { stored } }
        func load(for account: Account) -> Result<NousCredentials, ReadingFailure> {
            lock.withLock { stored }.map { .success($0) } ?? .failure(.loginExpired(hint: NousProvider.loginHint))
        }
        func save(_ credentials: NousCredentials, for account: Account) throws { lock.withLock { stored = credentials } }
        func delete(for account: Account) throws { lock.withLock { stored = nil } }
    }

    func testSignOutDeletesTokensAndKeepsTheAccountSignedOut() throws {
        let url = URL(fileURLWithPath: "/tmp/ticket6/store-test-config.json")
        try? FileManager.default.removeItem(at: url)
        let source = MemorySource(NousCredentials(accessToken: jwt(["exp": 4102444800]),
                                                  refreshToken: "refresh"))
        let store = AccountStore(config: ConfigStore(url: url),
                                 readerFor: { kind in kind == .nous ? CredentialedReader(provider: NousProvider(), source: source) : nil })
        let account = Account(kind: .nous, label: "Personal")
        store.add(account)

        try store.signOut(account.id, hint: NousProvider.loginHint)

        XCTAssertNil(source.credentials)
        XCTAssertEqual(store.accounts.map(\.id), [account.id], "Sign out keeps the Account")
        XCTAssertNil(store.readings[account.id])
        XCTAssertEqual(store.failures[account.id], .loginExpired(hint: NousProvider.loginHint))
    }
}