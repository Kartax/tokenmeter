import Foundation

/// Codex (ChatGPT): reads `GET /backend-api/wham/usage` with TokenMeter's own ChatGPT tokens.
struct CodexProvider: Provider {
    static let defaultUsageBaseURL = URL(string: "https://chatgpt.com")!
    static let loginHint = "Sign in again"
    /// Refresh the access token when it expires within this many seconds.
    static let refreshMargin: TimeInterval = 300

    /// The instance the app uses. DEBUG `TOKENMETER_CODEX_BASE_URL` points both the usage and the
    /// auth endpoints at one local stub server.
    static let live: CodexProvider = {
        let debug = ProviderRegistry.debugBaseURL("TOKENMETER_CODEX_BASE_URL")
        return CodexProvider(usageBaseURL: debug ?? defaultUsageBaseURL, auth: .live)
    }()
    static let credentialSource = KeychainCredentialSource<CodexCredentials>(missingHint: loginHint)

    var usageBaseURL: URL = CodexProvider.defaultUsageBaseURL
    var auth = CodexAuth()

    func read(account: Account, credentials: CodexCredentials, session: URLSession, now: Date) async
        -> ProviderReading<CodexCredentials> {
        await read(account: account, credentials: credentials, session: session, now: now, persist: { _ in })
    }

    /// Refreshes first when the access token expires within `refreshMargin`, and once more on a 401.
    /// Rotated tokens go to `persist` before they are used.
    func read(account: Account, credentials: CodexCredentials, session: URLSession, now: Date,
              persist: @Sendable (CodexCredentials) -> Void) async -> ProviderReading<CodexCredentials> {
        var current = credentials
        var rotated: CodexCredentials?
        let expiresAt = JWTClaims(credentials.accessToken)?.expiresAt

        if let expiresAt, expiresAt.timeIntervalSince(now) < Self.refreshMargin {
            switch await auth.refresh(current, session: session, now: now) {
            case .success(let new):
                persist(new)
                (current, rotated) = (new, new)
            case .failure(let failure):
                // A dead grant ends here; a transient failure only does once the token has expired.
                if case .loginExpired = failure { return ProviderReading(.failure(failure)) }
                if expiresAt <= now { return ProviderReading(.failure(failure)) }
            }
        }

        var usage = await fetchUsage(current, session: session, now: now)
        if case .failure(.loginExpired) = usage, rotated == nil {
            switch await auth.refresh(current, session: session, now: now) {
            case .success(let new):
                persist(new)
                (current, rotated) = (new, new)
                usage = await fetchUsage(current, session: session, now: now)
            case .failure(let failure):
                return ProviderReading(.failure(failure))
            }
        }
        let final = current
        return ProviderReading(usage.map { reading(from: $0, account: account, credentials: final, now: now) },
                               rotatedCredentials: rotated)
    }

    // MARK: - wham/usage

