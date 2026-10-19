import Foundation

/// Mistral: an Organization **Admin** API key pasted in Settings, stored in TokenMeter's
/// Keychain item. Admin keys require an Enterprise plan and are created at backoffice.mistral.ai;
/// standard inference keys are rejected by the Admin API.
struct MistralCredentials: Codable, Equatable, Sendable {
    var adminKey: String
}

/// Reads `GET /v1/admin/spend-limit` with an Admin API key.
///
/// The response carries the Organization's monthly completion spend limit and usage. When a
/// positive limit exists it becomes a main "Monthly spend" quota; `monthly_limit_reached`
/// reports it as exhausted even if the reported usage has not caught up yet.
struct MistralProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.mistral.ai")!
    static let loginHint = "Use a Mistral Admin API key (Enterprise)"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_MISTRAL_BASE_URL` override).
    static let live = MistralProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_MISTRAL_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<MistralCredentials>(missingHint: loginHint)

    var baseURL: URL = MistralProvider.defaultBaseURL

    func read(account: Account, credentials: MistralCredentials, session: URLSession, now: Date) async
        -> ProviderReading<MistralCredentials> {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/admin/spend-limit"))
        request.setValue(credentials.adminKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let body = try? JSONDecoder().decode(SpendLimitResponse.self, from: data),
                          let completion = body.limits?.completion else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    guard let quota = Self.quota(for: completion, now: now) else {
                        return .failure(.unavailable("No monthly spend limit is configured"))
                    }
                    return .success(Reading(accountID: account.id, takenAt: now, plan: nil, identity: nil,
                                            quotas: [quota], credits: []))
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

    /// The main monthly quota, or nil when the Organization has no monthly spend limit.
    static func quota(for completion: SpendLimitResponse.Completion, now: Date) -> Quota? {
        guard completion.noMonthlyLimit != true,
              let limit = completion.usageLimit, limit > 0 else { return nil }
        let used = completion.totalUsage ?? completion.usage ?? 0
        let percent = completion.monthlyLimitReached == true ? 100 : used / limit * 100
        let (resetsAt, length) = monthWindow(containing: now)
        return Quota(window: Window(identity: .month, title: "Monthly spend", isMain: true,
                                    resetsAt: resetsAt, length: length),
                     percentUsed: percent)
    }

    /// The next 00:00 UTC (first day of next month) and the length of the current UTC month.
    static func monthWindow(containing date: Date) -> (resetsAt: Date, length: TimeInterval) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let resetsAt = calendar.date(byAdding: .month, value: 1, to: startOfMonth)!
        let days = calendar.range(of: .day, in: .month, for: startOfMonth)?.count ?? 30
        return (resetsAt, TimeInterval(days) * 86400)
    }

    struct SpendLimitResponse: Decodable {
        var limits: Limits?

        struct Limits: Decodable {
            var completion: Completion?
        }

        struct Completion: Decodable {
            var noMonthlyLimit: Bool?
            var monthlyLimitReached: Bool?
            var usage: Double?
            var totalUsage: Double?
            var vibeUsage: Double?
            var usageLimit: Double?

            enum CodingKeys: String, CodingKey {
                case noMonthlyLimit = "no_monthly_limit"
                case monthlyLimitReached = "monthly_limit_reached"
                case usage
                case totalUsage = "total_usage"
                case vibeUsage = "vibe_usage"
                case usageLimit = "usage_limit"
            }
        }
    }
}
