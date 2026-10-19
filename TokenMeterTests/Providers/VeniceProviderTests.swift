import XCTest
@testable import TokenMeter

/// Seam A: recorded `/billing/balance` responses → Reading or ReadingFailure.
final class VeniceProviderTests: XCTestCase {
    private let account = Account(kind: .venice, label: "Personal")
    private let credentials = VeniceCredentials(apiKey: "test-api-key")
    private let now = date("2026-10-18T12:00:00Z")

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await VeniceProvider().read(account: account, credentials: credentials,
                                    session: HTTPStub.session(routes), now: now).outcome
    }

    func testDIEMEpochIsTheMainQuotaAndOtherBalancesAreCredits() async throws {
        let reading = try await read(["GET /api/v1/billing/balance": .fixture("venice-balance-diem")]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.quotas.count, 1)
        let quota = try XCTUnwrap(reading.quotas.first)
        XCTAssertEqual(quota.window, Window(identity: .scoped("diem_epoch"), title: "Daily DIEM",
                                            isMain: true, resetsAt: date("2026-10-19T00:00:00Z"),
                                            length: 86400))
        XCTAssertEqual(quota.percentUsed, 9.5, accuracy: 0.001)
        XCTAssertFalse(quota.limitReached)
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "bundled", title: "Bundled credits", remaining: 10,
                          allowance: nil, currency: CreditBalance.creditsUnit,
                          renewsAt: nil, isMain: false),
            CreditBalance(id: "earned", title: "Earned credits", remaining: 5,
                          allowance: nil, currency: CreditBalance.creditsUnit,
                          renewsAt: nil, isMain: false),
            CreditBalance(id: "usd", title: "USD credits", remaining: 25,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: false),
        ])
    }

    func testRequestUsesBearerTokenAndVeniceHost() async throws {
        _ = try await read(["GET /api/v1/billing/balance": .fixture("venice-balance-diem")]).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.host, "api.venice.ai")
        XCTAssertEqual(request.url?.path, "/api/v1/billing/balance")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testExhaustedDIEMIsLimitReachedAndUSDFallbackIsAlsoMain() async throws {
        let reading = try await read(["GET /api/v1/billing/balance": .fixture("venice-balance-diem-spent")]).get()

        XCTAssertEqual(reading.quotas.map(\.percentUsed), [100])
        XCTAssertEqual(reading.quotas.map(\.limitReached), [true])
        XCTAssertEqual(reading.credits.map(\.isMain), [false, false, true])
        XCTAssertEqual(reading.credits.last?.remaining, Decimal(string: "12.5"))
    }

    func testUSDBalanceIsMainWithoutDIEM() async throws {
        let reading = try await read(["GET /api/v1/billing/balance": .fixture("venice-balance-usd")]).get()

        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "usd", title: "USD credits", remaining: 25,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: true),
        ])
    }

    func testActiveBundledCreditsAreMain() async throws {
        let reading = try await read(["GET /api/v1/billing/balance": .fixture("venice-balance-bundled")]).get()

        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits.map(\.id), ["bundled", "earned", "usd"])
        XCTAssertEqual(reading.credits.map(\.isMain), [true, false, false])
        XCTAssertEqual(reading.credits.first?.currency, CreditBalance.creditsUnit)
    }

    func testUnauthorizedIsLoginExpiredWithCheckApiKey() async {
        let result = await read([
            "GET /api/v1/billing/balance": .fixture("venice-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            "GET /api/v1/billing/balance": .fixture("venice-unauthorized", status: 403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Check API key")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "GET /api/v1/billing/balance": .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["GET /api/v1/billing/balance": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMissingBalancesIsUnexpectedResponse() async {
        for body in [#"{}"#, #"{"balances":"not an object"}"#] {
            let result = await read(["GET /api/v1/billing/balance": .json(body)])
            XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
        }
    }

    func testDIEMWithoutAllocationIsNotAQuota() async throws {
        let reading = try await read([
            "GET /api/v1/billing/balance": .json("""
                {"consumptionCurrency":"USD","diemEpochAllocation":0,
                 "balances":{"diem":5,"usd":1,"bundledCredits":null,"earnedCredits":null}}
                """),
        ]).get()

        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits.map(\.id), ["usd"])
        XCTAssertEqual(reading.credits.first?.isMain, true)
    }
}
