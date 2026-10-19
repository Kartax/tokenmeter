import Foundation

/// Alibaba Cloud Model Studio (Bailian) region. The Coding Plan console lives on a different
/// host and uses different commodity codes and region ids per deployment.
enum AlibabaRegion: String, Codable, CaseIterable, Sendable {
    case intl
    case cn

    var displayName: String {
        switch self {
        case .intl: "International"
        case .cn: "China mainland"
        }
    }

    var baseURL: URL {
        switch self {
        case .intl: URL(string: "https://modelstudio.console.alibabacloud.com")!
        case .cn: URL(string: "https://bailian.console.aliyun.com")!
        }
    }

    var currentRegionID: String {
        switch self {
        case .intl: "ap-southeast-1"
        case .cn: "cn-beijing"
        }
    }

    var commodityCode: String {
        switch self {
        case .intl: "sfm_codingplan_public_intl"
        case .cn: "sfm_codingplan_public_cn"
        }
    }

    /// The Coding Plan dashboard, used as the request's `Referer`.
    var dashboardURL: URL {
        switch self {
        case .intl:
            URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan")!
        case .cn:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!
        }
    }
}

/// A Coding Plan API key (`sk-sp-…`) and the console region it belongs to, stored in
/// TokenMeter's Keychain item.
struct AlibabaCredentials: Codable, Equatable, Sendable {
    var apiKey: String
    var region: AlibabaRegion

    init(apiKey: String, region: AlibabaRegion = .intl) {
        self.apiKey = apiKey
        self.region = region
    }

    private enum CodingKeys: String, CodingKey {
        case apiKey, region
    }

    /// Missing or unknown regions fall back to International so older items keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        region = (try? c.decodeIfPresent(AlibabaRegion.self, forKey: .region)) ?? .intl
    }
}

