import XCTest
@testable import TokenMeter

/// Seam A: recorded Antigravity `fetchAvailableModels`/`loadCodeAssist` responses → Reading.
final class AntigravityProviderTests: XCTestCase {
    private let account = Account(kind: .antigravity, label: "Personal")
    private let credentials = AntigravityCredentials(accessToken: "test-access-token")
    private let now = date("2026-10-18T12:00:00Z")
    private let modelsPath = "/v1internal:fetchAvailableModels"
    private let planPath = "/v1internal:loadCodeAssist"

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await AntigravityProvider().read(account: account, credentials: credentials,
                                         session: HTTPStub.session(routes), now: now).outcome
    }

    func testModelsMapPerModelQuotasWithTheMostUsedAsMain() async throws {
        let reading = try await read([
            "POST \(modelsPath)": .fixture("antigravity-models"),
            "POST \(planPath)": .fixture("antigravity-load-code-assist"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Free")
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .scoped("claude-sonnet-4-5"), title: "Claude Sonnet 4.5",
                                 isMain: false, resetsAt: date("2026-10-18T17:00:00Z"), length: nil),
                  percentUsed: 25),
            Quota(window: Window(identity: .scoped("gemini-3-pro-high"), title: "Gemini 3 Pro",
                                 isMain: true, resetsAt: date("2026-10-18T16:30:00Z"), length: nil),
                  percentUsed: 75),
        ])
    }

    func testInternalModelsAndEmptyDisplayNamesAreSkipped() async throws {
        let reading = try await read([
            "POST \(modelsPath)": .fixture("antigravity-models"),
        ]).get()

        XCTAssertEqual(reading.quotas.map(\.window.title), ["Claude Sonnet 4.5", "Gemini 3 Pro"])
        XCTAssertFalse(reading.quotas.contains { $0.window.title == "Internal Rollout" })
        XCTAssertEqual(reading.quotas.filter(\.window.isMain).count, 1)
    }

    func testLoadCodeAssistFailureDoesNotFailTheReading() async throws {
        let reading = try await read([
            "POST \(modelsPath)": .fixture("antigravity-models"),
            "POST \(planPath)": .status(500),
        ]).get()

        XCTAssertNil(reading.plan)
        XCTAssertEqual(reading.quotas.count, 2)
    }

    func testRequestUsesBearerTokenAndAntigravityHeaders() async throws {
        _ = try await read([
            "POST \(modelsPath)": .fixture("antigravity-models"),
            "POST \(planPath)": .fixture("antigravity-load-code-assist"),
        ]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == modelsPath })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "cloudcode-pa.googleapis.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "antigravity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Client-Metadata"),
                       #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#)
        XCTAssertEqual(String(data: HTTPStub.body(of: request), encoding: .utf8), "{}")
    }

    func testExpiredCredentialsAreRefreshedInMemoryOnly() async throws {
        let expired = AntigravityCredentials(accessToken: "stale-access-token",
                                             refreshToken: "test-refresh-token",
                                             expiresAt: now.addingTimeInterval(-60),
                                             clientID: "file-client-id",
                                             clientSecret: "file-client-secret")
        let session = HTTPStub.session([
            "POST /token": .json(#"{"access_token":"fresh-access-token","expires_in":3600}"#),
            "POST \(modelsPath)": .fixture("antigravity-models"),
        ])

        let result = await AntigravityProvider().read(account: account, credentials: expired,
                                                      session: session, now: now)

        let reading = try result.outcome.get()
        XCTAssertEqual(reading.quotas.count, 2)
        XCTAssertNil(result.rotatedCredentials)
        let refreshRequest = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == "/token" })
        let form = String(decoding: HTTPStub.body(of: refreshRequest), as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=test-refresh-token"))
        XCTAssertTrue(form.contains("client_id=file-client-id"))
        XCTAssertTrue(form.contains("client_secret=file-client-secret"))
        let modelsRequest = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == modelsPath })
        XCTAssertEqual(modelsRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-access-token")
    }

    func testExpiredCredentialsWithoutClientPairAreLoginExpired() async {
        let expired = AntigravityCredentials(accessToken: "stale-access-token",
                                             refreshToken: "test-refresh-token",
                                             expiresAt: now.addingTimeInterval(-60))
        let result = await AntigravityProvider().read(account: account, credentials: expired,
                                                      session: HTTPStub.session([:]), now: now)

        XCTAssertEqual(result.outcome,
                       .failure(.loginExpired(hint: AntigravityProvider.loginHint)))
        XCTAssertEqual(HTTPStub.requests, [])
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read(["POST \(modelsPath)": .status(401)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: AntigravityProvider.loginHint)))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read(["POST \(modelsPath)": .status(403)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: AntigravityProvider.loginHint)))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "POST \(modelsPath)": .status(429, headers: ["Retry-After": "90"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 90)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["POST \(modelsPath)": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMalformedResponseIsUnexpected() async {
        let result = await read(["POST \(modelsPath)": .json("{not json")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testMissingModelsIsNoAntigravityModels() async {
        let result = await read(["POST \(modelsPath)": .json("{}")])

        XCTAssertEqual(result, .failure(.unavailable("No Antigravity models returned")))
    }

    // MARK: - Borrowed credential parsing

    func testTokenFilePayloadParsesNestedTokenAndISOExpiry() {
        let data = Data(#"{"token":{"access_token":"a","refresh_token":"r","expiry":"2026-10-18T13:00:00Z","client_id":"cid","client_secret":"cs"},"auth_method":"consumer"}"#.utf8)

        XCTAssertEqual(AntigravityCredentialSource.parse(data),
                       AntigravityCredentials(accessToken: "a", refreshToken: "r",
                                              expiresAt: date("2026-10-18T13:00:00Z"),
                                              clientID: "cid", clientSecret: "cs"))
    }

    func testFlatTokenPayloadParsesMillisecondExpiry() {
        let data = Data(#"{"access_token":"a","refresh_token":"r","expires_at":1792328400000}"#.utf8)

        XCTAssertEqual(AntigravityCredentialSource.parse(data),
                       AntigravityCredentials(accessToken: "a", refreshToken: "r",
                                              expiresAt: date("2026-10-18T13:00:00Z")))
    }

    func testKeychainValueDecodesGoKeyringBase64Wrapper() {
        let json = Data(#"{"access_token":"a","refresh_token":"r","expiry":1792328400}"#.utf8)
        let value = Data("go-keyring-base64:\(json.base64EncodedString())".utf8)

        XCTAssertEqual(AntigravityCredentialSource.decodeKeychainValue(value),
                       AntigravityCredentials(accessToken: "a", refreshToken: "r",
                                              expiresAt: date("2026-10-18T13:00:00Z")))
    }

    func testKeychainValueAcceptsBareBase64JSON() {
        let json = Data(#"{"access_token":"a"}"#.utf8)

        XCTAssertEqual(AntigravityCredentialSource.decodeKeychainValue(Data(json.base64EncodedString().utf8)),
                       AntigravityCredentials(accessToken: "a", refreshToken: nil, expiresAt: nil))
    }

    func testMalformedCredentialsAreRejected() {
        XCTAssertNil(AntigravityCredentialSource.parse(Data("not json".utf8)))
        XCTAssertNil(AntigravityCredentialSource.parse(Data(#"{"refresh_token":"r"}"#.utf8)))
        XCTAssertNil(AntigravityCredentialSource.decodeKeychainValue(Data("test-not-base64!".utf8)))
    }

    func testCredentialSourcePrefersTheTokenFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-credentials-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("antigravity-oauth-token")
        try Data(#"{"token":{"access_token":"from-file","refresh_token":"r"}}"#.utf8).write(to: file)

        var source = AntigravityCredentialSource()
        source.tokenFileURL = file
        source.keychainItem = { _, _ in Data(#"{"access_token":"from-keychain"}"#.utf8) }

        XCTAssertEqual(try source.load(for: account).get().accessToken, "from-file")
    }

    func testCredentialSourceFallsBackToTheKeychain() throws {
        var source = AntigravityCredentialSource()
        source.tokenFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-missing-\(UUID().uuidString)")
        source.keychainItem = { service, username in
            XCTAssertEqual(service, "gemini")
            XCTAssertEqual(username, "antigravity")
            return Data(#"{"access_token":"from-keychain"}"#.utf8)
        }

        XCTAssertEqual(try source.load(for: account).get().accessToken, "from-keychain")
    }

    func testCredentialSourceWithoutALoginIsLoginExpired() {
        var source = AntigravityCredentialSource()
        source.tokenFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-missing-\(UUID().uuidString)")
        source.keychainItem = { _, _ in nil }

        XCTAssertEqual(source.load(for: account),
                       .failure(.loginExpired(hint: AntigravityProvider.loginHint)))
    }
}
