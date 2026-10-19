import XCTest
@testable import TokenMeter

/// Seam A: recorded `/zen/go/v1/usage` responses → Reading or ReadingFailure.
final class OpenCodeProviderTests: XCTestCase {
    private let account = Account(kind: .opencode, label: "Personal")
    private let credentials = OpenCodeCredentials(apiKey: "test-api-key")
    private let now = date("2026-10-18T12:00:00Z")

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await OpenCodeProvider().read(account: account, credentials: credentials,
                                      session: HTTPStub.session(routes), now: now).outcome
    }

    func testRollingWeeklyAndMonthlyMapToTheirWindows() async throws {
        let reading = try await read(["GET /zen/go/v1/usage": .fixture("opencode-usage-ok")]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .scoped("rolling_5h"), title: "Session", isMain: true,
                                 resetsAt: date("2026-10-18T16:59:00Z"), length: 18000),
                  percentUsed: 42.5),
            Quota(window: Window(identity: .week, title: "Weekly", isMain: false,
                                 resetsAt: date("2026-10-23T00:00:00Z"), length: 604800),
                  percentUsed: 61.25),
            Quota(window: Window(identity: .month, title: "Monthly", isMain: false,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: 2592000),
                  percentUsed: 12),
        ])
        XCTAssertEqual(reading.quotas.map(\.limitReached), [false, false, false])
    }

    func testRequestUsesBearerTokenAndUsagePath() async throws {
        _ = try await read(["GET /zen/go/v1/usage": .fixture("opencode-usage-ok")]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "opencode.ai")
        XCTAssertEqual(request.url?.path, "/zen/go/v1/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testPercentIsClampedToBounds() async throws {
        let reading = try await read(["GET /zen/go/v1/usage": .fixture("opencode-usage-clamped")]).get()

        XCTAssertEqual(reading.quotas.map(\.percentUsed), [100, 0, 100])
        XCTAssertEqual(reading.quotas.map(\.limitReached), [true, false, true])
    }

    func testRateLimitedStatusMeansFullyUsed() async throws {
        let reading = try await read(["GET /zen/go/v1/usage": .fixture("opencode-usage-rate-limited")]).get()

        XCTAssertEqual(reading.quotas.map(\.percentUsed), [100, 30, 100])
        XCTAssertEqual(reading.quotas.map(\.limitReached), [true, false, true])
        XCTAssertEqual(reading.quotas.first?.window.identity, .scoped("rolling_5h"))
    }

    func testOnlyReportedWindowsBecomeQuotas() async throws {
        let reading = try await read([
            "GET /zen/go/v1/usage": .json("""
                {"usage":{"rolling":{"status":"ok","percent":5,"resetsAt":null},"monthly":null}}
                """),
        ]).get()

        XCTAssertEqual(reading.quotas.map(\.window.identity), [.scoped("rolling_5h")])
        XCTAssertNil(reading.quotas.first?.window.resetsAt)
        XCTAssertEqual(reading.quotas.first?.window.length, 18000)
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([
            "GET /zen/go/v1/usage": .json(#"{"error":{"message":"Unauthorized"}}"#, status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testForbiddenEntitlementErrorExplainsMissingSubscription() async {
        let result = await read([
            "GET /zen/go/v1/usage": .fixture("opencode-entitlement", status: 403),
        ])

        XCTAssertEqual(result, .failure(.unavailable("No OpenCode Go subscription on this key")))
    }

    func testGenericForbiddenIsLoginExpired() async {
        let result = await read([
            "GET /zen/go/v1/usage": .json(#"{"error":{"type":"ForbiddenError","message":"Forbidden"}}"#,
                                          status: 403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "GET /zen/go/v1/usage": .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["GET /zen/go/v1/usage": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMissingOrMalformedUsageIsUnexpectedResponse() async {
        for body in [#"{}"#, #"{"usage":null}"#, #"{"usage":{"rolling":{"percent":"lots"}}}"#,
                     #"{"usage":[]}"#] {
            let result = await read(["GET /zen/go/v1/usage": .json(body)])
            XCTAssertEqual(result, .failure(.unavailable("Unexpected response")), body)
        }
    }
}
