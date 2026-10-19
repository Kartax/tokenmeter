import Foundation

/// Gemini CLI's OAuth login, borrowed for one fetch. Read fresh from
/// `~/.gemini/oauth_creds.json` and never written back: Gemini CLI owns the file and its refresh.
struct GeminiCredentials: Equatable, Sendable {
    /// The stored access token; empty when the file only has a refresh token.
    var accessToken: String
    var refreshToken: String?
    /// `expiry_date` from the file (milliseconds since 1970).
    var expiryDate: Date?
    /// Client credentials from the file, when present; otherwise the public Gemini CLI client is used.
    var clientID: String?
    var clientSecret: String?

    init(accessToken: String, refreshToken: String? = nil, expiryDate: Date? = nil,
         clientID: String? = nil, clientSecret: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDate = expiryDate
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

extension GeminiCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never reveals the tokens, even if the value ends up in a log or debugger print.
    var description: String {
        "GeminiCredentials(accessToken: <redacted>, refreshToken: <redacted>, "
            + "expiryDate: \(expiryDate.map { "\($0)" } ?? "nil"))"
    }

    var debugDescription: String { description }
}

/// Reads Gemini CLI's login from `~/.gemini/oauth_creds.json` on every fetch. Nothing is saved,
/// copied or deleted: the file belongs to Gemini CLI.
struct GeminiCredentialSource: CredentialSource {
    /// Gemini CLI's default credential file.
    static var credentialsPath: String { NSHomeDirectory() + "/.gemini/oauth_creds.json" }

    /// Injected so tests can point the source at a temporary directory.
    var fileURL: URL = URL(fileURLWithPath: GeminiCredentialSource.credentialsPath)

    func load(for account: Account) -> Result<GeminiCredentials, ReadingFailure> {
        guard let data = try? Data(contentsOf: fileURL),
              let credentials = GeminiCredentialSource.parse(data) else {
            return .failure(.loginExpired(hint: GeminiProvider.loginHint))
        }
        return .success(credentials)
    }

    /// Never called with rotated credentials (the Provider does not return any), and a no-op
    /// when it is: TokenMeter never writes Gemini CLI's file.
    func save(_ credentials: GeminiCredentials, for account: Account) throws {}

    /// Nothing to delete: TokenMeter stores no Gemini secret.
    func delete(for account: Account) throws {}

