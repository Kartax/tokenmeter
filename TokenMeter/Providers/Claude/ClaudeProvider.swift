import Foundation

/// Claude Code's OAuth login, borrowed for one fetch (ADR 0001). Deliberately not `Encodable`:
/// TokenMeter never stores, copies or refreshes this token. It lives in memory for one request.
struct ClaudeCredentials: Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date?
    /// e.g. "max", "pro" — Plan fallback when the profile has no rate-limit tier.
    var subscriptionType: String?
    /// e.g. "default_claude_max_5x".
    var rateLimitTier: String?
}

extension ClaudeCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never reveals the token, even if the value ends up in a log or debugger print.
    var description: String {
        "ClaudeCredentials(accessToken: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))"
    }

    var debugDescription: String { description }
}

/// Reads `GET /api/oauth/usage` (required) and `GET /api/oauth/profile` (Plan and identity,
/// best effort) with Claude Code's OAuth token. Both endpoints are undocumented; parsing is lenient.
struct ClaudeProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    static let loginHint = "run `claude`"
    /// A 429 backs the Account off for at least this long, even when `Retry-After` is shorter.
    static let minimumBackOff: TimeInterval = 5 * 60
    static let userAgent = "claude-cli/2.1.0 (external, cli)"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_CLAUDE_BASE_URL` override).
    static let live = ClaudeProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_CLAUDE_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = ClaudeCredentialSource()

    var baseURL: URL = ClaudeProvider.defaultBaseURL

    func read(account: Account, credentials: ClaudeCredentials, session: URLSession, now: Date) async
        -> ProviderReading<ClaudeCredentials> {
        // Claude Code owns the refresh-token rotation; an expired token is never refreshed here.
        if let expiresAt = credentials.expiresAt, expiresAt <= now {
            return ProviderReading(.failure(.loginExpired(hint: Self.loginHint)))
        }
        async let profile = fetchProfile(credentials, session: session)
        let usage = await fetchUsage(credentials, session: session, now: now)
        let fetchedProfile = await profile
        return ProviderReading(usage.map { usage in
            let plan = ClaudePlan.displayName(tier: fetchedProfile?.rateLimitTier ?? credentials.rateLimitTier,
                                              subscriptionType: credentials.subscriptionType)
            return Reading(accountID: account.id, takenAt: now, plan: plan, identity: fetchedProfile?.email,
                           quotas: usage.quotas, credits: usage.credits)
        })
    }

    private func request(_ path: String, _ credentials: ClaudeCredentials) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - /api/oauth/usage

    private func fetchUsage(_ credentials: ClaudeCredentials, session: URLSession, now: Date) async
        -> Result<(quotas: [Quota], credits: [CreditBalance]), ReadingFailure> {
        await HTTP.send(request("api/oauth/usage", credentials), session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mapped = ClaudeUsage.map(object) else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return .success(mapped)
            case 401, 403:
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                let retryAfter = max(HTTP.retryAfter(response, now: now) ?? 0, Self.minimumBackOff)
                return .failure(.rateLimited(retryAfter: retryAfter))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    // MARK: - /api/oauth/profile

    private struct Profile {
        var email: String?
        var rateLimitTier: String?
    }

    /// Identity and rate-limit tier; any failure yields nil and never fails the Reading.
    private func fetchProfile(_ credentials: ClaudeCredentials, session: URLSession) async -> Profile? {
        guard case .success(let (data, response)) = await HTTP.send(request("api/oauth/profile", credentials),
                                                                    session: session),
              (200..<300).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            coreLog.info("Claude profile unavailable; Reading continues without identity")
            return nil
        }
        let account = object["account"] as? [String: Any]
        let organization = object["organization"] as? [String: Any]
        let email = ["email", "email_address", "emailAddress"].lazy
            .compactMap { (account?[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return Profile(email: email, rateLimitTier: organization?["rate_limit_tier"] as? String)
    }
}

/// Maps the usage response. Field names identify Windows: `five_hour` → main `session`,
/// `seven_day` → main `week`, other `seven_day_*` → scoped weekly Windows.
enum ClaudeUsage {
    private static let sessionLength: TimeInterval = 5 * 3600
    private static let weekLength: TimeInterval = 7 * 86400

    /// Nil when the response contains neither a Window nor a Credit balance.
    static func map(_ object: [String: Any]) -> (quotas: [Quota], credits: [CreditBalance])? {
        var quotas: [Quota] = []
        var credits: [CreditBalance] = []

        let session = window(named: "five_hour", in: object)
        let week = window(named: "seven_day", in: object)
        if let session {
            quotas.append(quota(.session, title: "Session", isMain: true, length: sessionLength, session))
        }
        if let week {
            quotas.append(quota(.week, title: "Week", isMain: true, length: weekLength, week))
        }
        for name in scopedWindowNames(in: object) {
            guard let usage = window(named: name, in: object) else { continue }
            quotas.append(quota(.scoped(name), title: scopedTitle(name), isMain: false, length: weekLength, usage))
        }

        if let extra = object["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let limitCents = decimal(extra["monthly_limit"]) {
            // `monthly_limit` and `used_credits` are in cents.
            let usedCents = decimal(extra["used_credits"]) ?? 0
            credits.append(CreditBalance(id: "extra_usage", title: "Extra usage",
                                         remaining: (limitCents - usedCents) / 100, allowance: limitCents / 100,
                                         currency: (extra["currency"] as? String) ?? "USD",
                                         renewsAt: nil, isMain: false))
        }

        // Usage-based organisations have no session/week Windows but a spend limit.
        if session == nil, week == nil, let spend = object["spend"] as? [String: Any],
           let limit = decimal(spend["limit"]) {
            let used = decimal(spend["used"]) ?? 0
            credits.insert(CreditBalance(id: "spend", title: "Spend limit", remaining: limit - used,
                                         allowance: limit, currency: (spend["currency"] as? String) ?? "USD",
                                         renewsAt: HTTP.date((spend["resets_at"] ?? spend["resetsAt"]) as? String),
                                         isMain: true), at: 0)
        }

        return quotas.isEmpty && credits.isEmpty ? nil : (quotas, credits)
    }

    private struct WindowUsage {
        var utilization: Double
        var resetsAt: Date?
    }

    /// A Window by field name: the nested `{utilization, resets_at}` object, or the legacy flat
    /// `<name>_utilization` / `<name>_resets_at` fields. Nil when absent or null.
    private static func window(named name: String, in object: [String: Any]) -> WindowUsage? {
        if let nested = object[name] as? [String: Any] {
            guard let utilization = double(nested["utilization"]) else { return nil }
            return WindowUsage(utilization: utilization, resetsAt: HTTP.date(nested["resets_at"] as? String))
        }
        guard let utilization = double(object["\(name)_utilization"]) else { return nil }
        return WindowUsage(utilization: utilization, resetsAt: HTTP.date(object["\(name)_resets_at"] as? String))
    }

    /// `seven_day_<scope>` names in either form, sorted for a stable order.
    private static func scopedWindowNames(in object: [String: Any]) -> [String] {
        let names = object.keys.compactMap { key -> String? in
            guard key.hasPrefix("seven_day_") else { return nil }
            if key.hasSuffix("_utilization") { return String(key.dropLast("_utilization".count)) }
            if key.hasSuffix("_resets_at") { return nil }
            return key
        }
        return Set(names).subtracting(["seven_day"]).sorted()
    }

    /// "seven_day_oauth_apps" → "OAuth apps week", "seven_day_sonnet" → "Sonnet week".
    private static func scopedTitle(_ name: String) -> String {
        let scope = name.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ")
        let words = scope.split(separator: " ").map { word in
            word.lowercased() == "oauth" ? "OAuth" : String(word)
        }
        let title = words.joined(separator: " ")
        return (title.prefix(1).uppercased() + title.dropFirst()) + " week"
    }

    private static func quota(_ identity: WindowIdentity, title: String, isMain: Bool, length: TimeInterval,
                              _ usage: WindowUsage) -> Quota {
        Quota(window: Window(identity: identity, title: title, isMain: isMain, resetsAt: usage.resetsAt,
                             length: length),
              percentUsed: usage.utilization)
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse):
            number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse):
            Decimal(string: number.stringValue)
        case let string as String: Decimal(string: string)
        default: nil
        }
    }
}

/// Plan display names from Claude's rate-limit tier or subscription type.
enum ClaudePlan {
    /// "default_claude_max_5x" → "Max 5x", "claude_pro" → "Pro"; falls back to the
    /// subscription type ("max" → "Max"). Nil when neither is known.
    static func displayName(tier: String?, subscriptionType: String?) -> String? {
        if let tier, let name = name(from: tier) { return name }
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespaces), !type.isEmpty else { return nil }
        return name(from: type) ?? type.capitalized
    }

    private static func name(from raw: String) -> String? {
        let parts = raw.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        if parts.contains("max") {
            let multiplier = parts.last { $0.hasSuffix("x") && Int($0.dropLast()) != nil }
            return multiplier.map { "Max \($0)" } ?? "Max"
        }
        for (key, name) in [("pro", "Pro"), ("team", "Team"), ("enterprise", "Enterprise"), ("free", "Free")]
        where parts.contains(Substring(key)) {
            return name
        }
        return nil
    }
}
