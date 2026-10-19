import XCTest
@testable import TokenMeter

/// Seam A: recorded `/user/balance` responses → Reading or ReadingFailure.
final class DeepSeekProviderTests: XCTestCase {
    private let account = Account(kind: .deepseek, label: "Personal")
    private let credentials = DeepSeekCredentials(apiKey: "test-api-key")
    private let now = date("2026-10-18T12:00:00Z")

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await DeepSeekProvider().read(account: account, credentials: credentials,
                                      session: HTTPStub.session(routes), now: now).outcome
    }

    func testUSDAndCNYBalancesMapWithFirstAsMain() async throws {
        let reading = try await read([
            "GET /user/balance": .fixture("deepseek-balance-usd-cny"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "usd", title: "USD balance", remaining: Decimal(string: "110.00")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: true),
            CreditBalance(id: "cny", title: "CNY balance", remaining: Decimal(string: "789.50")!,
                          allowance: nil, currency: "CNY", renewsAt: nil, isMain: false),
        ])
    }

    func testNumericAmountsStillParse() async throws {
        let reading = try await read([
            "GET /user/balance": .fixture("deepseek-balance-numbers"),
        ]).get()

        XCTAssertEqual(reading.credits.map(\.id), ["usd", "cny"])
        XCTAssertEqual(reading.credits.map(\.remaining), [Decimal(string: "42.5")!, Decimal(string: "7.25")!])
        XCTAssertEqual(reading.credits.map(\.isMain), [true, false])
    }

    func testMalformedEntriesAreSkippedAndFirstValidIsMain() async throws {
        let reading = try await read([
            "GET /user/balance": .fixture("deepseek-balance-malformed"),
        ]).get()

        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "cny", title: "CNY balance", remaining: 25,
                          allowance: nil, currency: "CNY", renewsAt: nil, isMain: true),
        ])
    }

    func testEmptyOrUnparseableBalancesAreUnexpectedResponse() async {
        for response: HTTPStub.Response in [
            .fixture("deepseek-balance-empty"),
            .json(#"{"is_available":true}"#),
            .json(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"n/a"}]}"#),
            .json(#"{"is_available":true,"balance_infos":"not an array"}"#),
        ] {
            let result = await read(["GET /user/balance": response])
            XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
        }
    }

    func testUnavailableBalanceStillMapsZero() async throws {
        let reading = try await read([
            "GET /user/balance": .fixture("deepseek-balance-unavailable"),
        ]).get()

        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "usd", title: "USD balance", remaining: 0,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: true),
        ])
    }

    func testRequestUsesBearerTokenAndDeepSeekHost() async throws {
        _ = try await read(["GET /user/balance": .fixture("deepseek-balance-usd-cny")]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.deepseek.com")
        XCTAssertEqual(request.url?.path, "/user/balance")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testUnauthorizedIsLoginExpired() async {
        let result = await read([
            "GET /user/balance": .fixture("deepseek-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            "GET /user/balance": .fixture("deepseek-unauthorized", status: 403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "GET /user/balance": .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["GET /user/balance": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }
}
