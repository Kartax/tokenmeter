import Foundation

/// Ollama Cloud: an API key pasted in Settings, stored in TokenMeter's Keychain item.
struct OllamaCredentials: Codable, Equatable, Sendable {
    var apiKey: String
}

/// Reads `GET /api/balance` (required) and `POST /api/me` (Plan and identity, best effort).
/// See https://docs.ollama.com/api/balance — documented limit 10 requests/min per user.
struct OllamaProvider: Provider {
    static let defaultBaseURL = URL(string: "https://ollama.com")!
    static let loginHint = "Check API key"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_OLLAMA_BASE_URL` override).
    static let live = OllamaProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_OLLAMA_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<OllamaCredentials>(missingHint: loginHint)

    var baseURL: URL = OllamaProvider.defaultBaseURL

    func read(account: Account, credentials: OllamaCredentials, session: URLSession, now: Date) async
        -> ProviderReading<OllamaCredentials> {
        async let me = fetchMe(credentials, session: session)
        let balance = await fetchBalance(credentials, session: session, now: now)
        let profile = await me
        return ProviderReading(balance.map { balance in
            Reading(accountID: account.id, takenAt: now, plan: profile?.plan, identity: profile?.identity,
                    quotas: balance.quotas, credits: balance.credits)
        })
    }

    // MARK: - /api/balance

    private func fetchBalance(_ credentials: OllamaCredentials, session: URLSession, now: Date) async
        -> Result<(quotas: [Quota], credits: [CreditBalance]), ReadingFailure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/balance"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(BalanceResponse.self, from: data),
                      let mapped = Self.map(body) else { return .failure(.unavailable("Unexpected response")) }
                return .success(mapped)
            case 401, 403:
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    /// Allowance plans → main monthly CreditBalance; legacy plans → main `session` and `week`
    /// Quotas; purchased credits → non-main CreditBalance. Nil when `included` matches neither shape.
    private static func map(_ body: BalanceResponse) -> (quotas: [Quota], credits: [CreditBalance])? {
        guard let included = body.included else { return nil }
        var quotas: [Quota] = []
        var credits: [CreditBalance] = []

        if let allowance = included.allowance_usd {
            guard let balance = included.balance_usd else { return nil }
            credits.append(CreditBalance(id: "included", title: "Monthly credits", remaining: balance,
                                         allowance: allowance, currency: "USD",
                                         renewsAt: HTTP.date(included.period?.until), isMain: true))
        } else {
            if let session = included.session?.quota(.session, title: "Session", length: 5 * 3600) {
                quotas.append(session)
            }
            if let week = included.weekly?.quota(.week, title: "Week", length: 7 * 86400) {
                quotas.append(week)
            }
            guard !quotas.isEmpty else { return nil }
        }

        if let purchased = body.purchased?.balance_usd {
            credits.append(CreditBalance(id: "purchased", title: "Purchased credits", remaining: purchased,
                                         allowance: nil, currency: "USD", renewsAt: nil, isMain: false))
        }
        return (quotas, credits)
    }

    private struct BalanceResponse: Decodable {
        var included: Included?
        var purchased: Purchased?

        struct Included: Decodable {
            var balance_usd: Decimal?
            var allowance_usd: Decimal?
            var period: Period?
            var session: Limit?
            var weekly: Limit?
        }

        struct Period: Decodable {
            var from: String?
            var until: String?
        }

        struct Limit: Decodable {
            var remaining_percent: Double?
            var resets_at: String?

            func quota(_ identity: WindowIdentity, title: String, length: TimeInterval) -> Quota? {
                guard let remaining_percent else { return nil }
                let window = Window(identity: identity, title: title, isMain: true,
                                    resetsAt: HTTP.date(resets_at), length: length)
                return Quota(window: window, percentUsed: 100 - remaining_percent)
            }
        }

        struct Purchased: Decodable {
            var balance_usd: Decimal?
        }
    }

    // MARK: - /api/me

    private struct Profile {
        var plan: String?
        var identity: String?
    }

    /// Plan and identity; any failure yields nil and never fails the Reading.
    private func fetchMe(_ credentials: OllamaCredentials, session: URLSession) async -> Profile? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard case .success(let (data, response)) = await HTTP.send(request, session: session),
              (200..<300).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            coreLog.info("Ollama /api/me unavailable; Reading continues without Plan")
            return nil
        }
        // ollama.com capitalises keys ("Plan"); the local Ollama proxy lowercases them.
        func string(_ key: String) -> String? {
            let value = (object[key.capitalized] ?? object[key]) as? String
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return Profile(plan: string("plan")?.capitalized, identity: string("email") ?? string("name"))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