/// Alibaba Cloud Model Studio Coding Plan quotas: `POST /data/api.json` with the
/// `queryCodingPlanInstanceInfoV2` action. The response carries a 5-hour, weekly and monthly
/// allowance in `codingPlanQuotaInfo`; instances may appear under `codingPlanInstanceInfos`.
struct AlibabaProvider: Provider {
    static let defaultBaseURL = URL(string: "https://modelstudio.console.alibabacloud.com")!
    static let loginHint = "Use a Coding Plan API key (sk-sp-...)"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_ALIBABA_BASE_URL` override).
    /// `nil` means "use the selected region's console host".
    static let live = AlibabaProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_ALIBABA_BASE_URL"))
    static let credentialSource = KeychainCredentialSource<AlibabaCredentials>(missingHint: loginHint)

    /// Overrides both console hosts, e.g. for a local smoke-run stub.
    var baseURL: URL?

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    func read(account: Account, credentials: AlibabaCredentials, session: URLSession, now: Date) async
        -> ProviderReading<AlibabaCredentials> {
        let result: Result<Reading, ReadingFailure> = await HTTP.send(Self.request(credentials: credentials, baseURL: baseURL),
                                                                      session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    return Self.map(data, account: account, now: now)
                case 401, 403:
                    return .failure(.loginExpired(hint: Self.loginHint))
                case 429:
                    return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
                default:
                    return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
                }
            }
        return ProviderReading(result)
    }

    // MARK: - Request

    static func request(credentials: AlibabaCredentials, baseURL: URL?) -> URLRequest {
        let region = credentials.region
        let host = baseURL ?? region.baseURL
        var components = URLComponents(url: host, resolvingAgainstBaseURL: false)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action",
                         value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: region.currentRegionID),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(QueryRequest(
            queryCodingPlanInstanceInfoRequest: QueryRequest.Query(commodityCode: region.commodityCode)))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-DashScope-API-Key")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin(of: host), forHTTPHeaderField: "Origin")
        request.setValue(region.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        return request
    }

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private static func origin(of url: URL) -> String {
        let string = url.absoluteString
        return string.hasSuffix("/") ? String(string.dropLast()) : string
    }

    private struct QueryRequest: Encodable {
        var queryCodingPlanInstanceInfoRequest: Query

        struct Query: Encodable {
            var commodityCode: String
        }
    }

    // MARK: - Mapping

    private enum WindowKeys {
        static let fiveHourUsed = ["per5HourUsedQuota", "perFiveHourUsedQuota"]
        static let fiveHourTotal = ["per5HourTotalQuota", "perFiveHourTotalQuota"]
        static let fiveHourRefresh = ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"]
        static let weekUsed = ["perWeekUsedQuota"]
        static let weekTotal = ["perWeekTotalQuota"]
        static let weekRefresh = ["perWeekQuotaNextRefreshTime"]
        static let monthUsed = ["perBillMonthUsedQuota", "perMonthUsedQuota"]
        static let monthTotal = ["perBillMonthTotalQuota", "perMonthTotalQuota"]
        static let monthRefresh = ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"]
    }

    /// Parses `data`/`successResponse`-wrapped or root-level payloads into Quotas. Nil counters
    /// never become 0%: a payload with an active plan but no quota info fails instead.
    static func map(_ data: Data, account: Account, now: Date) -> Result<Reading, ReadingFailure> {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unavailable("Unexpected response"))
        }
        return map(payload, account: account, now: now)
    }

    static func map(_ payload: [String: Any], account: Account, now: Date) -> Result<Reading, ReadingFailure> {
        let instances = (findArray(forKeys: ["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: payload) ?? [])
            .compactMap { $0 as? [String: Any] }
        let instance = selectInstance(instances, now: now)

        guard let quotaInfo = instance.flatMap({ findQuotaInfo(in: $0) }) ?? findQuotaInfo(in: payload) else {
            return .failure(.unavailable("Coding Plan quota data not returned"))
        }

        var quotas: [Quota] = []
        if let quota = makeQuota(identity: .session, title: "5-hour", length: 5 * 60 * 60,
                                 used: WindowKeys.fiveHourUsed, total: WindowKeys.fiveHourTotal,
                                 refresh: WindowKeys.fiveHourRefresh, in: quotaInfo) {
            quotas.append(quota)
        }
        if let quota = makeQuota(identity: .week, title: "Weekly", length: 7 * 24 * 60 * 60,
                                 used: WindowKeys.weekUsed, total: WindowKeys.weekTotal,
                                 refresh: WindowKeys.weekRefresh, in: quotaInfo) {
            quotas.append(quota)
        }
        if let quota = makeQuota(identity: .month, title: "Monthly", length: nil,
                                 used: WindowKeys.monthUsed, total: WindowKeys.monthTotal,
                                 refresh: WindowKeys.monthRefresh, in: quotaInfo) {
            quotas.append(quota)
        }

        guard !quotas.isEmpty else {
            return .failure(.unavailable("Coding Plan quota data not returned"))
        }

        // The first window is the one to show in the popover: 5-hour, else weekly, else monthly.
        quotas[0].window.isMain = true

        let plan = instance.flatMap { planName(in: $0) } ?? planName(in: payload)
        return .success(Reading(accountID: account.id, takenAt: now, plan: plan, identity: nil,
                                quotas: quotas, credits: []))
    }

    private static func makeQuota(identity: WindowIdentity, title: String, length: TimeInterval?,
                                  used usedKeys: [String], total totalKeys: [String],
                                  refresh refreshKeys: [String], in info: [String: Any]) -> Quota? {
        guard let total = number(forKeys: totalKeys, in: info), total > 0,
              let used = number(forKeys: usedKeys, in: info) else { return nil }
        let window = Window(identity: identity, title: title, isMain: false,
                            resetsAt: date(forKeys: refreshKeys, in: info), length: length)
        return Quota(window: window, percentUsed: used / total * 100)
    }

    private static func planName(in info: [String: Any]) -> String? {
        for key in ["planName", "plan_name", "instanceName", "instance_name", "packageName", "package_name"] {
            if let value = info[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Prefer the instance with usable counters, then one the API marks active; else the first.
    private static func selectInstance(_ instances: [[String: Any]], now: Date) -> [String: Any]? {
        if let withQuota = instances.first(where: { findQuotaInfo(in: $0) != nil }) {
            return withQuota
        }
        if let active = instances.first(where: { isActive($0, now: now) }) {
            return active
        }
        return instances.first
    }

    private static func isActive(_ info: [String: Any], now: Date) -> Bool {
        if let status = info["status"] as? String ?? info["instanceStatus"] as? String {
            if ["VALID", "ACTIVE"].contains(status.uppercased()) { return true }
        }
        if let active = info["isActive"] as? Bool { return active }
        for key in ["endTime", "periodEndTime", "expireTime", "expirationTime"] {
            if let expiry = flexibleDate(info[key]), expiry > now { return true }
        }
        return false
    }

    // MARK: - Loose JSON lookup

    /// Counter keys that identify a quota object when `codingPlanQuotaInfo` is absent.
    private static let quotaMarkerKeys: Set<String> = [
        "per5HourUsedQuota", "per5HourTotalQuota", "perFiveHourUsedQuota", "perFiveHourTotalQuota",
        "perWeekUsedQuota", "perWeekTotalQuota", "perBillMonthUsedQuota", "perBillMonthTotalQuota",
        "perMonthUsedQuota", "perMonthTotalQuota",
    ]

    private static func findQuotaInfo(in value: Any) -> [String: Any]? {
        findDictionary(forKeys: ["codingPlanQuotaInfo", "coding_plan_quota_info"], in: value)
            ?? findObject(containingAnyKeyIn: quotaMarkerKeys, in: value)
    }

    private static func findArray(forKeys keys: [String], in value: Any) -> [Any]? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let found = dictionary[key] as? [Any] { return found }
            }
            for key in dictionary.keys.sorted() {
                if let found = findArray(forKeys: keys, in: dictionary[key]!) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = findArray(forKeys: keys, in: item) { return found }
            }
        }
        return nil
    }

    private static func findDictionary(forKeys keys: [String], in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let found = dictionary[key] as? [String: Any] { return found }
            }
            for key in dictionary.keys.sorted() {
                if let found = findDictionary(forKeys: keys, in: dictionary[key]!) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = findDictionary(forKeys: keys, in: item) { return found }
            }
        }
        return nil
    }

    private static func findObject(containingAnyKeyIn keys: Set<String>, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if !keys.isDisjoint(with: dictionary.keys) { return dictionary }
            for key in dictionary.keys.sorted() {
                if let found = findObject(containingAnyKeyIn: keys, in: dictionary[key]!) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = findObject(containingAnyKeyIn: keys, in: item) { return found }
            }
        }
        return nil
    }

    // MARK: - Flexible values

    private static func number(forKeys keys: [String], in dictionary: [String: Any]) -> Double? {
        for key in keys {
            if let value = flexibleNumber(dictionary[key]) { return value }
        }
        return nil
    }

    private static func flexibleNumber(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        }
        if let string = raw as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func date(forKeys keys: [String], in dictionary: [String: Any]) -> Date? {
        for key in keys {
            if let value = flexibleDate(dictionary[key]) { return value }
        }
        return nil
    }

    /// Epoch seconds, epoch milliseconds or an ISO 8601 string.
    static func flexibleDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return date(epoch: number.doubleValue)
        }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let epoch = Double(trimmed) { return date(epoch: epoch) }
            return HTTP.date(trimmed)
        }
        return nil
    }

    private static func date(epoch: Double) -> Date? {
        guard epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch > 1_000_000_000_000 ? epoch / 1000 : epoch)
    }
}
