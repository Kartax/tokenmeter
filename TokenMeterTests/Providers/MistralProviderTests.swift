import XCTest
@testable import TokenMeter

/// Seam A: recorded `/v1/admin/spend-limit` responses → Reading or ReadingFailure.
final class MistralProviderTests: XCTestCase {
    private let account = Account(kind: .mistral, label: "Organization")
    private let credentials = MistralCredentials(adminKey: "test-admin-key")
    private let now = date("2026-10-18T12:00:00Z")
    private let path = "GET /v1/admin/spend-limit"

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await MistralProvider().read(account: account, credentials: credentials,
                                     session: HTTPStub.session(routes), now: now).outcome
    }

    func testMonthlySpendQuotaMapsUsageAgainstLimit() async throws {
        let reading = try await read([path: .fixture("mistral-spend-limit")]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas.count, 1)
        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.window, Window(identity: .month, title: "Monthly spend", isMain: true,
                                            resetsAt: date("2026-11-01T00:00:00Z"),
                                            length: 31 * 86400))
        XCTAssertEqual(quota.percentUsed, 24.69, accuracy: 0.001)
        XCTAssertFalse(quota.limitReached)
    }

    func testTotalUsageIsPreferredOverUsage() async throws {
        let reading = try await read([path: .fixture("mistral-spend-total-usage")]).get()

        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.percentUsed, 50, accuracy: 0.001)
        XCTAssertFalse(quota.limitReached)
    }

    func testReachedMonthlyLimitIsOneHundredPercent() async throws {
        let reading = try await read([path: .fixture("mistral-spend-limit-reached")]).get()

        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.percentUsed, 100)
        XCTAssertTrue(quota.limitReached)
    }

    func testNoMonthlyLimitIsUnavailable() async {
        let result = await read([path: .fixture("mistral-spend-no-monthly-limit")])

        XCTAssertEqual(result, .failure(.unavailable("No monthly spend limit is configured")))
    }

    func testMissingLimitIsUnavailable() async {
        let result = await read([path: .fixture("mistral-spend-missing-limit")])

        XCTAssertEqual(result, .failure(.unavailable("No monthly spend limit is configured")))
    }

    func testMalformedBodyIsUnexpectedResponse() async {
        for body in [#"{}"#, #"{"limits":{}}"#] {
            let result = await read([path: .json(body)])
            XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
        }
    }

    func testRequestUsesAdminKeyHeaderAndSpendLimitPath() async throws {
        _ = try await read([path: .fixture("mistral-spend-limit")]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.host, "api.mistral.ai")
        XCTAssertEqual(request.url?.path, "/v1/admin/spend-limit")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-admin-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testUnauthorizedAdminKeyIsLoginExpired() async {
        let result = await read([path: .fixture("mistral-unauthorized", status: 401)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Use a Mistral Admin API key (Enterprise)")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([path: .fixture("mistral-unauthorized", status: 403)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Use a Mistral Admin API key (Enterprise)")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([path: .status(429, headers: ["Retry-After": "30"])])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 30)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read([path: .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }
}
