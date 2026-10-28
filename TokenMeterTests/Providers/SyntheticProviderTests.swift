import XCTest
@testable import TokenMeter

/// Seam A: recorded `/v2/quotas` responses → Reading or ReadingFailure.
final class SyntheticProviderTests: XCTestCase {
    private let account = Account(kind: .synthetic, label: "Personal")
    private let credentials = SyntheticCredentials(apiKey: "test-api-key")
    private let now = date("2026-10-18T12:00:00Z")

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await SyntheticProvider().read(account: account, credentials: credentials,
                                       session: HTTPStub.session(routes), now: now).outcome
    }

    func testFullResponseMapsEveryKnownWindowWithRollingAsMain() async throws {
        let reading = try await read(["GET /v2/quotas": .fixture("synthetic-quotas-full")]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .scoped("rolling_5h"), title: "5-hour limit", isMain: true,
                                 resetsAt: date("2026-10-18T15:00:00Z"), length: 18000),
                  percentUsed: 60),
            Quota(window: Window(identity: .week, title: "Weekly budget", isMain: false,
                                 resetsAt: date("2026-10-22T00:00:00Z"), length: 604800),
                  percentUsed: 75),
            Quota(window: Window(identity: .month, title: "Subscription", isMain: false,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
                  percentUsed: 25),
            Quota(window: Window(identity: .scoped("search"), title: "Search", isMain: false,
                                 resetsAt: date("2026-10-18T12:30:00Z"), length: 3600),
                  percentUsed: 40),
        ])
    }

    func testLimitedRollingWindowIsFullAndLimitReached() async throws {
        let reading = try await read(["GET /v2/quotas": .fixture("synthetic-quotas-limited")]).get()

        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.window.identity, .scoped("rolling_5h"))
        XCTAssertTrue(quota.window.isMain)
        XCTAssertEqual(quota.percentUsed, 100)
        XCTAssertTrue(quota.limitReached)
        XCTAssertEqual(reading.quotas.count, 1)
    }

    func testPercentOnlyWeeklyIsMainWhenRollingIsMissing() async throws {
        let reading = try await read(["GET /v2/quotas": .fixture("synthetic-quotas-weekly")]).get()

        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .week, title: "Weekly budget", isMain: true,
                                 resetsAt: date("2026-10-22T00:00:00Z"), length: 604800),
                  percentUsed: 37.5),
        ])
    }

    func testPlanWeeklyCreditsAreMainInsteadOfUnusedSubscriptionRequests() async throws {
        let reading = try await read(["GET /v2/quotas": .fixture("synthetic-quotas-plan-weekly")]).get()

        let main = try XCTUnwrap(reading.quotas.first(where: { $0.window.isMain }))
        XCTAssertEqual(main.window.identity, .week)
        XCTAssertEqual(main.percentUsed, 13.663836, accuracy: 0.000001)
        // The next 2% regeneration tick is not a full quota reset.
        XCTAssertNil(main.window.resetsAt)
        XCTAssertEqual(reading.quotas.filter { $0.window.identity == .week }.count, 1)
    }

    func testLegacySubscriptionIsMainAndSearchIsAnExtra() async throws {
        let reading = try await read(["GET /v2/quotas": .fixture("synthetic-quotas-legacy")]).get()

        XCTAssertEqual(reading.quotas.count, 2)
        XCTAssertEqual(reading.quotas[0].window,
                       Window(identity: .month, title: "Subscription", isMain: true,
                              resetsAt: date("2026-11-01T00:00:00Z"), length: nil))
        XCTAssertEqual(reading.quotas[0].percentUsed, 20)
        XCTAssertEqual(reading.quotas[1].window,
                       Window(identity: .scoped("search"), title: "Search", isMain: false,
                              resetsAt: date("2026-10-18T12:30:00Z"), length: 3600))
        XCTAssertEqual(reading.quotas[1].percentUsed, 5)
    }

    func testMissingKnownQuotasIsUnexpectedResponse() async {
        let result = await read(["GET /v2/quotas": .fixture("synthetic-quotas-empty")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testMalformedQuotaFieldsAreUnexpectedResponse() async {
        let result = await read(["GET /v2/quotas": .fixture("synthetic-quotas-malformed")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testRequestUsesBearerTokenAndQuotasPath() async throws {
        _ = try await read(["GET /v2/quotas": .fixture("synthetic-quotas-full")]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.host, "api.synthetic.new")
        XCTAssertEqual(request.url?.path, "/v2/quotas")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([
            "GET /v2/quotas": .fixture("synthetic-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            "GET /v2/quotas": .fixture("synthetic-unauthorized", status: 403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "GET /v2/quotas": .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["GET /v2/quotas": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }
}
