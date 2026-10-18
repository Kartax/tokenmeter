import XCTest
@testable import TokenMeter

/// An unsigned JWT with the given payload (TokenMeter only reads claims, never verifies).
func jwt(_ claims: [String: Any]) -> String {
    func encode(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(["alg": "none"])).\(encode(claims)).sig"
}

/// Seam A: recorded `wham/usage` and token-refresh responses → Reading or ReadingFailure.
final class CodexProviderTests: XCTestCase {
    private let account = Account(kind: .codex, label: "Personal")
    private let now = date("2026-10-18T12:00:00Z")

    private func accessToken(expiresIn seconds: TimeInterval, tag: String = "old") -> String {
        jwt(["exp": now.addingTimeInterval(seconds).timeIntervalSince1970, "tag": tag])
    }

    private var idToken: String {
        jwt(["email": "user@example.com",
             "https://api.openai.com/auth": ["chatgpt_account_id": "00000000-0000-0000-0000-000000000001",
                                             "chatgpt_plan_type": "pro"]])
    }

    private var credentials: CodexCredentials {
        CodexCredentials(accessToken: accessToken(expiresIn: 3600), refreshToken: "refresh-old", idToken: idToken)
    }

    private func read(_ routes: [String: [HTTPStub.Response]], credentials: CodexCredentials? = nil)
        async -> ProviderReading<CodexCredentials> {
        await CodexProvider().read(account: account, credentials: credentials ?? self.credentials,
                                   session: HTTPStub.session(sequences: routes), now: now)
    }

    private func reading(_ usage: HTTPStub.Response) async throws -> Reading {
        try await read(["GET /backend-api/wham/usage": [usage]]).outcome.get()
    }

    // MARK: - Mapping

