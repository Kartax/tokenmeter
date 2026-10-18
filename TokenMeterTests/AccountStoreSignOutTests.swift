import XCTest
@testable import TokenMeter

/// Sign-out without removing the Account: secrets deleted, Reading forgotten, loginExpired shown.
@MainActor
final class AccountStoreSignOutTests: XCTestCase {
    private final class MemorySource: CredentialSource, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CodexCredentials?
        init(_ credentials: CodexCredentials?) { stored = credentials }
        var credentials: CodexCredentials? { lock.withLock { stored } }
        func load(for account: Account) -> Result<CodexCredentials, ReadingFailure> {
            lock.withLock { stored }.map { .success($0) } ?? .failure(.loginExpired(hint: CodexProvider.loginHint))
        }
        func save(_ credentials: CodexCredentials, for account: Account) throws { lock.withLock { stored = credentials } }
        func delete(for account: Account) throws { lock.withLock { stored = nil } }
    }

    func testSignOutDeletesTokensAndKeepsTheAccountSignedOut() throws {
        let source = MemorySource(CodexCredentials(accessToken: jwt(["exp": 4102444800]),
                                                   refreshToken: "refresh", idToken: jwt(["email": "user@example.com"])))
        let store = AccountStore(config: ConfigStore(url: URL(fileURLWithPath: "/tmp/ticket5/store-test-config.json")),
                                 readerFor: { kind in kind == .codex ? CredentialedReader(provider: CodexProvider(), source: source) : nil })
        let account = Account(kind: .codex, label: "Personal")
        store.add(account)

        try store.signOut(account.id, hint: CodexProvider.loginHint)

        XCTAssertNil(source.credentials)
        XCTAssertEqual(store.accounts.map(\.id), [account.id], "Sign out keeps the Account")
        XCTAssertNil(store.readings[account.id])
        XCTAssertEqual(store.failures[account.id], .loginExpired(hint: CodexProvider.loginHint))
    }
}