    /// `{"access_token", "refresh_token", "expiry_date" (ms), "client_id", "client_secret"}`.
    /// Nil when the file has neither an access token nor a refresh token.
    static func parse(_ data: Data) -> GeminiCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let accessToken = string(json["access_token"]) ?? ""
        let refreshToken = string(json["refresh_token"])
        guard !accessToken.isEmpty || refreshToken != nil else { return nil }
        return GeminiCredentials(accessToken: accessToken,
                                 refreshToken: refreshToken,
                                 expiryDate: date(milliseconds: json["expiry_date"]),
                                 clientID: string(json["client_id"]),
                                 clientSecret: string(json["client_secret"]))
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(milliseconds value: Any?) -> Date? {
        let milliseconds: Double?
        switch value {
        case let number as NSNumber: milliseconds = number.doubleValue
        case let string as String: milliseconds = Double(string)
        default: milliseconds = nil
        }
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

/// Gemini CLI quota: reads the OAuth login Gemini CLI stores, refreshes it in memory when needed,
/// then asks Google's Cloud Code Private API for the Account's plan and per-model quotas.
///
/// The login and the refresh belong to Gemini CLI; a refreshed access token is used for this
/// fetch only and is never written back to `~/.gemini/oauth_creds.json`.
struct GeminiProvider: Provider {
    static let defaultBaseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    static let defaultTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let loginHint = "Run `gemini` to sign in"

    /// The public Gemini CLI OAuth client, used when the credentials file has no client pair.
    static let publicClientID = ""
    static let publicClientSecret = ""

    /// Access tokens this close to expiry are refreshed before use.
    static let expiryBuffer: TimeInterval = 30

    /// The instance the app uses (honours the DEBUG `TOKENMETER_GEMINI_BASE_URL` override for the
    /// Cloud Code endpoints).
    static let live = GeminiProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_GEMINI_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = GeminiCredentialSource()

    var baseURL: URL
    var tokenURL: URL

    init(baseURL: URL = GeminiProvider.defaultBaseURL, tokenURL: URL = GeminiProvider.defaultTokenURL) {
        self.baseURL = baseURL
        self.tokenURL = tokenURL
    }

    func read(account: Account, credentials: GeminiCredentials, session: URLSession, now: Date) async
        -> ProviderReading<GeminiCredentials> {
        let accessToken: String
        if credentials.needsRefresh(now: now) {
            guard let refreshToken = credentials.refreshToken else {
                return ProviderReading(.failure(.loginExpired(hint: Self.loginHint)))
            }
            switch await refresh(credentials, refreshToken: refreshToken, session: session, now: now) {
            case .failure(let failure):
                return ProviderReading(.failure(failure))
            case .success(let refreshed):
                accessToken = refreshed
            }
        } else {
            accessToken = credentials.accessToken
        }

        let status: CodeAssistInfo?
        switch await loadCodeAssist(accessToken: accessToken, session: session) {
        case .failure(let failure):
            return ProviderReading(.failure(failure))
        case .success(let info):
            status = info
        }

        switch await fetchQuota(accessToken: accessToken, project: status?.project, session: session, now: now) {
        case .failure(let failure):
            return ProviderReading(.failure(failure))
        case .success(let quotas):
            return ProviderReading(.success(Reading(accountID: account.id, takenAt: now, plan: status?.plan,
                                                     identity: nil, quotas: quotas, credits: [])))
        }
    }

    // MARK: - Token refresh

    private struct RefreshResponse: Decodable {
        var accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    /// Exchanges the refresh token for an access token. The result stays in memory; Gemini CLI's
    /// credential file is never updated.
    private func refresh(_ credentials: GeminiCredentials, refreshToken: String, session: URLSession,
                         now: Date) async -> Result<String, ReadingFailure> {
        let clientID: String
        let clientSecret: String
        if let fileClientID = credentials.clientID, let fileClientSecret = credentials.clientSecret {
            clientID = fileClientID
            clientSecret = fileClientSecret
        } else {
            clientID = Self.publicClientID
            clientSecret = Self.publicClientSecret
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(RefreshResponse.self, from: data),
                      let accessToken = body.accessToken, !accessToken.isEmpty else {
                    return .failure(.loginExpired(hint: Self.loginHint))
                }
                return .success(accessToken)
            case 400, 401, 403:
                // `invalid_grant` and friends: the stored login can no longer be refreshed.
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    // MARK: - loadCodeAssist

    private struct CodeAssistInfo {
        var project: String?
        var plan: String?
    }

    /// Best effort: a missing project or plan never fails the Reading. A rejected token does,
    /// because the quota request would be rejected as well.
    private func loadCodeAssist(accessToken: String, session: URLSession) async
        -> Result<CodeAssistInfo, ReadingFailure> {
        var request = URLRequest(url: endpoint("loadCodeAssist"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        switch await HTTP.send(request, session: session) {
        case .failure:
            return .success(CodeAssistInfo())
        case .success(let (data, response)):
            switch response.statusCode {
            case 200..<300:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .success(CodeAssistInfo())
                }
                return .success(CodeAssistInfo(project: Self.project(from: json), plan: Self.plan(from: json)))
            case 401, 403:
                return .failure(.loginExpired(hint: Self.loginHint))
            default:
                return .success(CodeAssistInfo())
            }
        }
    }

    private static func project(from json: [String: Any]) -> String? {
        if let project = json["cloudaicompanionProject"] as? String {
            let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let project = json["cloudaicompanionProject"] as? [String: Any] else { return nil }
        for key in ["id", "projectId"] {
            if let value = project[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// `standard-tier` → "Standard", `free-tier` → "Free", `legacy-tier` → "Legacy"; otherwise the
    /// tier's own name.
    private static func plan(from json: [String: Any]) -> String? {
        guard let tier = json["currentTier"] as? [String: Any] else { return nil }
        if let id = tier["id"] as? String {
            switch id {
            case "free-tier": return "Free"
            case "standard-tier": return "Standard"
            case "legacy-tier": return "Legacy"
            default: break
            }
        }
        guard let name = tier["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - retrieveUserQuota

    private struct QuotaResponse: Decodable {
        struct Bucket: Decodable {
            var modelId: String?
            var remainingFraction: Double?
            var resetTime: String?
            var tokenType: String?
        }

        var quota: [Bucket]?
    }

    private func fetchQuota(accessToken: String, project: String?, session: URLSession, now: Date) async
        -> Result<[Quota], ReadingFailure> {
        var request = URLRequest(url: endpoint("retrieveUserQuota"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project ?? ""])
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let mapped = Self.mapQuota(data) else {
                    return .failure(.unavailable("Unexpected response"))
                }
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

    /// One Quota per `modelId` bucket. The bucket with the least remaining fraction is the main
    /// Window; `percentUsed = (1 - remainingFraction) × 100`. Nil for a missing, empty or malformed
    /// `quota` array.
    static func mapQuota(_ data: Data) -> [Quota]? {
        guard let response = try? JSONDecoder().decode(QuotaResponse.self, from: data),
              let buckets = response.quota, !buckets.isEmpty else { return nil }
        var parsed: [(modelID: String, percentUsed: Double, resetsAt: Date?)] = []
        for bucket in buckets {
            guard let modelID = bucket.modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !modelID.isEmpty, let fraction = bucket.remainingFraction else { return nil }
            parsed.append((modelID, (1 - fraction) * 100, HTTP.date(bucket.resetTime)))
        }
        var mainIndex = 0
        for index in parsed.indices where parsed[index].percentUsed > parsed[mainIndex].percentUsed {
            mainIndex = index
        }
        return parsed.enumerated().map { index, entry in
            Quota(window: Window(identity: .scoped(entry.modelID), title: entry.modelID,
                                 isMain: index == mainIndex, resetsAt: entry.resetsAt, length: nil),
                  percentUsed: entry.percentUsed)
        }
    }

    private func endpoint(_ method: String) -> URL {
        baseURL.appendingPathComponent("v1internal:\(method)")
    }
}

private extension GeminiCredentials {
    /// True when there is no access token or it expires within `GeminiProvider.expiryBuffer`.
    func needsRefresh(now: Date) -> Bool {
        if accessToken.isEmpty { return true }
        guard let expiryDate else { return false }
        return expiryDate <= now.addingTimeInterval(GeminiProvider.expiryBuffer)
    }
}
