import XCTest
@testable import TokenMeter

/// Seam A: recorded `/v1/token_plan/remains` responses → Reading or ReadingFailure.
final class MiniMaxProviderTests: XCTestCase {
    private let account = Account(kind: .minimax, label: "Personal")
    private let now = date("2026-10-18T12:00:00Z")
    private let path = "GET /v1/token_plan/remains"

    private func read(_ routes: [String: HTTPStub.Response], region: MiniMaxRegion = .global) async
        -> Result<Reading, ReadingFailure> {
        await MiniMaxProvider().read(account: account,
                                     credentials: MiniMaxCredentials(apiKey: "test-api-key", region: region),
                                     session: HTTPStub.session(routes), now: now).outcome
    }

    func testGlobalPlanMapsSessionQuotaAndPlan() async throws {
        let reading = try await read([path: .fixture("minimax-token-plan-global")]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Token Plan Plus")
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas.count, 1)
        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.window, Window(identity: .session, title: "Session", isMain: true,
                                            resetsAt: date("2026-10-18T13:00:00Z"), length: 18000))
        XCTAssertEqual(quota.percentUsed, 60, accuracy: 0.001)
        XCTAssertFalse(quota.limitReached)
    }

    func testRequestUsesBearerTokenAndGlobalHost() async throws {
        _ = try await read([path: .fixture("minimax-token-plan-global")]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.host, "www.minimax.io")
        XCTAssertEqual(request.url?.path, "/v1/token_plan/remains")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testChinaRegionUsesChinaHostAndSuffixesPlan() async throws {
        let reading = try await read([path: .fixture("minimax-token-plan-cn")], region: .cn).get()

        XCTAssertEqual(reading.plan, "Starter (CN)")
        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.percentUsed, 25, accuracy: 0.001)
        XCTAssertEqual(quota.window.resetsAt, date("2026-10-18T13:00:00Z"))
        XCTAssertEqual(quota.window.length, 18000)

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.host, "api.minimaxi.com")
        XCTAssertEqual(request.url?.path, "/v1/token_plan/remains")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
    }

    func testPercentOnlyResponseFallsBackToRemainingPercent() async throws {
        let reading = try await read([path: .fixture("minimax-token-plan-percent")]).get()

        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.percentUsed, 75, accuracy: 0.001)
        XCTAssertEqual(quota.window.resetsAt, date("2026-10-18T14:00:00Z"))
        XCTAssertNil(quota.window.length)
        XCTAssertNil(reading.plan)
    }

    func testRemainingPercentIsInvertedNotTreatedAsUsed() async throws {
        let reading = try await read([
            path: .json(#"{"model_remains":[{"current_interval_remaining_percent":90}]}"#),
        ]).get()

        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.percentUsed, 10, accuracy: 0.001)
    }

    func testMissingTotalsIsUnavailable() async {
        let result = await read([path: .fixture("minimax-token-plan-missing-totals")])

        XCTAssertEqual(result, .failure(.unavailable("Missing usage data")))
    }

    func testPlanComesFromResponseTitleBeforeModelPlan() async throws {
        let reading = try await read([path: .fixture("minimax-token-plan-plan")]).get()

        XCTAssertEqual(reading.plan, "Token Plan Max")
        XCTAssertEqual(reading.quotas.first?.percentUsed, 50)
    }

    func testMostConstrainedModelBucketIsChosen() async throws {
        let reading = try await read([path: .fixture("minimax-token-plan-multiple")]).get()

        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.percentUsed, 90, accuracy: 0.001)
        XCTAssertEqual(reading.plan, "Second")
    }

    func testExplicitUsedCountWinsOverRemainingCount() async throws {
        let reading = try await read([
            path: .json("""
                {"base_resp":{"status_code":0},"model_remains":[{
                  "current_interval_total_count":100,
                  "current_interval_usage_count":10,
                  "current_interval_used_count":75
                }]}
                """),
        ]).get()

        XCTAssertEqual(reading.quotas.first?.percentUsed, 75)
    }

    func testEndTimeAcceptsEpochSeconds() async throws {
        let reading = try await read([path: .fixture("minimax-token-plan-seconds")]).get()

        XCTAssertEqual(reading.quotas.first?.window.resetsAt, date("2026-10-18T13:00:00Z"))
        XCTAssertEqual(reading.quotas.first?.percentUsed, 10)
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([path: .status(401)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check MiniMax API key")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([path: .status(403)])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check MiniMax API key")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([path: .status(429, headers: ["Retry-After": "42"])])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read([path: .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testAPIStatusAuthenticationErrorIsLoginExpired() async {
        let result = await read([path: .fixture("minimax-token-plan-api-error")])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check MiniMax API key")))
    }

    func testAPIStatusErrorIsUnavailableWithServerMessage() async {
        let result = await read([path: .fixture("minimax-token-plan-api-unavailable")])

        XCTAssertEqual(result, .failure(.unavailable("system error")))
    }

    func testMalformedBodyIsUnexpectedResponse() async {
        let result = await read([path: .json("{")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testMissingModelRemainsIsMissingUsageData() async {
        let result = await read([path: .json(#"{"base_resp":{"status_code":0}}"#)])

        XCTAssertEqual(result, .failure(.unavailable("Missing usage data")))
    }
}
