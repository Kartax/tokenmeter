import Foundation

/// Z.ai GLM Coding Plan: an API key pasted in Settings, stored in TokenMeter's Keychain item.
struct ZaiCredentials: Codable, Equatable, Sendable {
    var apiKey: String
}

/// Reads `GET /api/monitor/usage/quota/limit` (required) and `GET /api/biz/subscription/list`
/// (Plan name and renewal, best effort). Limit entries are identified by their `type` and
/// `unit`/`number`, never by their position in `data.limits`:
/// - `TOKENS_LIMIT` `unit: 3, number: 5` → the 5-hour Session Window (main).
/// - `TOKENS_LIMIT` `unit: 6, number: 7` → the Weekly Window.
/// - `TIME_LIMIT` → the monthly web-search/reader call quota.
struct ZaiProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.z.ai")!
    static let loginHint = "Check API key"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_ZAI_BASE_URL` override).
    static let live = ZaiProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_ZAI_BASE_URL")
                                      ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<ZaiCredentials>(missingHint: loginHint)

    var baseURL: URL = ZaiProvider.defaultBaseURL

    func read(account: Account, credentials: ZaiCredentials, session: URLSession, now: Date) async
        -> ProviderReading<ZaiCredentials> {
        async let subscription = fetchSubscription(credentials, session: session)
        let quota = await fetchQuota(credentials, session: session, now: now)
        let info = await subscription
        let result: Result<Reading, ReadingFailure> = quota.map { limits in
            Reading(accountID: account.id, takenAt: now, plan: info?.plan, identity: nil,
                    quotas: Self.map(limits, webResetsAt: info?.renewsAt, now: now), credits: [])
        }
        return ProviderReading(result)
    }

    // MARK: - /api/monitor/usage/quota/limit

    private func fetchQuota(_ credentials: ZaiCredentials, session: URLSession, now: Date) async
        -> Result<[Limit], ReadingFailure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/monitor/usage/quota/limit"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
                    return .failure(.unavailable("Unexpected response"))
                }
                // z.ai answers HTTP 200 with `code`/`success` describing a rejected request.
                if body.success == false || (body.code != nil && body.code != 200) {
                    let message = body.msg?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let message, !message.isEmpty { return .failure(.unavailable(message)) }
                    if let code = body.code { return .failure(.unavailable("Server returned code \(code)")) }
                    return .failure(.unavailable("Unexpected response"))
                }
                guard let limits = body.data?.limits else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return .success(limits)
            case 401, 403:
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    // MARK: - Mapping

    /// Session first, Weekly second, then the web-search quota. The Session is main whenever it
    /// is present; the web-search quota becomes main only when neither token Window exists.
    static func map(_ limits: [Limit], webResetsAt: Date?, now: Date) -> [Quota] {
        var session: Quota?
        var weekly: Quota?
        var web: Quota?

        for limit in limits {
            switch limit.type {
            case "TOKENS_LIMIT":
                guard let percent = percentUsed(limit) else { continue }
                switch (limit.unit, limit.number) {
                case (3, 5):
                    if session == nil {
                        let window = Window(identity: .session, title: "Session", isMain: true,
                                            resetsAt: date(epochMilliseconds: limit.nextResetTime),
                                            length: 5 * 3600)
                        session = Quota(window: window, percentUsed: percent)
                    }
                case (6, 7):
                    if weekly == nil {
                        let window = Window(identity: .week, title: "Weekly", isMain: false,
                                            resetsAt: date(epochMilliseconds: limit.nextResetTime),
                                            length: 7 * 86400)
                        weekly = Quota(window: window, percentUsed: percent)
                    }
                default:
                    continue
                }
            case "TIME_LIMIT":
                guard web == nil, let percent = percentUsed(limit) else { continue }
                let window = Window(identity: .scoped("web_search"), title: "Web searches", isMain: false,
                                    resetsAt: webResetsAt ?? nextMonthStart(now), length: nil)
                web = Quota(window: window, percentUsed: percent)
            default:
                continue
            }
        }

        if var web, session == nil, weekly == nil {
            web.window.isMain = true
            return [web]
        }
        return [session, weekly, web].compactMap { $0 }
    }

    /// Percent used: `percentage` when reported, else `currentValue / usage`, else
    /// `(usage - remaining) / usage`. Nil when none of the fields can produce a percentage.
    static func percentUsed(_ limit: Limit) -> Double? {
        if let percentage = limit.percentage { return percentage }
        guard let usage = limit.usage, usage > 0 else { return nil }
        if let current = limit.currentValue { return Double(current) / Double(usage) * 100 }
        if let remaining = limit.remaining { return Double(usage - remaining) / Double(usage) * 100 }
        return nil
    }

    private static func date(epochMilliseconds: Int64?) -> Date? {
        guard let milliseconds = epochMilliseconds else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// The next 00:00 UTC, when the monthly web-search quota renews.
    private static func nextMonthStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1))!
        return calendar.date(byAdding: .month, value: 1, to: start)!
    }

    // MARK: - /api/biz/subscription/list

    private struct SubscriptionInfo {
        var plan: String?
        var renewsAt: Date?
    }

    /// The first active product's name and renewal; any failure yields nil and never fails the
    /// Reading. Web-search resets use the renewal when the quota response carries no reset.
    private func fetchSubscription(_ credentials: ZaiCredentials, session: URLSession) async -> SubscriptionInfo? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/biz/subscription/list"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard case .success(let (data, response)) = await HTTP.send(request, session: session),
              (200..<300).contains(response.statusCode),
              let body = try? JSONDecoder().decode(SubscriptionResponse.self, from: data),
              let products = body.data else {
            coreLog.info("Z.ai subscription list unavailable; Reading continues without Plan")
            return nil
        }

        func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
        func isActive(_ product: Subscription) -> Bool {
            if let active = product.active { return active }
            guard let status = trimmed(product.status)?.uppercased() else { return true }
            return status == "VALID" || status == "ACTIVE"
        }

        guard let product = products.first(where: { isActive($0) && trimmed($0.productName) != nil }) else {
            return nil
        }
        return SubscriptionInfo(plan: trimmed(product.productName),
                                renewsAt: Self.date(epochMilliseconds: product.nextRenewTime?.value))
    }

    private struct SubscriptionResponse: Decodable {
        var data: [Subscription]?
    }

    private struct Subscription: Decodable {
        var productName: String?
        var status: String?
        var active: Bool?
        var nextRenewTime: EpochMilliseconds?
    }

    /// A renewal date that may be epoch milliseconds or a `yyyy-MM-dd`/ISO date string; a
    /// malformed value costs the reset, not the whole subscription list.
    private struct EpochMilliseconds: Decodable {
        var value: Int64?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                value = number
                return
            }
            guard let string = try? container.decode(String.self) else {
                value = nil
                return
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let milliseconds = Int64(trimmed) {
                value = milliseconds
                return
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: trimmed) {
                value = Int64(date.timeIntervalSince1970 * 1000)
                return
            }
            value = HTTP.date(trimmed).map { Int64($0.timeIntervalSince1970 * 1000) }
        }
    }

    // MARK: - Response shapes

    private struct QuotaResponse: Decodable {
        var code: Int?
        var success: Bool?
        var msg: String?
        var data: QuotaData?
    }

    private struct QuotaData: Decodable {
        var limits: [Limit]?
    }

    struct Limit: Decodable {
        var type: String
        var unit: Int?
        var number: Int?
        var usage: Int?
        var currentValue: Int?
        var remaining: Int?
        var percentage: Double?
        /// Epoch milliseconds.
        var nextResetTime: Int64?
    }
}
