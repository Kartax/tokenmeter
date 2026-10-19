import Foundation

/// Synthetic: an API key pasted in Settings, stored in TokenMeter's Keychain item.
struct SyntheticCredentials: Codable, Equatable, Sendable {
    var apiKey: String
}

/// Reads `GET /v2/quotas`. The response's known slots are mapped by their fields, not by position:
/// the rolling five-hour limit, the weekly token budget, and optionally a legacy monthly request
/// count plus an hourly search allowance.
/// See https://dev.synthetic.new/docs/synthetic/quotas
struct SyntheticProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.synthetic.new")!
    static let loginHint = "Check API key"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_SYNTHETIC_BASE_URL` override).
    static let live = SyntheticProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_SYNTHETIC_BASE_URL")
                                            ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<SyntheticCredentials>(missingHint: loginHint)

    var baseURL: URL = SyntheticProvider.defaultBaseURL

    func read(account: Account, credentials: SyntheticCredentials, session: URLSession, now: Date) async
        -> ProviderReading<SyntheticCredentials> {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/quotas"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let body = try? JSONDecoder().decode(QuotaResponse.self, from: data),
                          let quotas = Self.map(body) else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    return .success(Reading(accountID: account.id, takenAt: now, plan: nil, identity: nil,
                                            quotas: quotas, credits: []))
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

    // MARK: - Mapping

    /// The rolling window is the main Quota when usable, else the weekly budget, else the legacy
    /// subscription count. Search is always a non-main extra. Nil when the response carries none
    /// of the known quota shapes.
    static func map(_ body: QuotaResponse) -> [Quota]? {
        var quotas: [Quota] = []
        var mainIndex: Int?

        if let rolling = body.rollingFiveHourLimit,
           let max = rolling.max, max > 0, let remaining = rolling.remaining {
            let percent = rolling.limited == true ? 100 : (max - remaining) / max * 100
            mainIndex = quotas.count
            quotas.append(Quota(
                window: Window(identity: .scoped("rolling_5h"), title: "5-hour limit", isMain: false,
                               resetsAt: HTTP.date(rolling.nextTickAt), length: 5 * 3600),
                percentUsed: percent))
        }

        if let weekly = body.weeklyTokenLimit, let percentRemaining = weekly.percentRemaining {
            if mainIndex == nil { mainIndex = quotas.count }
            quotas.append(Quota(
                window: Window(identity: .week, title: "Weekly budget", isMain: false,
                               resetsAt: HTTP.date(weekly.nextRegenAt), length: 7 * 24 * 3600),
                percentUsed: 100 - percentRemaining))
        }

        if let subscription = body.subscription,
           let limit = subscription.limit, limit > 0, let requests = subscription.requests {
            if mainIndex == nil { mainIndex = quotas.count }
            quotas.append(Quota(
                window: Window(identity: .month, title: "Subscription", isMain: false,
                               resetsAt: HTTP.date(subscription.renewsAt), length: nil),
                percentUsed: requests / limit * 100))
        }

        if let hourly = body.search?.hourly,
           let limit = hourly.limit, limit > 0, let requests = hourly.requests {
            quotas.append(Quota(
                window: Window(identity: .scoped("search"), title: "Search", isMain: false,
                               resetsAt: HTTP.date(hourly.renewsAt), length: 3600),
                percentUsed: requests / limit * 100))
        }

        guard let mainIndex else { return nil }
        quotas[mainIndex].window.isMain = true
        return quotas
    }

    struct QuotaResponse: Decodable {
        var rollingFiveHourLimit: RollingFiveHourLimit?
        var weeklyTokenLimit: WeeklyTokenLimit?
        var subscription: Subscription?
        var search: Search?

        struct RollingFiveHourLimit: Decodable {
            var remaining: Double?
            var max: Double?
            var nextTickAt: String?
            var limited: Bool?
        }

        struct WeeklyTokenLimit: Decodable {
            var percentRemaining: Double?
            var nextRegenAt: String?
        }

        struct Subscription: Decodable {
            var limit: Double?
            var requests: Double?
            var renewsAt: String?
        }

        struct Search: Decodable {
            var hourly: Hourly?
        }

        struct Hourly: Decodable {
            var limit: Double?
            var requests: Double?
            var renewsAt: String?
        }
    }
}
