import XCTest
@testable import TokenMeter

/// The credential store between Keychain and Provider: rotated credentials are saved before use.
final class CredentialedReaderTests: XCTestCase {
    /// In-memory stand-in for the Keychain item of one Account.
    private final class MemorySource: CredentialSource, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CodexCredentials?
        /// Paths requested from the server at the moment of each save.
        private(set) var savedAfterRequests: [[String?]] = []

        init(_ credentials: CodexCredentials?) { stored = credentials }

        var credentials: CodexCredentials? { lock.withLock { stored } }

        func load(for account: Account) -> Result<CodexCredentials, ReadingFailure> {
            lock.withLock { stored }.map { .success($0) } ?? .failure(.loginExpired(hint: "Sign in again"))
        }

        func save(_ credentials: CodexCredentials, for account: Account) throws {
            lock.withLock {
                stored = credentials
                savedAfterRequests.append(HTTPStub.requests.map { $0.url?.path })
            }
        }

        func delete(for account: Account) throws { lock.withLock { stored = nil } }
    }

    func testRotatedCodexTokensAreStoredBeforeTheRetry() async throws {
        let account = Account(kind: .codex, label: "Personal")
        let newAccess = jwt(["exp": 4102444800])
        let source = MemorySource(CodexCredentials(accessToken: jwt(["exp": 4102444800]), refreshToken: "refresh-old",
                                                   idToken: ""))
        let session = HTTPStub.session(sequences: [
            "GET /backend-api/wham/usage": [.status(401), .fixture("codex-usage-team")],
            "POST /oauth/token": [.json(#"{"access_token":"\#(newAccess)","refresh_token":"refresh-new"}"#)],
        ])

        let result = await CredentialedReader(provider: CodexProvider(), source: source)
            .read(account, session: session, now: date("2026-10-18T12:00:00Z"))

        XCTAssertEqual(try result.get().plan, "Team")
        XCTAssertEqual(source.credentials?.accessToken, newAccess)
        XCTAssertEqual(source.credentials?.refreshToken, "refresh-new")
        XCTAssertEqual(source.savedAfterRequests, [["/backend-api/wham/usage", "/oauth/token"]])
    }
}
