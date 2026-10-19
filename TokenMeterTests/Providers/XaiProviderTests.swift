import XCTest
@testable import TokenMeter

/// Seam A: xAI Management API billing responses → Reading or ReadingFailure.
final class XaiProviderTests: XCTestCase {
    private let account = Account(kind: .xai, label: "Team")
    private let credentials = XaiCredentials(apiKey: "test-management-key", teamID: "team-test-1234")
    private let now = date("2026-10-18T12:00:00Z")

    private let prepaidPath = "/v1/billing/teams/team-test-1234/prepaid/balance"
    private let previewPath = "/v1/billing/teams/team-test-1234/postpaid/invoice/preview"

    private func read(_ routes: [String: HTTPStub.Response]) async -> Result<Reading, ReadingFailure> {
        await XaiProvider().read(account: account, credentials: credentials,
                                 session: HTTPStub.session(routes), now: now).outcome
    }

    func testPrepaidBalanceMapsToMainCreditBalance() async throws {
        let reading = try await read(["GET \(prepaidPath)": .fixture("xai-prepaid-balance")]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "prepaid", title: "Prepaid credits", remaining: Decimal(string: "12.34")!,
                          allowance: nil, currency: "USD", renewsAt: nil, isMain: true),
        ])
    }

    func testPrepaidBalanceInvertsTheLedgerSign() async throws {
        let reading = try await read([
            "GET \(prepaidPath)": .json(#"{"total":{"val":"250"},"changes":[]}"#),
        ]).get()

        let prepaid = try XCTUnwrap(reading.credits.first)
        XCTAssertEqual(prepaid.remaining, Decimal(string: "-2.5"))
        XCTAssertTrue(prepaid.isMain)
    }

    func testPostpaidPreviewAddsRemainingBalance() async throws {
        let reading = try await read([
            "GET \(prepaidPath)": .fixture("xai-prepaid-balance"),
            "GET \(previewPath)": .fixture("xai-postpaid-preview"),
        ]).get()

        XCTAssertEqual(reading.credits.map(\.id), ["prepaid", "postpaid"])
        XCTAssertEqual(reading.credits.map(\.isMain), [true, false])
        XCTAssertEqual(reading.credits[1], CreditBalance(
            id: "postpaid", title: "Postpaid remaining", remaining: Decimal(string: "65.44")!,
            allowance: 100, currency: "USD", renewsAt: nil, isMain: false))
    }

    func testPreviewWithoutLimitDoesNotFabricateABalance() async throws {
        let reading = try await read([
            "GET \(prepaidPath)": .fixture("xai-prepaid-balance"),
            "GET \(previewPath)": .fixture("xai-postpaid-preview-missing-limit"),
        ]).get()

        XCTAssertEqual(reading.credits.map(\.id), ["prepaid"])
    }

    func testPreviewFailureDoesNotFailThePrepaidReading() async throws {
        let reading = try await read([
            "GET \(prepaidPath)": .fixture("xai-prepaid-balance"),
            "GET \(previewPath)": .status(500),
        ]).get()

        XCTAssertEqual(reading.credits.map(\.id), ["prepaid"])
    }

    func testRequestUsesBearerManagementKeyAndTeamPath() async throws {
        _ = try await read([
            "GET \(prepaidPath)": .fixture("xai-prepaid-balance"),
            "GET \(previewPath)": .fixture("xai-postpaid-preview"),
        ]).get()

        XCTAssertEqual(HTTPStub.requests.count, 2)
        let first = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(first.url?.host, "management-api.x.ai")
        XCTAssertEqual(first.url?.path, prepaidPath)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer test-management-key")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(HTTPStub.requests.last?.url?.path, previewPath)
        XCTAssertTrue(HTTPStub.requests.last?.url?.path.contains(credentials.teamID) == true)
    }

    func testMissingTotalIsUnavailableInsteadOfZero() async {
        let result = await read(["GET \(prepaidPath)": .fixture("xai-prepaid-missing-total")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testMalformedTotalIsUnavailableInsteadOfZero() async {
        let result = await read(["GET \(prepaidPath)": .fixture("xai-prepaid-malformed-total")])

        XCTAssertEqual(result, .failure(.unavailable("Unexpected response")))
    }

    func testEmptyTeamIDFailsWithoutRequests() async {
        let result = await XaiProvider().read(
            account: account, credentials: XaiCredentials(apiKey: "test-management-key", teamID: "  "),
            session: HTTPStub.session([:]), now: now).outcome

        XCTAssertEqual(result, .failure(.unavailable("Team ID not found — check the xAI team ID")))
        XCTAssertEqual(HTTPStub.requests, [])
    }

    func testUnauthorizedManagementKeyIsLoginExpired() async {
        let result = await read([
            "GET \(prepaidPath)": .fixture("xai-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Use a Management API key")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            "GET \(prepaidPath)": .fixture("xai-unauthorized", status: 403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Use a Management API key")))
    }

    func testNotFoundPointsToTheTeamID() async {
        let result = await read([
            "GET \(prepaidPath)": .fixture("xai-team-not-found", status: 404),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Team ID not found — check the xAI team ID")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "GET \(prepaidPath)": .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["GET \(prepaidPath)": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }
}
