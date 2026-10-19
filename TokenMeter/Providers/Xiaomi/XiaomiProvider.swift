import Foundation

/// Xiaomi MiMo: cookies copied from a signed-in platform.xiaomimimo.com browser session,
/// stored in TokenMeter's Keychain item. The console has no API-key usage endpoint.
struct XiaomiCredentials: Codable, Equatable, Sendable {
    /// The full `Cookie` request header, e.g. `api-platform_serviceToken=…; userId=…`.
    var cookie: String
}

/// Reads `GET /balance` (required) plus `GET /tokenPlan/detail` and `GET /tokenPlan/usage`
/// (best effort) from the MiMo platform console.
///
/// The console authenticates with browser cookies; `api-platform_serviceToken` and `userId`
/// are required, and a missing one fails before any request. Responses carry a body `code`
/// in addition to the HTTP status.
struct XiaomiProvider: Provider {
    static let defaultBaseURL = URL(string: "https://platform.xiaomimimo.com/api/v1")!
    static let loginHint = "Paste fresh cookies from platform.xiaomimimo.com"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_XIAOMI_BASE_URL` override).
    static let live = XiaomiProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_XIAOMI_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<XiaomiCredentials>(missingHint: loginHint)

    static let requiredCookieNames = ["api-platform_serviceToken", "userId"]

    var baseURL: URL = XiaomiProvider.defaultBaseURL

    func read(account: Account, credentials: XiaomiCredentials, session: URLSession, now: Date) async
        -> ProviderReading<XiaomiCredentials> {
        let cookie = Self.normalizedCookie(credentials.cookie)
        guard Self.hasRequiredCookies(cookie) else {
            return ProviderReading(.failure(.loginExpired(hint: Self.loginHint)))
        }

        async let plan = fetchTokenPlan("tokenPlan/detail", as: TokenPlanDetail.self,
                                        cookie: cookie, session: session)
        async let usage = fetchTokenPlan("tokenPlan/usage", as: MonthUsagePayload.self,
                                         cookie: cookie, session: session)
        let balance = await fetchBalance(cookie: cookie, session: session, now: now)
        let (planDetail, monthUsage) = await (plan, usage)

        let result = balance.map { credits in
            var quotas: [Quota] = []
            if let monthUsage,
               let quota = Self.quota(monthUsage.monthUsage, resetsAt: planDetail?.periodEnd) {
                quotas.append(quota)
            }
            return Reading(accountID: account.id, takenAt: now, plan: planDetail?.plan, identity: nil,
                           quotas: quotas, credits: credits)
        }
        return ProviderReading(result)
    }

    // MARK: - Requests

    /// Trims a pasted value and drops an optional leading `Cookie:` label.
    static func normalizedCookie(_ raw: String) -> String {
        var cookie = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookie.lowercased().hasPrefix("cookie:") {
            cookie = String(cookie.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cookie
    }

    /// True when both required cookie names carry a non-empty value.
    static func hasRequiredCookies(_ cookie: String) -> Bool {
        var values: [String: String] = [:]
        for pair in cookie.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { values[name] = value }
        }
        return Self.requiredCookieNames.allSatisfy { name in
            values[name].map { !$0.isEmpty } ?? false
        }
    }

    private func request(_ path: String, cookie: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue("UTC+01:00", forHTTPHeaderField: "x-timeZone")
        return request
    }

    // MARK: - /balance

    private func fetchBalance(cookie: String, session: URLSession, now: Date) async
        -> Result<[CreditBalance], ReadingFailure> {
        await HTTP.send(request("balance", cookie: cookie), session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let envelope = try? JSONDecoder().decode(Envelope<BalancePayload>.self, from: data) else {
                    return .failure(.unavailable("Unexpected response"))
                }
                switch envelope.code {
                case 0:
                    guard let payload = envelope.data,
                          let balance = Self.money(payload.balance),
                          let currency = Self.nonEmpty(payload.currency) else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    var credits = [CreditBalance(id: "balance", title: "Balance", remaining: balance,
                                                 allowance: nil, currency: currency, renewsAt: nil,
                                                 isMain: true)]
                    if let cash = payload.cashBalance.flatMap(Self.money) {
                        credits.append(CreditBalance(id: "cash", title: "Cash balance", remaining: cash,
                                                     allowance: nil, currency: currency, renewsAt: nil,
                                                     isMain: false))
                    }
                    if let gift = payload.giftBalance.flatMap(Self.money) {
                        credits.append(CreditBalance(id: "gift", title: "Gift balance", remaining: gift,
                                                     allowance: nil, currency: currency, renewsAt: nil,
                                                     isMain: false))
                    }
                    return .success(credits)
                case 401, 403:
                    return .failure(.loginExpired(hint: Self.loginHint))
                default:
                    return .failure(.unavailable(Self.message(envelope.message)))
                }
            case 401, 403:
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    // MARK: - Token plan (best effort)

    /// Detail or usage payload; any transport, status or `code` failure yields nil.
    private func fetchTokenPlan<Payload: Decodable>(_ path: String, as type: Payload.Type,
                                                    cookie: String, session: URLSession) async -> Payload? {
        guard case .success(let (data, response)) = await HTTP.send(request(path, cookie: cookie),
                                                                    session: session),
              (200..<300).contains(response.statusCode),
              let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: data),
              envelope.code == 0 else { return nil }
        return envelope.data
    }

    /// The main monthly Quota from `monthUsage`: the first item with a limit, else the month's
    /// own percentage. Title follows the item; the reset time comes from the plan detail.
    static func quota(_ month: MonthUsage?, resetsAt: Date?) -> Quota? {
        guard let month else { return nil }
        let window = Window(identity: .month, title: "Token plan", isMain: true, resetsAt: resetsAt, length: nil)
        if let item = month.items?.first(where: { ($0.limit ?? 0) > 0 }) {
            let computed: Double? = {
                guard let used = item.used, let limit = item.limit, limit > 0 else { return nil }
                return used / limit * 100
            }()
            let percent = item.percent ?? computed ?? month.percent
            guard let percent else { return nil }
            let title = nonEmpty(item.name) ?? "Token plan"
            return Quota(window: Window(identity: .month, title: title, isMain: true,
                                        resetsAt: resetsAt, length: nil), percentUsed: percent)
        }
        guard let percent = month.percent else { return nil }
        return Quota(window: window, percentUsed: percent)
    }

    static func plan(_ detail: TokenPlanDetail?) -> String? {
        guard let detail else { return nil }
        return nonEmpty(detail.planName) ?? nonEmpty(detail.planCode)
    }

    /// `yyyy-MM-dd HH:mm:ss` in UTC, as the console reports it.
    static func planDate(_ string: String?) -> Date? {
        guard let string = nonEmpty(string) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }

    private static func money(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The server's body message, which is user-facing and never a credential.
    private static func message(_ body: String?) -> String {
        nonEmpty(body) ?? "Unexpected response"
    }

    // MARK: - Response bodies

    private struct Envelope<Payload: Decodable>: Decodable {
        var code: Int
        var message: String?
        var data: Payload?
    }

    private struct BalancePayload: Decodable {
        var balance: String
        var currency: String
        var cashBalance: String?
        var giftBalance: String?
    }

    struct TokenPlanDetail: Decodable {
        var planCode: String?
        var planName: String?
        var currentPeriodEnd: String?

        var plan: String? { XiaomiProvider.plan(self) }
        var periodEnd: Date? { XiaomiProvider.planDate(currentPeriodEnd) }
    }

    struct MonthUsagePayload: Decodable {
        var monthUsage: MonthUsage?
    }

    struct MonthUsage: Decodable {
        var percent: Double?
        var items: [Item]?

        struct Item: Decodable {
            var name: String?
            var used: Double?
            var limit: Double?
            var percent: Double?
        }
    }
}