    func testMainWindowsScopedWindowsAndCreditsFromAProPlan() async throws {
        let reading = try await reading(.fixture("codex-usage-pro"))

        let reset5h = Date(timeIntervalSince1970: 1766948068)
        let resetWeek = Date(timeIntervalSince1970: 1767407914)
        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Pro")
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .session, title: "Session", isMain: true, resetsAt: reset5h, length: 18000),
                  percentUsed: 22),
            Quota(window: Window(identity: .week, title: "Week", isMain: true, resetsAt: resetWeek, length: 604800),
                  percentUsed: 43),
            Quota(window: Window(identity: .scoped("gpt_5_3_codex_spark.session"), title: "GPT-5.3-Codex-Spark · Session",
                                 isMain: false, resetsAt: reset5h, length: 18000),
                  percentUsed: 30),
            Quota(window: Window(identity: .scoped("gpt_5_3_codex_spark.week"), title: "GPT-5.3-Codex-Spark · Week",
                                 isMain: false, resetsAt: resetWeek, length: 604800),
                  percentUsed: 100),
            Quota(window: Window(identity: .scoped("code_review.week"), title: "Code review · Week",
                                 isMain: false, resetsAt: resetWeek, length: 604800),
                  percentUsed: 5),
        ])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "credits", title: "Credits", remaining: Decimal(string: "14.5")!, allowance: nil,
                          currency: CreditBalance.creditsUnit, renewsAt: nil, isMain: false),
        ])
        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(credentials.accessToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testIdentityIsTheEmailFromTheIdToken() async throws {
        let reading = try await reading(.fixture("codex-usage-pro"))

        XCTAssertEqual(reading.identity, "user@example.com")
    }

    func testWeeklyOnlyLimitInThePrimarySlotIsTheWeekWindow() async throws {
        let reading = try await reading(.fixture("codex-usage-team"))

        XCTAssertEqual(reading.plan, "Team")
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .week, title: "Week", isMain: true,
                                 resetsAt: Date(timeIntervalSince1970: 1767407914), length: 604800),
                  percentUsed: 61),
        ])
        XCTAssertEqual(reading.credits, [])
    }

    func testUsageAbove100PercentIsClampedAndLimitReached() async throws {
        let reading = try await reading(.json("""
            {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":117,"limit_window_seconds":18000,"reset_at":1766948068}}}
            """))

        XCTAssertEqual(reading.quotas.map(\.percentUsed), [100])
        XCTAssertEqual(reading.quotas.map(\.limitReached), [true])
        XCTAssertEqual(reading.plan, "Plus")
    }

    func testKnownPlanIdsHaveDisplayNames() async throws {
        for (id, name) in [("prolite", "Pro 100"), ("promax", "Pro 500"), ("business", "Business"),
                           ("enterprise", "Enterprise")] {
            let reading = try await reading(.json(#"{"plan_type":"\#(id)","rate_limit":{}}"#))
            XCTAssertEqual(reading.plan, name, id)
        }
    }

    func testUnknownPlanTypeIsShownVerbatim() async throws {
        let reading = try await reading(.json(#"{"plan_type":"edu_plus","rate_limit":{}}"#))

        XCTAssertEqual(reading.plan, "edu_plus")
    }

    func testUnlimitedCreditsAreNotACreditBalance() async throws {
        let reading = try await reading(.json(#"{"credits":{"has_credits":true,"unlimited":true,"balance":"0"}}"#))

        XCTAssertEqual(reading.credits, [])
    }

    func testUnexpectedBodyIsUnavailable() async {
        let outcome = await read(["GET /backend-api/wham/usage": [.json("[1,2]")]]).outcome

        XCTAssertEqual(outcome, .failure(.unavailable("Unexpected response")))
    }

    func testRateLimitedHonoursRetryAfter() async {
        let outcome = await read(["GET /backend-api/wham/usage": [.status(429, headers: ["Retry-After": "120"])]]).outcome

        XCTAssertEqual(outcome, .failure(.rateLimited(retryAfter: 120)))
    }

    // MARK: - Refresh

    private var newAccessToken: String { accessToken(expiresIn: 864000, tag: "new") }

    private var refreshed: HTTPStub.Response {
        .json(#"{"access_token":"\#(newAccessToken)","refresh_token":"refresh-new","id_token":"\#(idToken)"}"#)
    }

    private func json(_ data: Data) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    func testAccessTokenNearExpiryIsRefreshedBeforeReading() async throws {
        let expiring = CodexCredentials(accessToken: accessToken(expiresIn: 60), refreshToken: "refresh-old",
                                        idToken: idToken)
        let result = await read(["POST /oauth/token": [refreshed],
                                 "GET /backend-api/wham/usage": [.fixture("codex-usage-pro")]],
                                credentials: expiring)

        XCTAssertEqual(try result.outcome.get().plan, "Pro")
        XCTAssertEqual(result.rotatedCredentials,
                       CodexCredentials(accessToken: newAccessToken, refreshToken: "refresh-new", idToken: idToken))
        let requests = HTTPStub.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/oauth/token", "/backend-api/wham/usage"])
        guard requests.count == 2 else { return }
        let refresh = json(HTTPStub.body(of: requests[0]))
        XCTAssertEqual(requests[0].url?.host, "auth.openai.com")
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(refresh["refresh_token"], "refresh-old")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(newAccessToken)")
    }

    func testUnauthorizedTriggersRefreshThenRetry() async throws {
        let result = await read(["GET /backend-api/wham/usage": [.status(401), .fixture("codex-usage-pro")],
                                 "POST /oauth/token": [refreshed]])

        XCTAssertEqual(try result.outcome.get().plan, "Pro")
        XCTAssertEqual(result.rotatedCredentials?.accessToken, newAccessToken)
        XCTAssertEqual(result.rotatedCredentials?.refreshToken, "refresh-new")
        XCTAssertEqual(HTTPStub.requests.map { $0.url?.path },
                       ["/backend-api/wham/usage", "/oauth/token", "/backend-api/wham/usage"])
        XCTAssertEqual(HTTPStub.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(newAccessToken)")
    }

    func testRotatedTokensArePersistedBeforeTheyAreUsed() async {
        let persisted = Recorder<(CodexCredentials, requestsSoFar: [String?])>()
        let session = HTTPStub.session(sequences: ["GET /backend-api/wham/usage": [.status(401), .fixture("codex-usage-pro")],
                                                   "POST /oauth/token": [refreshed]])

        _ = await CodexProvider().read(account: account, credentials: credentials, session: session, now: now) {
            persisted.append(($0, HTTPStub.requests.map { $0.url?.path }))
        }

        XCTAssertEqual(persisted.values.map(\.0.accessToken), [newAccessToken])
        XCTAssertEqual(persisted.values.first?.requestsSoFar, ["/backend-api/wham/usage", "/oauth/token"])
    }

    func testFailedRefreshIsLoginExpired() async {
        let result = await read(["GET /backend-api/wham/usage": [.status(401)],
                                 "POST /oauth/token": [.fixture("codex-refresh-reused", status: 400)]])

        XCTAssertEqual(result.outcome, .failure(.loginExpired(hint: "Sign in again")))
        XCTAssertNil(result.rotatedCredentials)
    }

    func testUnauthorizedAgainAfterRefreshIsLoginExpiredButKeepsRotatedTokens() async {
        let result = await read(["GET /backend-api/wham/usage": [.status(401)],
                                 "POST /oauth/token": [refreshed]])

        XCTAssertEqual(result.outcome, .failure(.loginExpired(hint: "Sign in again")))
        XCTAssertEqual(result.rotatedCredentials?.refreshToken, "refresh-new")
        XCTAssertEqual(HTTPStub.requests.count, 3)
    }

    func testRefreshResponseWithoutRefreshTokenKeepsTheOldOne() async {
        let result = await read(["GET /backend-api/wham/usage": [.status(401), .fixture("codex-usage-pro")],
                                 "POST /oauth/token": [.json(#"{"access_token":"\#(newAccessToken)"}"#)]])

        XCTAssertEqual(result.rotatedCredentials,
                       CodexCredentials(accessToken: newAccessToken, refreshToken: "refresh-old", idToken: idToken))
    }

    func testServerErrorWhileRefreshingAStillValidTokenReadsWithIt() async throws {
        let expiring = CodexCredentials(accessToken: accessToken(expiresIn: 60), refreshToken: "refresh-old",
                                        idToken: idToken)
        let result = await read(["POST /oauth/token": [.status(503)],
                                 "GET /backend-api/wham/usage": [.fixture("codex-usage-pro")]],
                                credentials: expiring)

        XCTAssertEqual(try result.outcome.get().plan, "Pro")
        XCTAssertNil(result.rotatedCredentials)
    }

    func testServerErrorWhileRefreshingAnExpiredTokenIsUnavailable() async {
        let expired = CodexCredentials(accessToken: accessToken(expiresIn: -60), refreshToken: "refresh-old",
                                       idToken: idToken)
        let result = await read(["POST /oauth/token": [.status(503)]], credentials: expired)

        XCTAssertEqual(result.outcome, .failure(.unavailable("Server returned 503")))
    }
}

/// Thread-safe list of values recorded from `@Sendable` callbacks.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}
