import XCTest
@testable import TokenMeter

/// Seam A: recorded `/api/monitor/usage/quota/limit` and `/api/biz/subscription/list`
/// responses → Reading or ReadingFailure.
final class ZaiProviderTests: XCTestCase {
    private let account = Account(kind: .zai, label: "GLM")
    private let credentials = ZaiCredentials(apiKey: "test-api-key")
    private let now = date("2026-10-18T12:00:00Z")

    private let quotaPath = "GET /api/monitor/usage/quota/limit"
    private let subscriptionPath = "GET /api/biz/subscription/list"

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await ZaiProvider().read(account: account, credentials: credentials,
                                 session: HTTPStub.session(routes), now: now).outcome
    }

    func testQuotaMapsSessionWeeklyAndWebSearchAndSubscriptionPlan() async throws {
        let reading = try await read([
            quotaPath: .fixture("zai-quota-full"),
            subscriptionPath: .fixture("zai-subscription"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "GLM Coding Plan Pro")
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas.count, 3)

        XCTAssertEqual(reading.quotas[0].window,
                       Window(identity: .session, title: "Session", isMain: true,
                              resetsAt: date("2026-10-18T18:00:00Z"), length: 5 * 3600))
        XCTAssertEqual(reading.quotas[0].percentUsed, 42, accuracy: 0.001)
        XCTAssertFalse(reading.quotas[0].limitReached)

        XCTAssertEqual(reading.quotas[1].window,
                       Window(identity: .week, title: "Weekly", isMain: false,
                              resetsAt: date("2026-10-25T00:00:00Z"), length: 7 * 86400))
        XCTAssertEqual(reading.quotas[1].percentUsed, 14, accuracy: 0.001)

        XCTAssertEqual(reading.quotas[2].window,
                       Window(identity: .scoped("web_search"), title: "Web searches", isMain: false,
                              resetsAt: date("2026-11-01T09:30:00Z"), length: nil))
        XCTAssertEqual(reading.quotas[2].percentUsed, 25, accuracy: 0.001)
    }

    func testDateOnlySubscriptionRenewalParsesAndResetsWebSearch() async throws {
        let reading = try await read([
            quotaPath: .json("""
                {"code":200,"success":true,"data":{"limits":[
                  {"type":"TIME_LIMIT","unit":5,"number":1,"usage":10,"currentValue":1,"percentage":10}
                ]}}
                """),
            subscriptionPath: .json("""
                {"code":200,"success":true,"data":[
                  {"productName":"GLM Coding Plan Pro","status":"VALID","nextRenewTime":"2026-11-12"}
                ]}
                """),
        ]).get()

        XCTAssertEqual(reading.plan, "GLM Coding Plan Pro")
        XCTAssertEqual(reading.quotas.first?.window.resetsAt, date("2026-11-12T00:00:00Z"))
    }

    func testRequestUsesBearerTokenAndZaiHosts() async throws {
        _ = try await read([
            quotaPath: .fixture("zai-quota-full"),
            subscriptionPath: .fixture("zai-subscription"),
        ]).get()

        XCTAssertEqual(HTTPStub.requests.count, 2)
        for request in HTTPStub.requests {
            XCTAssertEqual(request.url?.host, "api.z.ai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        }
        let paths = Set(HTTPStub.requests.compactMap(\.url?.path))
        XCTAssertEqual(paths, ["/api/monitor/usage/quota/limit", "/api/biz/subscription/list"])
    }

    func testPercentageWinsOverCounts() async throws {
        let reading = try await read([quotaPath: .fixture("zai-quota-full")]).get()

        // Session: percentage 42, while currentValue/usage would be 30%.
        XCTAssertEqual(reading.quotas.first?.percentUsed ?? 0, 42, accuracy: 0.001)
    }

    func testMissingPercentageFallsBackToCounts() async throws {
        // Weekly has no percentage: currentValue/usage = 14%, remaining/usage = 20%.
        let reading = try await read([quotaPath: .fixture("zai-quota-full")]).get()

        XCTAssertEqual(reading.quotas[1].percentUsed, 14, accuracy: 0.001)

        let remainingOnly = try await read([
            quotaPath: .json("""
                {"code":200,"success":true,"data":{"limits":[
                  {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":200,"remaining":50}
                ]}}
                """),
        ]).get()
        XCTAssertEqual(remainingOnly.quotas.first?.percentUsed ?? 0, 75, accuracy: 0.001)
    }

    func testWebSearchOnlyIsMainAndResetsNextMonthUTC() async throws {
        let reading = try await read([
            quotaPath: .json("""
                {"code":200,"success":true,"data":{"limits":[
                  {"type":"TIME_LIMIT","unit":5,"number":1,"usage":10,"currentValue":1,"percentage":10}
                ]}}
                """),
        ]).get()

        XCTAssertEqual(reading.quotas.count, 1)
        XCTAssertEqual(reading.quotas.first?.window,
                       Window(identity: .scoped("web_search"), title: "Web searches", isMain: true,
                              resetsAt: date("2026-11-01T00:00:00Z"), length: nil))
        XCTAssertEqual(try XCTUnwrap(reading.quotas.first?.percentUsed), 10, accuracy: 0.001)
        XCTAssertNil(reading.plan)
    }

    func testEmptyLimitsIsAResultWithoutQuotas() async throws {
        let reading = try await read([quotaPath: .fixture("zai-quota-empty")]).get()

        XCTAssertEqual(reading.quotas, [])
        XCTAssertNil(reading.plan)
    }

    func testMissingLimitsIsUnexpectedResponse() async {
        let result = await read([quotaPath: .fixture("zai-quota-missing")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([quotaPath: .fixture("zai-unauthorized", status: 401)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([quotaPath: .fixture("zai-unauthorized", status: 403)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([quotaPath: .status(429, headers: ["Retry-After": "42"])])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read([quotaPath: .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testBodyCodeErrorWithHTTP200IsUnavailable() async {
        let result = await read([quotaPath: .fixture("zai-code-error")])

        XCTAssertEqual(result, .failure(.unavailable("Invalid API key")))
    }
}
