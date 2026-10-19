import Foundation

/// GitHub Copilot: a GitHub OAuth token obtained through the Copilot device-code flow, stored in
/// TokenMeter's Keychain item (no refresh; a revoked token shows "Sign in again").
struct CopilotCredentials: Codable, Equatable, Sendable {
    var token: String
}

/// Reads `GET /copilot_internal/user` (undocumented, used by the Copilot clients). Since June 2026
/// Copilot meters usage in AI credits: `premium_interactions` carries the monthly allotment, while
/// Free plans meter chat and completions. Business/Enterprise seats managed by an organization may
/// report only a `credits_used` count and no per-seat allowance.
struct CopilotProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.github.com")!
    static let loginHint = "Sign in again"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_COPILOT_BASE_URL` override).
    static let live = CopilotProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_COPILOT_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<CopilotCredentials>(missingHint: loginHint)

    var baseURL: URL = CopilotProvider.defaultBaseURL

    func read(account: Account, credentials: CopilotCredentials, session: URLSession, now: Date) async
        -> ProviderReading<CopilotCredentials> {
        var request = URLRequest(url: baseURL.appendingPathComponent("copilot_internal/user"))
        // The internal endpoint expects the `token` scheme; the Copilot clients send these headers.
        request.setValue("token \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-GitHub-Api-Version")

        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let body = try? JSONDecoder().decode(UsageResponse.self, from: data),
                          let reading = Self.reading(from: body, accountID: account.id, takenAt: now) else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    return .success(reading)
                case 401:
                    return .failure(.loginExpired(hint: Self.loginHint))
                case 403:
                    // Secondary rate limits send Retry-After; the primary limit sends
                    // X-RateLimit-Remaining: 0 plus X-RateLimit-Reset.
                    if let retryAfter = HTTP.retryAfter(response, now: now) {
                        return .failure(.rateLimited(retryAfter: retryAfter))
                    }
                    if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                            .flatMap(TimeInterval.init)
                        return .failure(.rateLimited(retryAfter: reset.map { max(0, $0 - now.timeIntervalSince1970) }))
                    }
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

    /// Nil when the response contains neither a Window nor a Credit balance and is not a
    /// token-based-billing placeholder. Every field is optional and malformed parts are skipped.
    static func reading(from body: UsageResponse, accountID: UUID, takenAt: Date) -> Reading? {
        let reset = resetDate(body)
        var quotas: [Quota] = []
        var credits: [CreditBalance] = []
        let premium = body.quota_snapshots?["premium_interactions"]
        var premiumMetered = false

        if let balance = premium?.creditBalance(renewsAt: reset) {
            credits.append(balance)
            premiumMetered = true
        } else if let used = premium?.credits_used, used > 0 {
            // Org-managed seats expose no allowance but may still report this user's credits.
            credits.append(CreditBalance(id: "credits_used", title: "Credits used",
                                         remaining: decimal(used), allowance: nil,
                                         currency: CreditBalance.creditsUnit, renewsAt: reset,
                                         isMain: true))
            premiumMetered = true
        }

        for (key, title) in [("chat", "Chat"), ("completions", "Completions")] {
            if let quota = snapshotQuota(body.quota_snapshots?[key], identity: key, title: title,
                                         isMain: !premiumMetered, resetsAt: reset) {
                quotas.append(quota)
            }
        }

        // Older Free responses report remaining counts against monthly limits instead of snapshots.
        if quotas.isEmpty && credits.isEmpty,
           let monthly = body.monthly_quotas, let limited = body.limited_user_quotas {
            for (key, title) in [("chat", "Chat"), ("completions", "Completions")] {
                guard let total = monthly.value(for: key), total > 0,
                      let remaining = limited.value(for: key) else { continue }
                quotas.append(Quota(window: Window(identity: .scoped(key), title: title, isMain: true,
                                                  resetsAt: reset, length: nil),
                                    percentUsed: 100 - remaining / total * 100))
            }
        }

        guard !quotas.isEmpty || !credits.isEmpty || body.token_based_billing == true else { return nil }
        let login = body.login?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reading(accountID: accountID, takenAt: takenAt, plan: planName(body),
                       identity: login?.isEmpty == false ? login : nil,
                       quotas: quotas, credits: credits)
    }

    private static func snapshotQuota(_ snapshot: Snapshot?, identity: String, title: String,
                                      isMain: Bool, resetsAt: Date?) -> Quota? {
        guard let snapshot, snapshot.unlimited != true,
              let entitlement = snapshot.entitlement, entitlement > 0,
              snapshot.remaining != -1 else { return nil }
        let percentUsed: Double
        if let percentRemaining = snapshot.percent_remaining {
            percentUsed = 100 - percentRemaining
        } else if let remaining = snapshot.remaining {
            percentUsed = 100 - remaining / entitlement * 100
        } else if let used = snapshot.credits_used {
            percentUsed = used / entitlement * 100
        } else {
            return nil
        }
        return Quota(window: Window(identity: .scoped(identity), title: title, isMain: isMain,
                                    resetsAt: resetsAt, length: nil),
                     percentUsed: percentUsed)
    }

    static func planName(_ body: UsageResponse) -> String? {
        if body.access_type_sku?.lowercased().contains("free") == true { return "Free" }
        guard let raw = body.copilot_plan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "individual": return "Individual"
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "max": return "Max"
        default: return raw
        }
    }

    static func resetDate(_ body: UsageResponse) -> Date? {
        let candidates = [body.quota_reset_date_utc, body.quota_reset_date, body.limited_user_reset_date]
        for raw in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            where !raw.isEmpty {
            if let date = HTTP.date(raw) { return date }
            if let date = dayOnlyDate(raw) { return date }
        }
        return nil
    }

    /// A bare `yyyy-MM-dd` reset date, interpreted as 00:00 UTC.
    private static func dayOnlyDate(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    private static func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(value)) ?? Decimal(value)
    }

    // MARK: - Response model (tolerant: every field optional, malformed parts skipped)

    struct UsageResponse: Decodable {
        var login: String?
        var copilot_plan: String?
        var access_type_sku: String?
        var quota_reset_date: String?
        var quota_reset_date_utc: String?
        var limited_user_reset_date: String?
        var token_based_billing: Bool?
        var quota_snapshots: [String: Snapshot]?
        var monthly_quotas: Counts?
        var limited_user_quotas: Counts?

        private enum CodingKeys: String, CodingKey {
            case login, copilot_plan, access_type_sku, quota_reset_date, quota_reset_date_utc
            case limited_user_reset_date, token_based_billing, quota_snapshots
            case monthly_quotas, limited_user_quotas
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            login = try? c.decodeIfPresent(String.self, forKey: .login)
            copilot_plan = try? c.decodeIfPresent(String.self, forKey: .copilot_plan)
            access_type_sku = try? c.decodeIfPresent(String.self, forKey: .access_type_sku)
            quota_reset_date = try? c.decodeIfPresent(String.self, forKey: .quota_reset_date)
            quota_reset_date_utc = try? c.decodeIfPresent(String.self, forKey: .quota_reset_date_utc)
            limited_user_reset_date = try? c.decodeIfPresent(String.self, forKey: .limited_user_reset_date)
            token_based_billing = try? c.decodeIfPresent(Bool.self, forKey: .token_based_billing)
            quota_snapshots = try? c.decodeIfPresent([String: Snapshot].self, forKey: .quota_snapshots)
            monthly_quotas = try? c.decodeIfPresent(Counts.self, forKey: .monthly_quotas)
            limited_user_quotas = try? c.decodeIfPresent(Counts.self, forKey: .limited_user_quotas)
        }
    }

    struct Snapshot: Decodable {
        var entitlement: Double?
        var remaining: Double?
        var quota_remaining: Double?
        var percent_remaining: Double?
        var credits_used: Double?
        var unlimited: Bool?

        private enum CodingKeys: String, CodingKey {
            case entitlement, remaining, quota_remaining, percent_remaining, credits_used, unlimited
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entitlement = (try? c.decodeIfPresent(FlexibleNumber.self, forKey: .entitlement))?.value
            remaining = (try? c.decodeIfPresent(FlexibleNumber.self, forKey: .remaining))?.value
            quota_remaining = (try? c.decodeIfPresent(FlexibleNumber.self, forKey: .quota_remaining))?.value
            percent_remaining = (try? c.decodeIfPresent(FlexibleNumber.self, forKey: .percent_remaining))?.value
            credits_used = (try? c.decodeIfPresent(FlexibleNumber.self, forKey: .credits_used))?.value
            unlimited = try? c.decodeIfPresent(Bool.self, forKey: .unlimited)
        }

        /// The monthly AI-credit balance, or nil for an unlimited/placeholder bucket.
        func creditBalance(renewsAt: Date?) -> CreditBalance? {
            guard unlimited != true, let entitlement, entitlement > 0,
                  remaining != -1 else { return nil }
            let remaining: Double
            if let quotaRemaining = quota_remaining {
                remaining = quotaRemaining
            } else if let integerRemaining = self.remaining {
                remaining = integerRemaining
            } else if let used = credits_used {
                remaining = entitlement - used
            } else if let percentRemaining = percent_remaining {
                remaining = entitlement * percentRemaining / 100
            } else {
                return nil
            }
            return CreditBalance(id: "credits", title: "Credits", remaining: decimal(remaining),
                                 allowance: decimal(entitlement), currency: CreditBalance.creditsUnit,
                                 renewsAt: renewsAt, isMain: true)
        }
    }

    struct Counts: Decodable {
        var chat: Double?
        var completions: Double?

        private enum CodingKeys: String, CodingKey { case chat, completions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chat = (try? c.decodeIfPresent(FlexibleNumber.self, forKey: .chat))?.value
            completions = (try? c.decodeIfPresent(FlexibleNumber.self, forKey: .completions))?.value
        }

        func value(for key: String) -> Double? {
            key == "chat" ? chat : completions
        }
    }
}

/// A JSON number or numeric string (`1500`, `"1500"`, `19.25`); nil for anything else.
private struct FlexibleNumber: Decodable {
    var value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = Double(string.trimmingCharacters(in: .whitespaces))
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else {
            value = nil
        }
    }
}
