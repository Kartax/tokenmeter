import XCTest
@testable import TokenMeter

/// Seam A: recorded `/api/oauth/usage` and `/api/oauth/profile` responses → Reading or ReadingFailure.
final class ClaudeProviderTests: XCTestCase {
    private let account = Account(kind: .claude, label: "Personal")
    private let now = date("2026-10-18T12:00:00Z")
    private lazy var credentials = ClaudeCredentials(accessToken: "test-access-token",
                                                     expiresAt: now.addingTimeInterval(3600),
                                                     subscriptionType: "max", rateLimitTier: nil)

    private func read(_ routes: [String: HTTPStub.Response],
                      credentials: ClaudeCredentials? = nil) async -> Result<Reading, ReadingFailure> {
        await ClaudeProvider().read(account: account, credentials: credentials ?? self.credentials,
                                    session: HTTPStub.session(routes), now: now).outcome
    }

    func testMaxPlanHasMainSessionAndWeekAndScopedWeeklyWindows() async throws {
        let reading = try await read([
            "GET /api/oauth/usage": .fixture("claude-usage-max"),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.quotas.map(\.window.identity),
                       [.session, .week, .scoped("seven_day_opus"), .scoped("seven_day_sonnet")])
        XCTAssertEqual(reading.quotas.map(\.window.title), ["Session", "Week", "Opus week", "Sonnet week"])
        XCTAssertEqual(reading.quotas.map(\.window.isMain), [true, true, false, false])
        XCTAssertEqual(reading.quotas.map(\.percentUsed), [12.5, 30, 2, 5])
        XCTAssertEqual(reading.quotas.map(\.window.length), [18000, 604800, 604800, 604800])
        assertResets(reading.quotas, ["2026-10-18T14:30:00Z", "2026-10-23T09:00:00Z",
                                      "2026-10-23T09:00:00Z", "2026-10-23T09:00:00Z"])
    }

    func testEnabledExtraUsageIsANonMainCreditBalanceInDollars() async throws {
        let reading = try await read([
            "GET /api/oauth/usage": .fixture("claude-usage-max"),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ]).get()

        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "extra_usage", title: "Extra usage", remaining: 15, allowance: 20,
                          currency: "USD", renewsAt: nil, isMain: false),
        ])
    }

    func testPlanAndIdentityComeFromTheProfile() async throws {
        let reading = try await read([
            "GET /api/oauth/usage": .fixture("claude-usage-max"),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ]).get()

        XCTAssertEqual(reading.plan, "Max 5x")
        XCTAssertEqual(reading.identity, "user@example.com")
    }

    func testRequestsCarryTheOAuthTokenAndClaudeCodeHeaders() async throws {
        _ = try await read([
            "GET /api/oauth/usage": .fixture("claude-usage-max"),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ]).get()

        let usage = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == "/api/oauth/usage" })
        XCTAssertEqual(usage.url?.host, "api.anthropic.com")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-cli/"), true)
        XCTAssertEqual(usage.value(forHTTPHeaderField: "User-Agent")?.hasSuffix(" (external, cli)"), true)
        let profile = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == "/api/oauth/profile" })
        XCTAssertEqual(profile.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func testNullWindowsWithSpendAreAMainCreditBalance() async throws {
        let reading = try await read([
            "GET /api/oauth/usage": .fixture("claude-usage-spend"),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ]).get()

        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "spend", title: "Spend limit", remaining: Decimal(string: "37.5")!, allowance: 50,
                          currency: "USD", renewsAt: date("2026-11-01T00:00:00Z"), isMain: true),
        ])
    }

    func testLegacyFlatUtilizationFieldsAreAccepted() async throws {
        let reading = try await read([
            "GET /api/oauth/usage": .fixture("claude-usage-legacy"),
            "GET /api/oauth/profile": .status(500),
        ]).get()

        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .session, title: "Session", isMain: true,
                                 resetsAt: date("2026-10-18T15:00:00Z"), length: 18000), percentUsed: 40),
            Quota(window: Window(identity: .week, title: "Week", isMain: true,
                                 resetsAt: date("2026-10-22T00:00:00Z"), length: 604800), percentUsed: 104.5),
            Quota(window: Window(identity: .scoped("seven_day_opus"), title: "Opus week", isMain: false,
                                 resetsAt: date("2026-10-22T00:00:00Z"), length: 604800), percentUsed: 10),
        ])
        XCTAssertEqual(reading.quotas[1].percentUsed, 100)
        XCTAssertTrue(reading.quotas[1].limitReached)
    }

    func testFailingProfileFallsBackToTheSubscriptionTypeAndNoIdentity() async throws {
        let reading = try await read([
            "GET /api/oauth/usage": .fixture("claude-usage-max"),
            "GET /api/oauth/profile": .status(500),
        ]).get()

        XCTAssertEqual(reading.plan, "Max")
        XCTAssertNil(reading.identity)
    }

    func testExpiredTokenIsLoginExpiredWithoutAnyRequest() async {
        let expired = ClaudeCredentials(accessToken: "test-access-token", expiresAt: now.addingTimeInterval(-1),
                                        subscriptionType: "max", rateLimitTier: nil)
        let result = await read([
            "GET /api/oauth/usage": .fixture("claude-usage-max"),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ], credentials: expired)

        XCTAssertEqual(result, .failure(.loginExpired(hint: "run `claude`")))
        XCTAssertEqual(HTTPStub.requests, [])
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([
            "GET /api/oauth/usage": .fixture("claude-unauthorized", status: 401),
            "GET /api/oauth/profile": .fixture("claude-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "run `claude`")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            "GET /api/oauth/usage": .status(403),
            "GET /api/oauth/profile": .status(403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "run `claude`")))
    }

    func testTooManyRequestsBacksOffAtLeastFiveMinutes() async {
        let result = await read([
            "GET /api/oauth/usage": .status(429, headers: ["Retry-After": "42"]),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 300)))
    }

    func testTooManyRequestsHonoursALongerRetryAfter() async {
        let result = await read([
            "GET /api/oauth/usage": .status(429, headers: ["Retry-After": "900"]),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 900)))
    }

    func testTooManyRequestsWithoutRetryAfterBacksOffFiveMinutes() async {
        let result = await read([
            "GET /api/oauth/usage": .status(429),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 300)))
    }

    func testUnknownUsageShapeIsUnavailable() async {
        let result = await read([
            "GET /api/oauth/usage": .json(#"{"five_hour":null,"seven_day":null,"something_new":1}"#),
            "GET /api/oauth/profile": .fixture("claude-profile"),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read([
            "GET /api/oauth/usage": .status(500),
            "GET /api/oauth/profile": .status(500),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    private func assertResets(_ quotas: [Quota], _ expected: [String],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(quotas.count, expected.count, file: file, line: line)
        for (quota, iso) in zip(quotas, expected) {
            guard let resetsAt = quota.window.resetsAt else {
                XCTFail("\(quota.window.title) has no reset time", file: file, line: line)
                continue
            }
            XCTAssertEqual(resetsAt.timeIntervalSince(date(iso)), 0, accuracy: 1, file: file, line: line)
        }
    }
}
