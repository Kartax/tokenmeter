import XCTest
@testable import TokenMeter

/// Seam A: recorded `loadCodeAssist` + `retrieveUserQuota` responses → Reading or ReadingFailure.
final class GeminiProviderTests: XCTestCase {
    private let account = Account(kind: .gemini, label: "Personal")
    private let now = date("2026-10-19T12:00:00Z")
    private let credentials = GeminiCredentials(accessToken: "test-access-token",
                                                 expiryDate: date("2026-10-20T12:00:00Z"))
    private let loadRoute = "POST /v1internal:loadCodeAssist"
    private let quotaRoute = "POST /v1internal:retrieveUserQuota"
    private let tokenRoute = "POST /token"

    private func read(_ routes: [String: HTTPStub.Response],
                      credentials: GeminiCredentials? = nil) async -> Result<Reading, ReadingFailure> {
        await GeminiProvider().read(account: account, credentials: credentials ?? self.credentials,
                                    session: HTTPStub.session(routes), now: now).outcome
    }

    func testLoadCodeAssistAndQuotaMapPlanAndBuckets() async throws {
        let reading = try await read([
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .fixture("gemini-quota"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Standard")
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas.map(\.window), [
            Window(identity: .scoped("gemini-2.5-pro"), title: "gemini-2.5-pro",
                   isMain: true, resetsAt: date("2026-10-20T00:00:00Z"), length: nil),
            Window(identity: .scoped("gemini-2.5-flash"), title: "gemini-2.5-flash",
                   isMain: false, resetsAt: date("2026-10-20T00:00:00Z"), length: nil),
        ])
        XCTAssertEqual(reading.quotas.count, 2)
        XCTAssertEqual(reading.quotas[0].percentUsed, 75, accuracy: 0.001)
        XCTAssertEqual(reading.quotas[1].percentUsed, 20, accuracy: 0.001)
    }

    func testRefreshNotNeededUsesAccessTokenAndSendsExpectedRequests() async throws {
        _ = try await read([
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .fixture("gemini-quota"),
        ]).get()

        XCTAssertEqual(HTTPStub.requests.count, 2)
        let load = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(load.url?.host, "cloudcode-pa.googleapis.com")
        XCTAssertEqual(load.url?.path, "/v1internal:loadCodeAssist")
        XCTAssertEqual(load.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        let metadata = try jsonBody(load)
        XCTAssertEqual(metadata["metadata"] as? [String: String], [
            "ideType": "GEMINI_CLI", "pluginType": "GEMINI",
        ])

        let quota = try XCTUnwrap(HTTPStub.requests.last)
        XCTAssertEqual(quota.url?.path, "/v1internal:retrieveUserQuota")
        XCTAssertEqual(quota.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(try jsonBody(quota)["project"] as? String, "test-project-123")
    }

    func testMissingProjectStillCallsQuotaWithEmptyProject() async throws {
        let reading = try await read([
            loadRoute: .fixture("gemini-load-code-assist-no-project"),
            quotaRoute: .fixture("gemini-quota"),
        ]).get()

        XCTAssertEqual(reading.plan, "Free")
        XCTAssertEqual(HTTPStub.requests.count, 2)
        let quota = try XCTUnwrap(HTTPStub.requests.last)
        XCTAssertEqual(try jsonBody(quota)["project"] as? String, "")
        XCTAssertEqual(quota.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func testExpiredTokenIsRefreshedAndRotatedTokenIsNotReturned() async throws {
        let expired = GeminiCredentials(accessToken: "stale-access-token",
                                        refreshToken: "test-refresh-token",
                                        expiryDate: date("2026-10-19T11:00:00Z"),
                                        clientID: "file-client-id",
                                        clientSecret: "file-client-secret")
        let result = await GeminiProvider().read(
            account: account, credentials: expired,
            session: HTTPStub.session([
                tokenRoute: .json(#"{"access_token":"fresh-access-token","expires_in":3600}"#),
                loadRoute: .fixture("gemini-load-code-assist"),
                quotaRoute: .fixture("gemini-quota"),
            ]), now: now)

        XCTAssertNoThrow(try result.outcome.get())
        XCTAssertNil(result.rotatedCredentials)

        XCTAssertEqual(HTTPStub.requests.count, 3)
        let token = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(token.url?.host, "oauth2.googleapis.com")
        XCTAssertEqual(token.url?.path, "/token")
        XCTAssertEqual(token.httpMethod, "POST")
        XCTAssertEqual(token.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        XCTAssertEqual(formFields(HTTPStub.body(of: token)), [
            "client_id": "file-client-id",
            "client_secret": "file-client-secret",
            "refresh_token": "test-refresh-token",
            "grant_type": "refresh_token",
        ])
        XCTAssertEqual(HTTPStub.requests[1].value(forHTTPHeaderField: "Authorization"),
                       "Bearer fresh-access-token")
        XCTAssertEqual(HTTPStub.requests[2].value(forHTTPHeaderField: "Authorization"),
                       "Bearer fresh-access-token")
    }

    func testRefreshWithoutClientPairIsLoginExpired() async {
        let borrowed = GeminiCredentials(accessToken: "", refreshToken: "test-refresh-token")
        let result = await read([:], credentials: borrowed)

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `gemini` to sign in")))
        XCTAssertEqual(HTTPStub.requests, [])
    }

    func testRefreshUsesClientCredentialsFromTheFile() async throws {
        let borrowed = GeminiCredentials(accessToken: "", refreshToken: "test-refresh-token",
                                         clientID: "file-client-id", clientSecret: "file-client-secret")
        _ = try await read([
            tokenRoute: .json(#"{"access_token":"fresh-access-token"}"#),
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .fixture("gemini-quota"),
        ], credentials: borrowed).get()

        let token = try XCTUnwrap(HTTPStub.requests.first)
        let fields = formFields(HTTPStub.body(of: token))
        XCTAssertEqual(fields["client_id"], "file-client-id")
        XCTAssertEqual(fields["client_secret"], "file-client-secret")
    }

    func testRefreshRejectionIsLoginExpired() async {
        let expired = GeminiCredentials(accessToken: "stale-access-token",
                                        refreshToken: "test-refresh-token",
                                        expiryDate: date("2026-10-19T11:00:00Z"),
                                        clientID: "file-client-id",
                                        clientSecret: "file-client-secret")
        let result = await read([
            tokenRoute: .json(#"{"error":"invalid_grant"}"#, status: 400),
        ], credentials: expired)

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `gemini` to sign in")))
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }

    func testMissingRefreshTokenAndNoAccessTokenIsLoginExpired() async {
        let result = await read([:], credentials: GeminiCredentials(accessToken: ""))

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `gemini` to sign in")))
        XCTAssertEqual(HTTPStub.requests, [])
    }

    func testLoadCodeAssistUnauthorizedIsLoginExpired() async {
        let result = await read([
            loadRoute: .status(401),
            quotaRoute: .fixture("gemini-quota"),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `gemini` to sign in")))
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .status(401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `gemini` to sign in")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .status(403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `gemini` to sign in")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read([
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .status(500),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMalformedQuotaIsUnexpectedResponse() async {
        for body in [#"{"quota":[{"modelId":"gemini-2.5-pro"}]}"#,
                     #"{"quota":"not an array"}"#,
                     #"{}"#] {
            let result = await read([
                loadRoute: .fixture("gemini-load-code-assist"),
                quotaRoute: .json(body),
            ])

            XCTAssertEqual(result, .failure(.unavailable("Unexpected response")), body)
        }
    }

    func testNoBucketsIsUnexpectedResponse() async {
        let result = await read([
            loadRoute: .fixture("gemini-load-code-assist"),
            quotaRoute: .json(#"{"quota":[]}"#),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testUnknownTierIdFallsBackToItsName() async throws {
        let reading = try await read([
            loadRoute: .json(#"{"currentTier":{"id":"custom-tier","name":"Gemini Custom"}}"#),
            quotaRoute: .fixture("gemini-quota"),
        ]).get()

        XCTAssertEqual(reading.plan, "Gemini Custom")
    }

    func testEmptyLoadCodeAssistResponseKeepsPlanAndProjectOptional() async throws {
        let reading = try await read([
            loadRoute: .json("{}"),
            quotaRoute: .fixture("gemini-quota"),
        ]).get()

        XCTAssertNil(reading.plan)
        XCTAssertEqual(HTTPStub.requests.count, 2)
        XCTAssertEqual(try jsonBody(HTTPStub.requests[1])["project"] as? String, "")
    }

    // MARK: - Helpers

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: HTTPStub.body(of: request)) as? [String: Any])
    }

    private func formFields(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.count > 1 ? String(parts[1]) : ""
            return (String(parts[0]), value.removingPercentEncoding ?? value)
        })
    }
}

/// The borrowed credential file is read fresh and never written.
final class GeminiCredentialSourceTests: XCTestCase {
    func testReadsFileAndSaveDoesNotModifyIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiCredentialSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("oauth_creds.json")
        let contents = """
            {"access_token":"fake-access-token","refresh_token":"fake-refresh-token",
             "expiry_date":1760000000000,"client_id":"fake-client-id",
             "client_secret":"fake-client-secret"}
            """
        try Data(contents.utf8).write(to: file)

        let source = GeminiCredentialSource(fileURL: file)
        let account = Account(kind: .gemini)
        let credentials = try source.load(for: account).get()
        XCTAssertEqual(credentials.accessToken, "fake-access-token")
        XCTAssertEqual(credentials.refreshToken, "fake-refresh-token")
        XCTAssertEqual(credentials.expiryDate, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(credentials.clientID, "fake-client-id")
        XCTAssertEqual(credentials.clientSecret, "fake-client-secret")

        try source.save(GeminiCredentials(accessToken: "rotated-access-token"), for: account)
        try source.delete(for: account)
        XCTAssertEqual(try Data(contentsOf: file), Data(contents.utf8))
    }

    func testMissingFileIsLoginExpired() {
        let source = GeminiCredentialSource(
            fileURL: URL(fileURLWithPath: "/nonexistent/tokenmeter/gemini/oauth_creds.json"))

        XCTAssertEqual(source.load(for: Account(kind: .gemini)),
                       .failure(.loginExpired(hint: "Run `gemini` to sign in")))
    }
}
