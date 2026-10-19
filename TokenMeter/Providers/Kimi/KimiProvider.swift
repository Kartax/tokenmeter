import Foundation

/// Kimi Code's OAuth login, borrowed from `~/.kimi/credentials/kimi-code.json` for one fetch.
/// Deliberately not `Encodable`: TokenMeter never stores or rewrites this login.
struct KimiCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    /// Seconds since 1970, as stored by Kimi Code (`expires_at`).
    var expiresAt: TimeInterval?
}

extension KimiCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never reveals a token, even if the value ends up in a log or debugger print.
    var description: String {
        "KimiCredentials(accessToken: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))"
    }

    var debugDescription: String { description }
}

/// Reads Kimi Code's local login fresh on every fetch; never saves, refreshes on disk or deletes it.
struct KimiCredentialSource: CredentialSource {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
    }

    /// Overridable for tests; the app always reads the default path.
    var fileURL: URL = KimiCredentialSource.defaultFileURL

    func load(for account: Account) -> Result<KimiCredentials, ReadingFailure> {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .failure(.loginExpired(hint: KimiProvider.loginHint))
        }
        guard let credentials = Self.parse(data) else {
            return .failure(.loginExpired(hint: KimiProvider.loginHint))
        }
        return .success(credentials)
    }

    /// Never called: Kimi Code owns its login, and TokenMeter stores no Kimi secret.
    func save(_ credentials: KimiCredentials, for account: Account) throws {}

    /// Nothing to delete: removing the Account must not touch Kimi Code's login.
    func delete(for account: Account) throws {}

    /// True when Kimi Code's login file exists. Reads attributes only.
    static func hasLogin(fileURL: URL = KimiCredentialSource.defaultFileURL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// `{"access_token", "refresh_token", "expires_at" (seconds)}`; other fields are ignored.
    static func parse(_ data: Data) -> KimiCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let token = (object["access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        let refreshToken = (object["refresh_token"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return KimiCredentials(accessToken: token, refreshToken: refreshToken,
                               expiresAt: number(object["expires_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

/// Reads `GET /coding/v1/usages` with Kimi Code's borrowed OAuth token. The token is refreshed
/// in memory when it is near expiry (60 s buffer), but the rotation is never written back.
struct KimiProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.kimi.com")!
    static let defaultAuthURL = URL(string: "https://auth.kimi.com")!
    static let loginHint = "Run `kimi login`"
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// Refresh this many seconds before `expiresAt`, so a slow request does not use a dead token.
    static let refreshBuffer: TimeInterval = 60

    /// The instance the app uses (honours the DEBUG `TOKENMETER_KIMI_BASE_URL` override).
    static let live = KimiProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_KIMI_BASE_URL")
                                       ?? defaultBaseURL)
    static let credentialSource = KimiCredentialSource()

    var baseURL: URL
    /// OAuth host; overridable separately so tests can route token refreshes.
    var authURL: URL

    init(baseURL: URL = KimiProvider.defaultBaseURL, authURL: URL = KimiProvider.defaultAuthURL) {
        self.baseURL = baseURL
        self.authURL = authURL
    }

    func read(account: Account, credentials: KimiCredentials, session: URLSession, now: Date) async
        -> ProviderReading<KimiCredentials> {
        let token: KimiCredentials
        switch await tokenForRequest(credentials, session: session, now: now) {
        case .success(let usable): token = usable
        case .failure(let failure): return ProviderReading(.failure(failure))
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("coding/v1/usages"))
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let mapped = Self.map(object) else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    return .success(Reading(accountID: account.id, takenAt: now, plan: mapped.plan,
                                            identity: nil, quotas: mapped.quotas, credits: []))
                case 401, 403:
                    return .failure(.loginExpired(hint: Self.loginHint))
                case 429:
                    return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
                default:
                    return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
                }
            }
        // A refreshed token is used for this request only: Kimi Code's file is never rewritten.
        return ProviderReading(result)
    }

    // MARK: - Token refresh

    /// The stored token, refreshed in memory when it expires within the buffer.
    private func tokenForRequest(_ credentials: KimiCredentials, session: URLSession, now: Date) async
        -> Result<KimiCredentials, ReadingFailure> {
        guard let expiresAt = credentials.expiresAt,
              expiresAt <= now.timeIntervalSince1970 + Self.refreshBuffer else {
            return .success(credentials)
        }
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .failure(.loginExpired(hint: Self.loginHint))
        }

        var request = URLRequest(url: authURL.appendingPathComponent("api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody([
            ("client_id", Self.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])

        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = (object["access_token"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty else {
                    return .failure(.loginExpired(hint: Self.loginHint))
                }
                let rotatedRefresh = (object["refresh_token"] as? String)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                let expiresAt = Self.refreshExpiry(object, now: now) ?? credentials.expiresAt
                return .success(KimiCredentials(
                    accessToken: accessToken,
                    refreshToken: rotatedRefresh ?? refreshToken,
                    expiresAt: expiresAt))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                // A rejected grant (invalid/revoked refresh token) means the local login is stale.
                return .failure(.loginExpired(hint: Self.loginHint))
            }
        }
    }

    private static func refreshExpiry(_ object: [String: Any], now: Date) -> TimeInterval? {
        if let expiresIn = number(object["expires_in"]) {
            return now.timeIntervalSince1970 + expiresIn
        }
        return number(object["expires_at"])
    }

    // MARK: - Mapping

    /// `usage` is the main monthly Plan window. Each `limits[]` entry is a scoped Window named by
    /// its duration, so a reordered response never renames a Window. Without `usage`, the most
    /// constrained limit becomes main. Nil when the body has neither.
    static func map(_ object: [String: Any]) -> (plan: String?, quotas: [Quota])? {
        var quotas: [Quota] = []

        if let usage = object["usage"] as? [String: Any],
           let limit = number(usage["limit"]), limit > 0,
           let remaining = number(usage["remaining"]) {
            quotas.append(Quota(
                window: Window(identity: .month, title: "Plan", isMain: true,
                               resetsAt: resetDate(usage["resetTime"]), length: nil),
                percentUsed: percent(limit: limit, remaining: remaining)))
        }

        var limitQuotas: [Quota] = []
        if let limits = object["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let window = limit["window"] as? [String: Any],
                      let detail = limit["detail"] as? [String: Any],
                      let duration = number(window["duration"]), duration > 0,
                      let limitValue = number(detail["limit"]), limitValue > 0,
                      let remaining = number(detail["remaining"]) else { continue }
                let unit = (window["timeUnit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let unitName = unit ?? "unit"
                let minutes = totalMinutes(duration: duration, unit: unit)
                let title = minutes == 300 ? "Session"
                    : minutes == 10080 ? "Weekly"
                    : "\(Int(duration)) \(displayUnit(unitName))"
                limitQuotas.append(Quota(
                    window: Window(identity: .scoped("limit-\(Int(duration))-\(unitName)"),
                                   title: title, isMain: false,
                                   resetsAt: resetDate(detail["resetTime"]),
                                   length: seconds(duration: duration, unit: unit)),
                    percentUsed: percent(limit: limitValue, remaining: remaining)))
            }
        }

        if quotas.isEmpty {
            guard !limitQuotas.isEmpty else { return nil }
            // Most constrained wins, regardless of where it sits in the array.
            let main = limitQuotas.indices.max { limitQuotas[$0].percentUsed < limitQuotas[$1].percentUsed }
            if let main { limitQuotas[main].window.isMain = true }
        }
        quotas.append(contentsOf: limitQuotas)

        return (planName(in: object), quotas)
    }

    private static func planName(in object: [String: Any]) -> String? {
        guard let user = object["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let raw = (membership["level"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw {
        case "LEVEL_INTERMEDIATE": return "Intermediate"
        case "LEVEL_BASIC": return "Basic"
        default: return raw
        }
    }

    private static func percent(limit: Double, remaining: Double) -> Double {
        (limit - remaining) / limit * 100
    }

    /// The Window length in seconds, when the time unit is known.
    private static func seconds(duration: Double, unit: String?) -> TimeInterval? {
        switch unit {
        case "TIME_UNIT_MINUTE": duration * 60
        case "TIME_UNIT_HOUR": duration * 3_600
        case "TIME_UNIT_DAY": duration * 86_400
        default: nil
        }
    }

    private static func totalMinutes(duration: Double, unit: String?) -> Double? {
        seconds(duration: duration, unit: unit).map { $0 / 60 }
    }

    private static func displayUnit(_ unit: String) -> String {
        switch unit {
        case "TIME_UNIT_MINUTE": "minute"
        case "TIME_UNIT_HOUR": "hour"
        case "TIME_UNIT_DAY": "day"
        default: unit
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let date = HTTP.date(trimmed) { return date }
            if let seconds = Double(trimmed) { return Date(timeIntervalSince1970: normalizedEpoch(seconds)) }
            return nil
        }
        guard let seconds = number(value) else { return nil }
        return Date(timeIntervalSince1970: normalizedEpoch(seconds))
    }

    /// Kimi reports seconds; tolerate a millisecond timestamp just in case.
    private static func normalizedEpoch(_ value: Double) -> Double {
        value > 10_000_000_000 ? value / 1000 : value
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
