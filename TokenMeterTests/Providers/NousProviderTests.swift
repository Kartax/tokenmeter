import XCTest
@testable import TokenMeter

/// Seam A: recorded `/api/oauth/account` and token responses → Reading or ReadingFailure.
final class NousProviderTests: XCTestCase {
    private let account = Account(kind: .nous, label: "Personal")
    private let now = date("2026-10-18T12:00:00Z")

    private func credentials(expiresIn seconds: TimeInterval = 3600, refreshToken: String = "refresh-old") -> NousCredentials {
        NousCredentials(accessToken: jwt(["exp": now.addingTimeInterval(seconds).timeIntervalSince1970]),
                        refreshToken: refreshToken)
    }

    private var defaultCredentials: NousCredentials { credentials() }

    private func read(_ routes: [String: [HTTPStub.Response]], credentials: NousCredentials? = nil,
                      persist: @escaping (NousCredentials) -> Void = { _ in })
        async -> ProviderReading<NousCredentials> {
        await NousProvider().read(account: account, credentials: credentials ?? defaultCredentials,
                                  session: HTTPStub.session(sequences: routes), now: now, persist: persist)
    }

    private func reading(_ accountResponse: HTTPStub.Response, credentials: NousCredentials? = nil) async throws -> Reading {
        try await read(["GET /api/oauth/account": [accountResponse]], credentials: credentials).outcome.get()
    }

    // MARK: - Mapping

