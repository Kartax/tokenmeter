import XCTest
@testable import TokenMeter

/// Seam A: recorded `/api/balance` and `/api/me` responses → Reading or ReadingFailure.
final class OllamaProviderTests: XCTestCase {
    private let account = Account(kind: .ollama, label: "Personal")
    private let credentials = OllamaCredentials(apiKey: "test-api-key")
    private let now = date("2026-10-18T12:00:00Z")

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await OllamaProvider().read(account: account, credentials: credentials,
                                    session: HTTPStub.session(routes), now: now).outcome
    }

    func testAllowancePlanIsTheMainCreditBalance() async throws {
        let reading = try await read([
            "GET /api/balance": .fixture("ollama-balance-allowance"),
            "POST /api/me": .fixture("ollama-me"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "included", title: "Monthly credits", remaining: Decimal(string: "41.2")!,
                          allowance: 60, currency: "USD", renewsAt: date("2026-11-03T09:30:00Z"), isMain: true),
        ])
        let balanceRequest = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == "/api/balance" })
        XCTAssertEqual(balanceRequest.url?.host, "ollama.com")
        XCTAssertEqual(balanceRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
    }

    func testPlanAndIdentityComeFromApiMe() async throws {
        let reading = try await read([
            "GET /api/balance": .fixture("ollama-balance-allowance"),
            "POST /api/me": .fixture("ollama-me"),
        ]).get()

        XCTAssertEqual(reading.plan, "Pro")
        XCTAssertEqual(reading.identity, "user@example.com")
        let meRequest = try XCTUnwrap(HTTPStub.requests.first { $0.url?.path == "/api/me" })
        XCTAssertEqual(meRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
    }

    func testLegacyPlanHasMainSessionAndWeekQuotas() async throws {
        let reading = try await read([
            "GET /api/balance": .fixture("ollama-balance-legacy"),
            "POST /api/me": .fixture("ollama-me"),
        ]).get()

        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .session, title: "Session", isMain: true,
                                 resetsAt: date("2026-10-18T19:00:00Z"), length: 18000),
                  percentUsed: 25),
            Quota(window: Window(identity: .week, title: "Week", isMain: true,
                                 resetsAt: date("2026-10-20T00:00:00Z"), length: 604800),
                  percentUsed: 60),
        ])
    }

    func testLegacyQuotaWithNothingRemainingIsLimitReached() async throws {
        let reading = try await read([
            "GET /api/balance": .json(#"{"included":{"session":{"remaining_percent":0,"resets_at":"2026-10-18T19:00:00Z"}}}"#),
        ]).get()

        XCTAssertEqual(reading.quotas.map(\.percentUsed), [100])
        XCTAssertEqual(reading.quotas.map(\.limitReached), [true])
    }

    func testPurchasedCreditsAreANonMainCreditBalance() async throws {
        let reading = try await read([
            "GET /api/balance": .fixture("ollama-balance-purchased"),
            "POST /api/me": .fixture("ollama-me"),
        ]).get()

        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "included", title: "Monthly credits", remaining: Decimal(string: "72.5")!,
                          allowance: 100, currency: "USD", renewsAt: date("2026-10-15T09:30:00Z"), isMain: true),
            CreditBalance(id: "purchased", title: "Purchased credits", remaining: 25,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
        ])
    }

    func testUnauthorizedIsLoginExpiredWithCheckApiKey() async {
        let result = await read([
            "GET /api/balance": .fixture("ollama-unauthorized", status: 401),
            "POST /api/me": .fixture("ollama-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "GET /api/balance": .status(429, headers: ["Retry-After": "42"]),
            "POST /api/me": .fixture("ollama-me"),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testFailingApiMeDoesNotFailTheReading() async throws {
        let reading = try await read([
            "GET /api/balance": .fixture("ollama-balance-allowance"),
            "POST /api/me": .status(500),
        ]).get()

        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits.map(\.remaining), [Decimal(string: "41.2")!])
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read([
            "GET /api/balance": .status(500),
            "POST /api/me": .status(500),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testUnknownBalanceShapeIsUnavailable() async {
        let result = await read([
            "GET /api/balance": .json(#"{"included":{"something_new":1}}"#),
            "POST /api/me": .fixture("ollama-me"),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }
}

func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}