    private func fetchUsage(_ credentials: CodexCredentials, session: URLSession, now: Date) async
        -> Result<UsageResponse, ReadingFailure> {
        var request = URLRequest(url: usageBaseURL.appendingPathComponent("backend-api/wham/usage"))
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.identity.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return .success(body)
            case 401:
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    private func reading(from body: UsageResponse, account: Account, credentials: CodexCredentials, now: Date) -> Reading {
        var quotas = body.rate_limit?.quotas(scope: nil) ?? []
        for limit in body.additional_rate_limits ?? [] {
            guard let key = limit.metered_feature ?? limit.limit_name else { continue }
            quotas += limit.rate_limit?.quotas(scope: (key, limit.limit_name ?? key)) ?? []
        }
        quotas += body.code_review_rate_limit?.quotas(scope: ("code_review", "Code review")) ?? []

        var credits: [CreditBalance] = []
        if let c = body.credits, c.has_credits == true, c.unlimited != true, let balance = c.balance {
            credits.append(CreditBalance(id: "credits", title: "Credits", remaining: balance, allowance: nil,
                                         currency: CreditBalance.creditsUnit, renewsAt: nil, isMain: false))
        }
        return Reading(accountID: account.id, takenAt: now, plan: body.plan_type.map(Self.planName),
                       identity: credentials.identity.email, quotas: quotas, credits: credits)
    }

    /// Display name for a `plan_type`; unknown ids are shown verbatim.
    static func planName(_ id: String) -> String {
        switch id {
        case "plus": "Plus"
        case "pro": "Pro"
        case "prolite": "Pro 100"
        case "promax": "Pro 500"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        default: id
        }
    }

    // MARK: - Response model (tolerant: every field optional, malformed parts skipped)

    private struct UsageResponse: Decodable {
        var plan_type: String?
        var rate_limit: RateLimit?
        var additional_rate_limits: [AdditionalLimit]?
        var code_review_rate_limit: RateLimit?
        var credits: Credits?

        private enum CodingKeys: String, CodingKey {
            case plan_type, rate_limit, additional_rate_limits, code_review_rate_limit, credits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plan_type = try? c.decodeIfPresent(String.self, forKey: .plan_type)
            rate_limit = try? c.decodeIfPresent(RateLimit.self, forKey: .rate_limit)
            additional_rate_limits = (try? c.decodeIfPresent([Lossy<AdditionalLimit>].self,
                                                             forKey: .additional_rate_limits))?.compactMap(\.value)
            code_review_rate_limit = try? c.decodeIfPresent(RateLimit.self, forKey: .code_review_rate_limit)
            credits = try? c.decodeIfPresent(Credits.self, forKey: .credits)
        }
    }

    private struct RateLimit: Decodable {
        var primary_window: WindowSnapshot?
        var secondary_window: WindowSnapshot?

        /// Quotas of both slots, each identified by its window length (never by its slot).
        /// `scope` (key, title) marks model- or feature-scoped limits.
        func quotas(scope: (key: String, title: String)?) -> [Quota] {
            [primary_window, secondary_window].compactMap { $0?.quota(scope: scope) }
        }
    }

    private struct WindowSnapshot: Decodable {
        var used_percent: Double?
        var limit_window_seconds: Double?
        var reset_at: Double?

        func quota(scope: (key: String, title: String)?) -> Quota? {
            guard let used_percent, let length = limit_window_seconds, length > 0 else { return nil }
            let (key, title, mainIdentity) = Self.kind(length: length)
            let identity: WindowIdentity = if let scope {
                .scoped("\(scope.key).\(key)")
            } else {
                mainIdentity ?? .scoped("rate_limit.\(key)")
            }
            let window = Window(identity: identity, title: scope.map { "\($0.title) · \(title)" } ?? title,
                                isMain: scope == nil, resetsAt: reset_at.map(Date.init(timeIntervalSince1970:)),
                                length: length)
            return Quota(window: window, percentUsed: used_percent)
        }

        /// 5 hours → session, 7 days → week; other lengths get a key and title from their length.
        private static func kind(length: Double) -> (key: String, title: String, identity: WindowIdentity?) {
            switch Int(length) {
            case 18000: return ("session", "Session", .session)
            case 604800: return ("week", "Week", .week)
            case let seconds where seconds % 86400 == 0: return ("\(seconds)s", "\(seconds / 86400)-day", nil)
            case let seconds where seconds % 3600 == 0: return ("\(seconds)s", "\(seconds / 3600)-hour", nil)
            case let seconds: return ("\(seconds)s", "\(max(1, seconds / 60))-minute", nil)
            }
        }
    }

    private struct AdditionalLimit: Decodable {
        var limit_name: String?
        var metered_feature: String?
        var rate_limit: RateLimit?
    }

    private struct Credits: Decodable {
        var has_credits: Bool?
        var unlimited: Bool?
        var balance: Decimal?

        private enum CodingKeys: String, CodingKey { case has_credits, unlimited, balance }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            has_credits = try? c.decodeIfPresent(Bool.self, forKey: .has_credits)
            unlimited = try? c.decodeIfPresent(Bool.self, forKey: .unlimited)
            // A decimal string ("14.5") in practice; accept a number too.
            balance = (try? c.decodeIfPresent(String.self, forKey: .balance)).flatMap { $0.flatMap { Decimal(string: $0) } }
                ?? (try? c.decodeIfPresent(Decimal.self, forKey: .balance)) ?? nil
        }
    }
}
