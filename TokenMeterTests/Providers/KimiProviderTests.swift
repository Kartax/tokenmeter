import XCTest
@testable import TokenMeter

/// Seam A: recorded `/coding/v1/usages` responses → Reading or ReadingFailure.
final class KimiProviderTests: XCTestCase {
    private let account = Account(kind: .kimi, label: "Personal")
    private let credentials = KimiCredentials(accessToken: "test-access-token")
    private let now = date("2026-10-18T12:00:00Z")

    private func read(_ routes: [String: HTTPStub.Response],
                      credentials: KimiCredentials? = nil) async -> Result<Reading, ReadingFailure> {
        await KimiProvider().read(account: account,
                                  credentials: credentials ?? self.credentials,
                                  session: HTTPStub.session(routes), now: now).outcome
    }

    func testFullUsageAndLimitsMapWindowsAndMembershipPlan() async throws {
        let reading = try await read(["GET /coding/v1/usages": .fixture("kimi-usage-full")]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Intermediate")
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas.count, 3)

        XCTAssertEqual(reading.quotas[0].window,
                       Window(identity: .month, title: "Plan", isMain: true,
                              resetsAt: date("2026-11-01T00:00:00Z"), length: nil))
        XCTAssertEqual(reading.quotas[0].percentUsed, 26, accuracy: 0.001)
        XCTAssertFalse(reading.quotas[0].limitReached)

        XCTAssertEqual(reading.quotas[1].window,
                       Window(identity: .scoped("limit-300-TIME_UNIT_MINUTE"), title: "Session",
                              isMain: false, resetsAt: date("2026-10-18T17:00:00Z"), length: 18_000))
        XCTAssertEqual(reading.quotas[1].percentUsed, 0, accuracy: 0.001)

        XCTAssertEqual(reading.quotas[2].window,
                       Window(identity: .scoped("limit-10080-TIME_UNIT_MINUTE"), title: "Weekly",
                              isMain: false, resetsAt: date("2026-10-25T00:00:00Z"), length: 604_800))
        XCTAssertEqual(reading.quotas[2].percentUsed, 75, accuracy: 0.001)
    }

    func testStringEncodedNumbersStillMapQuotas() async throws {
        let reading = try await read(["GET /coding/v1/usages": .fixture("kimi-usage-strings")]).get()

        XCTAssertEqual(reading.plan, "Basic")
        XCTAssertEqual(reading.quotas.count, 2)
        XCTAssertEqual(reading.quotas[0].percentUsed, 70, accuracy: 0.001)
        XCTAssertEqual(reading.quotas[1].percentUsed, 80, accuracy: 0.001)
        XCTAssertEqual(reading.quotas[1].window.title, "Session")
        XCTAssertEqual(reading.quotas[1].window.length, 18_000)
    }

