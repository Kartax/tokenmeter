import XCTest
@testable import TokenMeter

/// Seam A: recorded Coding Plan responses → Reading or ReadingFailure.
final class AlibabaProviderTests: XCTestCase {
    private let account = Account(kind: .alibaba, label: "Coding Plan")
    private let now = date("2026-10-18T12:00:00Z")
    private let testBaseURL = URL(string: "https://alibaba.test")!

    private func read(_ routes: [String: HTTPStub.Response],
                      credentials: AlibabaCredentials = AlibabaCredentials(apiKey: "test-api-key"),
                      provider: AlibabaProvider? = nil) async -> Result<Reading, ReadingFailure> {
        await (provider ?? AlibabaProvider(baseURL: testBaseURL))
            .read(account: account, credentials: credentials, session: HTTPStub.session(routes), now: now)
            .outcome
    }

    func testInternationalResponseMapsFiveHourWeeklyAndMonthlyWindows() async throws {
        let reading = try await read([
            "POST /data/api.json": .fixture("alibaba-coding-plan-intl"),
        ]).get()

        XCTAssertEqual(reading.accountID, account.id)
        XCTAssertEqual(reading.takenAt, now)
        XCTAssertEqual(reading.plan, "Coding Plan Pro")
        XCTAssertNil(reading.identity)
        XCTAssertEqual(reading.credits, [])
        XCTAssertEqual(reading.quotas.map(\.window), [
            Window(identity: .session, title: "5-hour", isMain: true,
                   resetsAt: date("2026-10-18T17:00:00Z"), length: 5 * 60 * 60),
            Window(identity: .week, title: "Weekly", isMain: false,
                   resetsAt: date("2026-10-25T00:00:00Z"), length: 7 * 24 * 60 * 60),
            Window(identity: .month, title: "Monthly", isMain: false,
                   resetsAt: date("2026-11-01T00:00:00Z"), length: nil),
        ])
        XCTAssertEqual(reading.quotas.map(\.percentUsed), [12.5, 25, 12.5])
        XCTAssertEqual(reading.quotas.map(\.limitReached), [false, false, false])
    }

    func testInternationalRequestUsesModelStudioHostAndCodingPlanHeaders() async throws {
        _ = try await read(["POST /data/api.json": .fixture("alibaba-coding-plan-intl")],
                           provider: AlibabaProvider()).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "modelstudio.console.alibabacloud.com")
        XCTAssertEqual(request.url?.path, "/data/api.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-API-Key"), "test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://modelstudio.console.alibabacloud.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"),
                       "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))

        let items = try queryItems(of: request)
        XCTAssertEqual(items["action"], "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2")
        XCTAssertEqual(items["product"], "broadscope-bailian")
        XCTAssertEqual(items["api"], "queryCodingPlanInstanceInfoV2")
        XCTAssertEqual(items["currentRegionId"], "ap-southeast-1")
        XCTAssertEqual(try commodityCode(of: request), "sfm_codingplan_public_intl")
    }

    func testChinaMainlandRequestUsesBailianHostAndCNCommodityCode() async throws {
        _ = try await read(["POST /data/api.json": .fixture("alibaba-coding-plan-intl")],
                           credentials: AlibabaCredentials(apiKey: "test-api-key", region: .cn),
                           provider: AlibabaProvider()).get()

        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.host, "bailian.console.aliyun.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://bailian.console.aliyun.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"),
                       "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")
        let items = try queryItems(of: request)
        XCTAssertEqual(items["currentRegionId"], "cn-beijing")
        XCTAssertEqual(try commodityCode(of: request), "sfm_codingplan_public_cn")
    }

    func testNumericStringCountersAndEpochTimestampsStillMap() async throws {
        let reading = try await read([
            "POST /data/api.json": .fixture("alibaba-coding-plan-strings"),
        ]).get()

        XCTAssertEqual(reading.plan, "Coding Plan Lite")
        XCTAssertEqual(reading.quotas.map(\.window.identity), [.session, .week, .month])
        XCTAssertEqual(reading.quotas.map(\.percentUsed), [25, 0, 5])
        XCTAssertEqual(reading.quotas[0].window.resetsAt, Date(timeIntervalSince1970: 1_760_806_800))
        XCTAssertEqual(reading.quotas[1].window.resetsAt, Date(timeIntervalSince1970: 1_761_411_600))
        XCTAssertEqual(reading.quotas[2].window.resetsAt, date("2026-11-01T00:00:00Z"))
    }

    func testRootQuotaInfoWithoutInstancesMaps() async throws {
        let reading = try await read([
            "POST /data/api.json": .json("""
                {"codingPlanQuotaInfo":{"per5HourUsedQuota":50,"per5HourTotalQuota":100}}
                """),
        ]).get()

        XCTAssertNil(reading.plan)
        XCTAssertEqual(reading.quotas.count, 1)
        XCTAssertEqual(reading.quotas[0].window.identity, .session)
        XCTAssertTrue(reading.quotas[0].window.isMain)
        XCTAssertEqual(reading.quotas[0].percentUsed, 50)
        XCTAssertNil(reading.quotas[0].window.resetsAt)
    }

    func testActivePlanWithoutCountersIsUnavailableInsteadOfZeroPercent() async {
        let result = await read([
            "POST /data/api.json": .fixture("alibaba-coding-plan-no-quota"),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Coding Plan quota data not returned")))
    }

    func testZeroTotalsDoNotProduceWindows() async {
        let result = await read([
            "POST /data/api.json": .json("""
                {"codingPlanQuotaInfo":{"per5HourUsedQuota":0,"per5HourTotalQuota":0,
                 "perWeekUsedQuota":0,"perWeekTotalQuota":0,
                 "perBillMonthUsedQuota":0,"perBillMonthTotalQuota":0}}
                """),
        ])

        XCTAssertEqual(result, .failure(.unavailable("Coding Plan quota data not returned")))
    }

    func testUnauthorizedPointsToACodingPlanKey() async {
        let result = await read([
            "POST /data/api.json": .fixture("alibaba-unauthorized", status: 401),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Use a Coding Plan API key (sk-sp-...)")))
    }

    func testForbiddenIsLoginExpired() async {
        let result = await read([
            "POST /data/api.json": .fixture("alibaba-unauthorized", status: 403),
        ])

        XCTAssertEqual(result, .failure(.loginExpired(hint: "Use a Coding Plan API key (sk-sp-...)")))
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfter() async {
        let result = await read([
            "POST /data/api.json": .status(429, headers: ["Retry-After": "42"]),
        ])

        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 42)))
    }

    func testServerErrorIsUnavailableWithStatus() async {
        let result = await read(["POST /data/api.json": .status(500)])

        XCTAssertEqual(result, .failure(.unavailable("Server returned 500")))
    }

    func testMalformedOrEmptyResponsesAreUnavailable() async {
        let malformed = await read(["POST /data/api.json": .json("not json")])
        XCTAssertEqual(malformed, .failure(.unavailable("Unexpected response")))

        let array = await read(["POST /data/api.json": .json("[]")])
        XCTAssertEqual(array, .failure(.unavailable("Unexpected response")))

        for body in ["{}", #"{"data":[]}"#] {
            let result = await read(["POST /data/api.json": .json(body)])
            XCTAssertEqual(result, .failure(.unavailable("Coding Plan quota data not returned")))
        }
    }

    // MARK: - Helpers

    private func queryItems(of request: URLRequest) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func commodityCode(of request: URLRequest) throws -> String? {
        let body = HTTPStub.body(of: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = object["queryCodingPlanInstanceInfoRequest"] as? [String: Any]
        return query?["commodityCode"] as? String
    }
}
