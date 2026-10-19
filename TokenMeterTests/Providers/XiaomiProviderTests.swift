import XCTest
@testable import TokenMeter

/// Seam A: recorded `/balance` and token-plan responses → Reading or ReadingFailure.
final class XiaomiProviderTests: XCTestCase {
    private let account = Account(kind: .xiaomi, label: "Personal")
    private let credentials = XiaomiCredentials(
        cookie: "api-platform_serviceToken=test-service-token; userId=test-user")
    private let now = date("2026-10-18T12:00:00Z")

    private let balance = "GET /api/v1/balance"
    private let detail = "GET /api/v1/tokenPlan/detail"
    private let usage = "GET /api/v1/tokenPlan/usage"

    private func read(_ routes: [String: HTTPStub.Response],
                      credentials: XiaomiCredentials? = nil) async -> Result<Reading, ReadingFailure> {
        await XiaomiProvider().read(account: account, credentials: credentials ?? self.credentials,
                                    session: HTTPStub.session(routes), now: now).outcome
    }

    func testBalancePlanAndUsageMapQuotaPlanAndCredits() async throws {
        let reading = try await read([
            balance: .fixture("xiaomi-balance"),
            detail: .fixture("xiaomi-token-plan-detail"),
            usage: .fixture("xiaomi-token-plan-usage"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "MiMo Token Plan")
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .month, title: "MiMo tokens", isMain: true,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
                  percentUsed: 32),
        ])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "balance", title: "Balance", remaining: Decimal(string: "12.50")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: true),
            CreditBalance(id: "cash", title: "Cash balance", remaining: 2,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
            CreditBalance(id: "gift", title: "Gift balance", remaining: Decimal(string: "1.50")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
        ])
    }

    func testBalanceOnlyMapsMainCreditAndSkipsMissingTokenPlan() async throws {
        let reading = try await read([balance: .fixture("xiaomi-balance")]).get()

        XCTAssertNil(reading.plan)
        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "balance", title: "Balance", remaining: Decimal(string: "12.50")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: true),
            CreditBalance(id: "cash", title: "Cash balance", remaining: 2,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
            CreditBalance(id: "gift", title: "Gift balance", remaining: Decimal(string: "1.50")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
        ])
    }

    func testMonthPercentIsTheQuotaWithoutPricedItems() async throws {
        let reading = try await read([
            balance: .fixture("xiaomi-balance"),
            detail: .fixture("xiaomi-token-plan-detail"),
            usage: .fixture("xiaomi-token-plan-usage-percent"),
        ]).get()

        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .month, title: "Token plan", isMain: true,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
                  percentUsed: 47.5),
        ])
    }

    func testRequestUsesCookieHeaderAndBrowserHeaders() async throws {
        _ = try await read([balance: .fixture("xiaomi-balance")]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == "/api/v1/balance" })
        XCTAssertEqual(request.url?.host, "platform.xiaomimimo.com")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"),
                       "api-platform_serviceToken=test-service-token; userId=test-user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/plain, */*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://platform.xiaomimimo.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"),
                       "https://platform.xiaomimimo.com/#/console/balance")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-timeZone"), "UTC+01:00")
        let userAgent = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(userAgent.contains("Mozilla/5.0"))
    }

    func testCookieLabelPrefixIsNotSent() async throws {
        let prefixed = XiaomiCredentials(cookie: "Cookie: api-platform_serviceToken=test-service-token; userId=test-user")
        _ = try await read([balance: .fixture("xiaomi-balance")], credentials: prefixed).get()

        let request = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == "/api/v1/balance" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"),
                       "api-platform_serviceToken=test-service-token; userId=test-user")
    }

    func testBodyCode401IsLoginExpired() async {
        let result = await read([balance: .fixture("xiaomi-unauthorized")])

        XCTAssertEqual(result, .failure(.loginExpired(
            hint: "Paste fresh cookies from platform.xiaomimimo.com")))
    }

    func testUnauthorizedAndForbiddenAreLoginExpired() async {
        for status in [401, 403] {
            let result = await read([balance: .status(status)])
            XCTAssertEqual(result, .failure(.loginExpired(
                hint: "Paste fresh cookies from platform.xiaomimimo.com")))
        }
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([balance: .status(429, headers: ["Retry-After": "42"])])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read([balance: .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMalformedBalanceIsUnavailable() async {
        let result = await read([balance: .fixture("xiaomi-balance-malformed")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testMissingRequiredCookieIsLoginExpiredWithoutARequest() async {
        let result = await read([balance: .fixture("xiaomi-balance")],
                                credentials: XiaomiCredentials(
                                    cookie: "api-platform_serviceToken=test-service-token; sessionId=test-session"))

        XCTAssertEqual(result, .failure(.loginExpired(
            hint: "Paste fresh cookies from platform.xiaomimimo.com")))
        XCTAssertTrue(HTTPStub.requests.isEmpty)
    }
}