    func testPercentUsedComesFromLimitAndRemainingAndIsClamped() async throws {
        let reading = try await read([
            "GET /coding/v1/usages": .json("""
                {"usage":{"limit":100,"remaining":0},"limits":[]}
                """),
        ]).get()

        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.percentUsed, 100)
        XCTAssertTrue(quota.limitReached)
        XCTAssertEqual(quota.window.identity, .month)
        XCTAssertEqual(quota.window.title, "Plan")
        XCTAssertNil(quota.window.resetsAt)
        XCTAssertNil(quota.window.length)
    }

    func testLimitsOnlyMakesTheMostConstrainedLimitMain() async throws {
        let reading = try await read(["GET /coding/v1/usages": .fixture("kimi-limits-only")]).get()

        XCTAssertEqual(reading.plan, "LEVEL_FREE")
        XCTAssertEqual(reading.quotas.count, 3)
        XCTAssertEqual(reading.quotas.map(\.window.isMain), [false, true, false])
        XCTAssertEqual(reading.quotas[1].percentUsed, 80, accuracy: 0.001)
        XCTAssertEqual(reading.quotas[0].window.title, "60 minute")
        XCTAssertEqual(reading.quotas[1].window.title, "Session")
        XCTAssertEqual(reading.quotas[2].window.title, "Weekly")
        XCTAssertEqual(reading.quotas[2].window.length, 604_800)
        XCTAssertEqual(reading.quotas[0].window.identity, .scoped("limit-60-TIME_UNIT_MINUTE"))
        XCTAssertEqual(reading.quotas[2].window.identity, .scoped("limit-7-TIME_UNIT_DAY"))
    }

    func testRequestUsesBearerTokenAndKimiHost() async throws {
        _ = try await read(["GET /coding/v1/usages": .fixture("kimi-usage-full")]).get()

        XCTAssertEqual(HTTPStub.requests.count, 1)
        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.host, "api.kimi.com")
        XCTAssertEqual(request.url?.path, "/coding/v1/usages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([
            "GET /coding/v1/usages": .fixture("kimi-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `kimi login`")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            "GET /coding/v1/usages": .fixture("kimi-unauthorized", status: 403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Run `kimi login`")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "GET /coding/v1/usages": .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["GET /coding/v1/usages": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMalformedResponseIsUnavailable() async {
        for body in [
            "{}",
            "not json",
            #"{"usage":{"limit":"not a number","remaining":"1"},"limits":[]}"#,
            #"{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}]}"#,
        ] {
            let result = await read(["GET /coding/v1/usages": .json(body)])
            XCTAssertEqual(result, .failure(.unavailable("Unexpected response")), body)
        }
    }

    // MARK: - Borrowed credential refresh

    func testNearExpiryRefreshesInMemoryButNeverReturnsRotatedCredentials() async throws {
        let expiring = KimiCredentials(accessToken: "test-expired-token",
                                       refreshToken: "test-refresh-token",
                                       expiresAt: now.addingTimeInterval(-10).timeIntervalSince1970)
        let result = await KimiProvider().read(
            account: account, credentials: expiring,
            session: HTTPStub.session([
                "POST /api/oauth/token": .json("""
                    {"access_token":"test-refreshed-token","refresh_token":"test-rotated-refresh","expires_in":3600}
                    """),
                "GET /coding/v1/usages": .fixture("kimi-usage-full"),
            ]), now: now)
        _ = try result.outcome.get()

        XCTAssertNil(result.rotatedCredentials)
        XCTAssertEqual(HTTPStub.requests.count, 2)
        let refresh = HTTPStub.requests[0]
        XCTAssertEqual(refresh.httpMethod, "POST")
        XCTAssertEqual(refresh.url?.host, "auth.kimi.com")
        XCTAssertEqual(refresh.url?.path, "/api/oauth/token")
        XCTAssertEqual(refresh.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let form = String(decoding: HTTPStub.body(of: refresh), as: UTF8.self)
        XCTAssertTrue(form.contains("client_id=17e5f671-d194-4dfb-9706-5516cb48c098"))
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=test-refresh-token"))
        XCTAssertEqual(HTTPStub.requests[1].value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-refreshed-token")
    }

    func testRefreshRejectionIsLoginExpired() async {
        let expiring = KimiCredentials(accessToken: "test-expired-token",
                                       refreshToken: "test-refresh-token",
                                       expiresAt: now.addingTimeInterval(-10).timeIntervalSince1970)
        let result = await KimiProvider().read(
            account: account, credentials: expiring,
            session: HTTPStub.session(["POST /api/oauth/token": .status(400)]), now: now)

        XCTAssertEqual(result.outcome, .failure(.loginExpired(hint: "Run `kimi login`")))
        XCTAssertNil(result.rotatedCredentials)
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }

    func testExpiredTokenWithoutRefreshTokenIsLoginExpired() async {
        let expiring = KimiCredentials(accessToken: "test-expired-token",
                                       expiresAt: now.addingTimeInterval(-10).timeIntervalSince1970)
        let result = await KimiProvider().read(
            account: account, credentials: expiring,
            session: HTTPStub.session([:]), now: now)

        XCTAssertEqual(result.outcome, .failure(.loginExpired(hint: "Run `kimi login`")))
        XCTAssertTrue(HTTPStub.requests.isEmpty)
    }

    // MARK: - Borrowed credential source

    func testCredentialSourceParsesKimiCodeFile() {
        let data = Data(#"""
            {"access_token":"test-token","refresh_token":"test-refresh","expires_at":1760000000.5}
            """#.utf8)

        XCTAssertEqual(KimiCredentialSource.parse(data),
                       KimiCredentials(accessToken: "test-token", refreshToken: "test-refresh",
                                       expiresAt: 1_760_000_000.5))
    }

    func testCredentialSourceRejectsFileWithoutAccessToken() {
        XCTAssertNil(KimiCredentialSource.parse(Data(#"{"refresh_token":"test-refresh"}"#.utf8)))
        XCTAssertNil(KimiCredentialSource.parse(Data("not json".utf8)))
    }

    func testCredentialSourceReadsTheBorrowedFileFresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("kimi-code.json")
        try Data(#"{"access_token":"test-first-token","expires_at":1760000000}"#.utf8).write(to: url)
        let source = KimiCredentialSource(fileURL: url)

        XCTAssertEqual(try source.load(for: account).get().accessToken, "test-first-token")

        try Data(#"{"access_token":"test-second-token","expires_at":1760000000}"#.utf8).write(to: url)
        XCTAssertEqual(try source.load(for: account).get().accessToken, "test-second-token")
    }

    func testCredentialSourceNeverWritesOrDeletesTheBorrowedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("kimi-code.json")
        let original = Data(#"{"access_token":"test-token","refresh_token":"test-refresh","expires_at":1760000000}"#.utf8)
        try original.write(to: url)
        let source = KimiCredentialSource(fileURL: url)

        try source.save(KimiCredentials(accessToken: "test-rotated-token"), for: account)
        try source.delete(for: account)

        XCTAssertEqual(try Data(contentsOf: url), original)
        switch source.load(for: account) {
        case .failure:
            XCTFail("A borrowed login must remain readable")
        case .success(let loaded):
            XCTAssertEqual(loaded, KimiCredentials(accessToken: "test-token", refreshToken: "test-refresh",
                                                   expiresAt: 1_760_000_000))
        }
    }
}
