import Foundation

/// OpenCode Zen/Go: an API key pasted in Settings, stored in TokenMeter's Keychain item.
struct OpenCodeCredentials: Codable, Equatable, Sendable {
    var apiKey: String
}

/// Reads `GET /zen/go/v1/usage`: the rolling (5 h), weekly and monthly Go subscription windows.
struct OpenCodeProvider: Provider {
    static let defaultBaseURL = URL(string: "https://opencode.ai")!
    static let loginHint = "Check API key"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_OPENCODE_BASE_URL` override).
    static let live = OpenCodeProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_OPENCODE_BASE_URL")
                                           ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<OpenCodeCredentials>(missingHint: loginHint)

    /// The window lengths the usage endpoint reports; each window is identified by its own field.
    static let rollingLength: TimeInterval = 5 * 60 * 60
    static let weeklyLength: TimeInterval = 7 * 24 * 60 * 60
    static let monthlyLength: TimeInterval = 30 * 24 * 60 * 60

    var baseURL: URL = OpenCodeProvider.defaultBaseURL

    func read(account: Account, credentials: OpenCodeCredentials, session: URLSession, now: Date) async
        -> ProviderReading<OpenCodeCredentials> {
        var request = URLRequest(url: baseURL.appendingPathComponent("zen/go/v1/usage"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let body = try? JSONDecoder().decode(UsageResponse.self, from: data),
                          let usage = body.usage else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    return .success(Reading(accountID: account.id, takenAt: now, plan: nil, identity: nil,
                                            quotas: Self.map(usage), credits: []))
                case 401:
                    return .failure(.loginExpired(hint: Self.loginHint))
                case 403:
                    return .failure(Self.isEntitlementError(data)
                        ? .unavailable("No OpenCode Go subscription on this key")
                        : .loginExpired(hint: Self.loginHint))
                case 429:
                    return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
                default:
                    return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
                }
            }
        return ProviderReading(result)
    }

    // MARK: - Mapping

    /// The three windows the endpoint reports. `rate-limited` means the window is fully used.
    static func map(_ usage: UsageResponse.Usage) -> [Quota] {
        var quotas: [Quota] = []
        func quota(_ window: UsageResponse.Window?, identity: WindowIdentity, title: String,
                   isMain: Bool, length: TimeInterval) {
            guard let window else { return }
            let percent = window.status == "rate-limited" ? 100 : (window.percent ?? 0)
            quotas.append(Quota(
                window: Window(identity: identity, title: title, isMain: isMain,
                               resetsAt: HTTP.date(window.resetsAt), length: length),
                percentUsed: percent))
        }
        quota(usage.rolling, identity: .scoped("rolling_5h"), title: "Session", isMain: true,
              length: rollingLength)
        quota(usage.weekly, identity: .week, title: "Weekly", isMain: false,
              length: weeklyLength)
        quota(usage.monthly, identity: .month, title: "Monthly", isMain: false,
              length: monthlyLength)
        return quotas
    }

    /// True when a 403 body names an `EntitlementError` (the key is valid but has no Go plan).
    static func isEntitlementError(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        return (error["type"] as? String) == "EntitlementError"
    }

    struct UsageResponse: Decodable {
        struct Window: Decodable {
            var status: String?
            var percent: Double?
            var resetsAt: String?
        }

        struct Usage: Decodable {
            var rolling: Window?
            var weekly: Window?
            var monthly: Window?
        }

        var usage: Usage?
    }
}
