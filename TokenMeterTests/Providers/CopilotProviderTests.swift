import XCTest
@testable import TokenMeter

/// Seam A: recorded `/copilot_internal/user` responses → Reading or ReadingFailure.
final class CopilotProviderTests: XCTestCase {
    private let account = Account(kind: .copilot, label: "Personal")
    private let credentials = CopilotCredentials(token: "gho_test-token")
    private let now = date("2026-10-18T12:00:00Z")

    private func read(_ routes: [String: HTTPStub.Response]) async
        -> ProviderReading<CopilotCredentials> {
        await CopilotProvider().read(account: account, credentials: credentials,
                                     session: HTTPStub.session(routes), now: now)
    }

    private func reading(_ fixture: String) async throws -> Reading {
        try await read(["GET /copilot_internal/user": .fixture(fixture)]).outcome.get()
    }

    // MARK: - Mapping

    func testPaidPlanMapsTheMonthlyCreditBalance() async throws {
        let reading = try await reading("copilot-usage-paid")

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Pro")
        XCTAssertEqual(reading.identity, "octocat")
        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "credits", title: "Credits", remaining: Decimal(string: "1234.5")!,
                          allowance: 1500, currency: CreditBalance.creditsUnit,
                          renewsAt: date("2026-11-01T00:00:00Z"), isMain: true),
        ])
        XCTAssertEqual(reading.credits.first?.percentUsed ?? -1, 17.7, accuracy: 0.001)

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token gho_test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2025-04-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Version"), "vscode/1.96.2")
    }

    func testFreePlanMapsChatAndCompletionQuotas() async throws {
        let reading = try await reading("copilot-usage-free")

        XCTAssertEqual(reading.plan, "Free")
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .scoped("chat"), title: "Chat", isMain: true,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
                  percentUsed: 9),
            Quota(window: Window(identity: .scoped("completions"), title: "Completions", isMain: true,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
                  percentUsed: 0.5),
        ])
    }

    func testOrgManagedSeatShowsThePersonalCreditsUsed() async throws {
        let reading = try await reading("copilot-usage-org-credits")

        XCTAssertEqual(reading.plan, "Business")
        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "credits_used", title: "Credits used", remaining: 2111,
                          allowance: nil, currency: CreditBalance.creditsUnit,
                          renewsAt: date("2026-11-01T00:00:00Z"), isMain: true),
        ])
        XCTAssertNil(reading.credits.first?.percentUsed)
    }

    func testOrgManagedSeatWithoutPersonalCreditsStillShowsThePlan() async throws {
        let reading = try await reading("copilot-usage-org")

        XCTAssertEqual(reading.plan, "Business")
        XCTAssertEqual(reading.identity, "octocat")
        XCTAssertEqual(reading.quotas, [])
        XCTAssertEqual(reading.credits, [])
    }

    func testLegacyFreeLimitsMapToQuotas() async throws {
        let reading = try await reading("copilot-usage-legacy-free")

        XCTAssertEqual(reading.plan, "Free")
        XCTAssertEqual(reading.quotas, [
            Quota(window: Window(identity: .scoped("chat"), title: "Chat", isMain: true,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
                  percentUsed: 75),
            Quota(window: Window(identity: .scoped("completions"), title: "Completions", isMain: true,
                                 resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
                  percentUsed: 25),
        ])
    }

    func testNumericStringsAreAccepted() async throws {
        let reading = try await read(["GET /copilot_internal/user": .json("""
            {"login":"octocat","copilot_plan":"pro","quota_snapshots":{"premium_interactions":
              {"entitlement":"300","remaining":"240","percent_remaining":"80"}}}
            """)]).outcome.get()

        XCTAssertEqual(reading.credits, [
            CreditBalance(id: "credits", title: "Credits", remaining: 240, allowance: 300,
                          currency: CreditBalance.creditsUnit, renewsAt: nil, isMain: true),
        ])
    }

    func testOverageAboveTheAllowanceClampsThePercentUsed() async throws {
        let reading = try await read(["GET /copilot_internal/user": .json("""
            {"copilot_plan":"pro","quota_snapshots":{"premium_interactions":
              {"entitlement":300,"remaining":-75,"percent_remaining":-15}}}
            """)]).outcome.get()

        XCTAssertEqual(reading.credits.first?.remaining, -75)
        XCTAssertEqual(reading.credits.first?.allowance, 300)
        XCTAssertEqual(reading.credits.first?.percentUsed ?? -1, 100, accuracy: 0.001)
    }

    // MARK: - Failures

    func testUnexpectedBodyIsUnavailable() async {
        let outcome = await read(["GET /copilot_internal/user": .json(#"{"copilot_plan":"pro"}"#)]).outcome

        XCTAssertEqual(outcome, .failure(.unavailable("Unexpected response")))
    }

    func testUnauthorizedIsLoginExpired() async {
        let outcome = await read(["GET /copilot_internal/user": .status(401)]).outcome

        XCTAssertEqual(outcome, .failure(.loginExpired(hint: "Sign in again")))
    }

    func testPrimaryRateLimitUsesTheResetHeader() async {
        let reset = Int(now.addingTimeInterval(120).timeIntervalSince1970)
        let outcome = await read([
            "GET /copilot_internal/user":
                .status(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"]),
        ]).outcome

        XCTAssertEqual(outcome, .failure(.rateLimited(retryAfter: 120)))
    }

    func testSecondaryRateLimitHonoursRetryAfter() async {
        let outcome = await read([
            "GET /copilot_internal/user": .status(403, headers: ["Retry-After": "45"]),
        ]).outcome

        XCTAssertEqual(outcome, .failure(.rateLimited(retryAfter: 45)))
    }

    func testTooManyRequestsHonoursRetryAfter() async {
        let outcome = await read([
            "GET /copilot_internal/user": .status(429, headers: ["Retry-After": "30"]),
        ]).outcome

        XCTAssertEqual(outcome, .failure(.rateLimited(retryAfter: 30)))
    }

    func testForbiddenForAnotherReasonIsLoginExpired() async {
        let outcome = await read([
            "GET /copilot_internal/user": .status(403, headers: ["X-RateLimit-Remaining": "42"]),
        ]).outcome

        XCTAssertEqual(outcome, .failure(.loginExpired(hint: "Sign in again")))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let outcome = await read(["GET /copilot_internal/user": .status(500)]).outcome

        XCTAssertEqual(outcome, .failure(.unavailable("Server returned 500")))
    }
}
