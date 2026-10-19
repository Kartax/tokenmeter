import XCTest
@testable import TokenMeter

/// Seam A: recorded Connect-RPC responses for `GetPlanInfo` and `GetCurrentPeriodUsage`.
final class CursorProviderTests: XCTestCase {
    private let account = Account(kind: .cursor, label: "Personal")
    private let credentials = CursorCredentials(accessToken: "test-access-token")
    private let now = date("2026-10-18T12:00:00Z")

    private let planRoute = "POST /aiserver.v1.DashboardService/GetPlanInfo"
    private let usageRoute = "POST /aiserver.v1.DashboardService/GetCurrentPeriodUsage"

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await CursorProvider().read(account: account, credentials: credentials,
                                    session: HTTPStub.session(routes), now: now).outcome
    }

    func testPlanAndUsageMapTheBillingCycleWithAutoAndAPIWindows() async throws {
        let reading = try await read([
            planRoute: .fixture("cursor-plan"),
            usageRoute: .fixture("cursor-usage"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Pro")
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])

        let reset = date("2026-11-01T00:00:00Z")
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .month, title: "Billing cycle", isMain: true,
                                 resetsAt: reset, length: 2_678_400), percentUsed: 37.5),
            Quota(window: Window(identity: .scoped("auto"), title: "Auto", isMain: false,
                                 resetsAt: reset, length: 2_678_400), percentUsed: 20),
            Quota(window: Window(identity: .scoped("api"), title: "API", isMain: false,
                                 resetsAt: reset, length: 2_678_400), percentUsed: 55),
        ])
        XCTAssertEqual(reading.quotas.map(\.window.isMain), [true, false, false])
        XCTAssertFalse(reading.quotas[0].limitReached)
    }

    func testRequestsUseConnectProtocolHeadersAndBearerToken() async throws {
        _ = try await read([
            planRoute: .fixture("cursor-plan"),
            usageRoute: .fixture("cursor-usage"),
        ]).get()

        XCTAssertEqual(HTTPStub.requests.count, 2)
        for (request, path) in zip(HTTPStub.requests, [planRoute, usageRoute]) {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api2.cursor.sh")
            XCTAssertEqual(request.url?.path, path.split(separator: " ").last.map { String($0) })
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            XCTAssertEqual(String(decoding: HTTPStub.body(of: request), as: UTF8.self), "{}")
        }
    }

    func testMissingTotalPercentUsedFallsBackToSpendOverLimit() async throws {
        let reading = try await read([
            planRoute: .fixture("cursor-plan"),
            usageRoute: .fixture("cursor-usage-spend"),
        ]).get()

        XCTAssertEqual(reading.quotas.first?.percentUsed ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(reading.quotas.first?.window.identity, .month)
        XCTAssertEqual(reading.quotas.map(\.window.identity), [.month, .scoped("auto"), .scoped("api")])
    }

    func testUnauthorizedPlanIsLoginExpired() async {
        let result = await read([planRoute: .fixture("cursor-unauthorized", status: 401)])
        XCTAssertEqual(result, .failure(.loginExpired(hint: CursorProvider.loginHint)))
    }

    func testForbiddenPlanIsLoginExpired() async {
        let result = await read([planRoute: .status(403)])
        XCTAssertEqual(result, .failure(.loginExpired(hint: CursorProvider.loginHint)))
    }

    func testRateLimitedUsageCarriesRetryAfter() async {
        let result = await read([
            planRoute: .fixture("cursor-plan"),
            usageRoute: .status(429, headers: ["Retry-After": "42"]),
        ])
        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailable() async {
        let result = await read([planRoute: .status(500)])
        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testUsageFailureAfterPlanDoesNotProduceAnEmptyReading() async {
        let result = await read([
            planRoute: .fixture("cursor-plan"),
            usageRoute: .status(500),
        ])
        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMalformedUsageIsUnavailable() async {
        for body in [#"{}"#, "not json"] {
            let result = await read([
                planRoute: .fixture("cursor-plan"),
                usageRoute: .json(body),
            ])
            XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
        }
    }

    func testMalformedPlanIsUnavailable() async {
        let result = await read([planRoute: .json(#"{}"#)])
        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testExpiredJWTIsRefreshedInMemory() async throws {
        let expired = jwt(expiringAt: now.addingTimeInterval(-60))
        let credentials = CursorCredentials(accessToken: expired, refreshToken: "test-refresh-token")
        let result = await CursorProvider().read(
            account: account, credentials: credentials,
            session: HTTPStub.session([
                "POST /oauth/token": .json(#"{"access_token":"refreshed-token","shouldLogout":false}"#),
                planRoute: .fixture("cursor-plan"),
                usageRoute: .fixture("cursor-usage"),
            ]), now: now).outcome
        _ = try result.get()

        XCTAssertEqual(HTTPStub.requests.first?.url?.path, "/oauth/token")
        let body = try XCTUnwrap(HTTPStub.requests.first.flatMap(HTTPStub.body(of:)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["client_id"] as? String, CursorProvider.clientID)
        XCTAssertEqual(object["refresh_token"] as? String, "test-refresh-token")
        let plan = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path.hasSuffix("GetPlanInfo") == true })
        XCTAssertEqual(plan.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
    }

    func testRefreshLogoutIsLoginExpired() async {
        let expired = jwt(expiringAt: now.addingTimeInterval(-60))
        let result = await CursorProvider().read(
            account: account,
            credentials: CursorCredentials(accessToken: expired, refreshToken: "test-refresh-token"),
            session: HTTPStub.session([
                "POST /oauth/token": .json(#"{"access_token":"","shouldLogout":true}"#),
            ]), now: now).outcome
        XCTAssertEqual(result, .failure(.loginExpired(hint: CursorProvider.loginHint)))
    }

    /// A minimal unsigned JWT whose only meaningful claim is `exp`.
    private func jwt(expiringAt date: Date) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": date.timeIntervalSince1970])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