    func testNumericMoneyWithPurchasedCreditsPlanAndIdentity() async throws {
        let reading = try await reading(.fixture("nous-account"))

        XCTAssertEqual(reading.plan, "Ultra")
        XCTAssertEqual(reading.identity, "user@example.com")
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "monthly", title: "Monthly credits", remaining: Decimal(string: "55")!,
                          allowance: 220, currency: "USD",
                          renewsAt: HTTP.date("2026-11-12T04:29:00.000Z"), isMain: true),
            CreditBalance(id: "purchased", title: "Purchased credits", remaining: Decimal(string: "19.25")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
        ])
        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://portal.nousresearch.com/api/oauth/account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.credentials().accessToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testIdentityFallsBackToTheOrganisationName() async throws {
        let reading = try await reading(.json("""
            {"organisation":{"name":"Example account"},
             "subscription":{"monthly_credits":220,"credits_remaining":55},
             "purchased_credits_remaining":0}
            """))

        XCTAssertEqual(reading.identity, "Example account")
        XCTAssertEqual(reading.plan, nil)
    }

    func testMoneyAsDecimalStrings() async throws {
        let reading = try await reading(.fixture("nous-account-strings"))

        XCTAssertEqual(reading.plan, "Starter")
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "monthly", title: "Monthly credits", remaining: Decimal(string: "4.50")!,
                          allowance: 22, currency: "USD",
                          renewsAt: HTTP.date("2026-11-12T04:29:00.000Z"), isMain: true),
            CreditBalance(id: "purchased", title: "Purchased credits", remaining: Decimal(string: "3.25")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
        ])
    }

    func testPurchasedCreditsFallBackToPaidServiceAccess() async throws {
        let reading = try await reading(.json("""
            {"paid_service_access":{"purchased_credits_remaining":7.5},
             "subscription":{"monthly_credits":220,"credits_remaining":55}}
            """))

        XCTAssertEqual(reading.credits.last?.remaining, Decimal(string: "7.5")!)
    }

    func testMissingCreditsRemainingIsNotZero() async throws {
        let reading = try await reading(.fixture("nous-account-missing"))

        // The purchased amount is absent from the response: no "purchased" balance at all, not a
        // zero one; the monthly balance is mapped when its remaining amount is present.
        XCTAssertEqual(reading.credits.map(\.id), ["monthly"])
        XCTAssertFalse(reading.credits.contains { $0.id == "purchased" })
    }

    func testRolloverKeepsTheBalanceButNoPercent() async throws {
        let reading = try await reading(.fixture("nous-account-rollover"))

        let monthly = try XCTUnwrap(reading.credits.first)
        XCTAssertEqual(monthly.remaining, Decimal(string: "240")!)
        XCTAssertEqual(monthly.allowance, 220)
        XCTAssertEqual(monthly.id, "monthly")
        XCTAssertTrue(monthly.isMain)
        // A rolled-over balance carries no threshold signal: the Reading has no Quotas, and
        // CreditBalance has no percent at all — the percent would be negative.
        XCTAssertTrue(reading.quotas.isEmpty)
        XCTAssertGreaterThan(monthly.remaining, monthly.allowance!)
    }

    func testFreeAccountWithoutSubscriptionGetsNoMainBalance() async throws {
        let reading = try await reading(.json(#"{"subscription":null,"purchased_credits_remaining":0}"#))

        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "purchased", title: "Purchased credits", remaining: Decimal(0),
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
        ])
    }

    func testUnexpectedBodyIsUnavailable() async {
        let outcome = await read(["GET /api/oauth/account": [.json("[]")]]).outcome

        XCTAssertEqual(outcome, .failure(.unavailable("Unexpected response")))
    }

    func testRateLimitedHonoursRetryAfter() async {
        let outcome = await read(["GET /api/oauth/account":
            [.status(429, headers: ["Retry-After": "42"])]]).outcome

        XCTAssertEqual(outcome, .failure(.rateLimited(retryAfter: 42)))
    }

    // MARK: - Refresh

    private var newToken: String { jwt(["exp": now.addingTimeInterval(3600).timeIntervalSince1970, "tag": "new"]) }

    private var refreshed: HTTPStub.Response {
        .json(#"{"access_token":"\#(newToken)","refresh_token":"refresh-new","expires_in":3600,"token_type":"Bearer"}"#)
    }

    private func form(_ data: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testExpiringAccessTokenIsRefreshedAndRotatedTokensPersistedBeforeUse() async throws {
        let persisted = Recorder<NousCredentials>()
        let expiring = credentials(expiresIn: 60)
        let result = await read(["POST /api/oauth/token": [refreshed],
                                 "GET /api/oauth/account": [.fixture("nous-account")]],
                                credentials: expiring, persist: { persisted.append($0) })

        XCTAssertEqual(try result.outcome.get().plan, "Ultra")
        XCTAssertEqual(result.rotatedCredentials,
                       NousCredentials(accessToken: newToken, refreshToken: "refresh-new"))
        XCTAssertEqual(persisted.values, [NousCredentials(accessToken: newToken, refreshToken: "refresh-new")],
                       "The rotated pair reaches persist before anything else")
        let requests = HTTPStub.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/oauth/token", "/api/oauth/account"])
        let refresh = requests[0]
        XCTAssertEqual(form(HTTPStub.body(of: refresh)), [
            "grant_type": "refresh_token",
            "client_id": "hermes-cli",
        ])
        XCTAssertEqual(refresh.value(forHTTPHeaderField: "x-nous-refresh-token"), "refresh-old")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(newToken)")
    }

    func testRefreshWithoutRotationKeepsTheOldRefreshToken() async throws {
        let result = await read(["POST /api/oauth/token": [.json(#"{"access_token":"\#(newToken)"}"#)],
                                 "GET /api/oauth/account": [.fixture("nous-account")]],
                                credentials: credentials(expiresIn: 60))

        XCTAssertEqual(result.rotatedCredentials?.refreshToken, "refresh-old")
    }

    func testReusedRefreshTokenIsLoginExpired() async {
        let result = await read(["GET /api/oauth/account": [.status(401)],
                                 "POST /api/oauth/token": [.fixture("nous-refresh-reused", status: 400)]])

        XCTAssertEqual(result.outcome, .failure(.loginExpired(hint: "Sign in again")))
        XCTAssertNil(result.rotatedCredentials)
    }

    func testDeadGrantCodeNearExpiryIsLoginExpiredWithoutARequest() async {
        let result = await read(["POST /api/oauth/token": [.fixture("nous-refresh-reused", status: 400)]],
                                credentials: credentials(expiresIn: 60))

        XCTAssertEqual(result.outcome, .failure(.loginExpired(hint: "Sign in again")))
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }

    func testServerErrorWhileRefreshingAStillValidTokenReadsWithIt() async throws {
        let result = await read(["POST /api/oauth/token": [.status(503)],
                                 "GET /api/oauth/account": [.fixture("nous-account")]],
                                credentials: credentials(expiresIn: 60))

        XCTAssertEqual(try result.outcome.get().plan, "Ultra")
        XCTAssertNil(result.rotatedCredentials)
    }

    func testServerErrorWhileRefreshingAnExpiredTokenIsUnavailable() async {
        let result = await read(["POST /api/oauth/token": [.status(503)]],
                                credentials: credentials(expiresIn: -60))

        XCTAssertEqual(result.outcome, .failure(.unavailable("Server returned 503")))
    }

    func test401TriggersRefreshThenRetry() async throws {
        let result = await read(["GET /api/oauth/account": [.status(401), .fixture("nous-account")],
                                 "POST /api/oauth/token": [refreshed]])

        XCTAssertEqual(try result.outcome.get().plan, "Ultra")
        XCTAssertEqual(result.rotatedCredentials?.refreshToken, "refresh-new")
        XCTAssertEqual(HTTPStub.requests.map { $0.url?.path },
                       ["/api/oauth/account", "/api/oauth/token", "/api/oauth/account"])
    }
}