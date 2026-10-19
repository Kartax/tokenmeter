import Foundation
import Security

/// Antigravity's own login, borrowed read-only from the local Antigravity CLI (ADR 0001 pattern):
/// read fresh on every fetch, held in memory only, never stored or refreshed in TokenMeter's Keychain.
struct AntigravityCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// The OAuth client pair from the token file/Keychain, when present. TokenMeter embeds none.
    var clientID: String? = nil
    var clientSecret: String? = nil
}

/// Reads Antigravity's local login: `~/.gemini/antigravity-cli/antigravity-oauth-token`, then the
/// generic-password Keychain item service `gemini`, account `antigravity`.
/// Never saves or deletes: Antigravity owns the login.
struct AntigravityCredentialSource: CredentialSource {
    static var defaultTokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    /// Injected so the file and Keychain paths can be exercised without touching either.
    var tokenFileURL: URL = AntigravityCredentialSource.defaultTokenFileURL
    var keychainItem: @Sendable (_ service: String, _ account: String) throws -> Data? =
        AntigravityCredentialSource.readKeychainItem

    func load(for account: Account) -> Result<AntigravityCredentials, ReadingFailure> {
        if let data = FileManager.default.contents(atPath: tokenFileURL.path),
           let credentials = Self.parse(data) {
            return .success(credentials)
        }
        do {
            if let data = try keychainItem("gemini", "antigravity"),
               let credentials = Self.decodeKeychainValue(data) {
                return .success(credentials)
            }
        } catch let failure as KeychainStore.Failure
            where failure.status == errSecAuthFailed || failure.status == errSecUserCanceled {
            return .failure(.unavailable("Keychain access denied — allow TokenMeter in the prompt"))
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
        return .failure(.loginExpired(hint: AntigravityProvider.loginHint))
    }

    /// Never called: Antigravity credentials are borrowed and never rotated by TokenMeter.
    func save(_ credentials: AntigravityCredentials, for account: Account) throws {}

    /// Nothing to delete: Antigravity owns its login and TokenMeter stores no Antigravity secret.
    func delete(for account: Account) throws {}

    /// Accepts both Antigravity CLI's `{"token":{"access_token","refresh_token","expiry"}}` file
    /// and a flat `{"access_token","refresh_token","expires_at"}` object.
    static func parse(_ data: Data) -> AntigravityCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credentials = credentials(from: object) else { return nil }
        return credentials
    }

    static func credentials(from object: [String: Any]) -> AntigravityCredentials? {
        let token = object["token"] as? [String: Any] ?? object
        guard let accessToken = string(token["access_token"]) ?? string(token["accessToken"]) else {
            return nil
        }
        let refreshToken = string(token["refresh_token"]) ?? string(token["refreshToken"])
        let expiry = token["expiry"] ?? token["expires_at"] ?? token["expiry_date"]
            ?? token["expiresAt"] ?? token["expiryDate"]
        return AntigravityCredentials(accessToken: accessToken, refreshToken: refreshToken,
                                      expiresAt: date(from: expiry),
                                      clientID: string(token["client_id"]) ?? string(token["clientId"]),
                                      clientSecret: string(token["client_secret"]) ?? string(token["clientSecret"]))
    }

    /// Keychain values may be raw JSON, a `go-keyring-base64:` wrapper, or bare base64 JSON.
    static func decodeKeychainValue(_ data: Data) -> AntigravityCredentials? {
        if let credentials = parse(data) { return credentials }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let payload: String
        if text.hasPrefix("go-keyring-base64:") {
            payload = String(text.dropFirst("go-keyring-base64:".count))
        } else {
            payload = text
        }
        guard let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        return parse(decoded)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Seconds or milliseconds since 1970, or an ISO 8601 string.
    private static func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return date(seconds: number.doubleValue)
        }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) { return date(seconds: seconds) }
        return HTTP.date(trimmed)
    }

    private static func date(seconds: Double) -> Date? {
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
    }

    /// The first time, macOS asks whether TokenMeter may use Antigravity's item.
    @Sendable static func readKeychainItem(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainStore.Failure(status: status)
        }
    }
}

/// Google Antigravity: per-model quotas from the borrowed local Antigravity login.
/// `POST /v1internal:fetchAvailableModels` (required), `POST /v1internal:loadCodeAssist`
/// (Plan, best effort). OAuth access tokens are refreshed in memory; nothing is persisted.
struct AntigravityProvider: Provider {
    static let defaultBaseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    static let defaultTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let loginHint = "Open Antigravity or run `agy login`"

    private static let clientMetadata = #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#

    /// The instance the app uses (honours the DEBUG `TOKENMETER_ANTIGRAVITY_BASE_URL` override).
    static let live = AntigravityProvider(
        baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_ANTIGRAVITY_BASE_URL") ?? defaultBaseURL)
    static let credentialSource = AntigravityCredentialSource()

    var baseURL: URL = AntigravityProvider.defaultBaseURL
    var tokenURL: URL = AntigravityProvider.defaultTokenURL

    func read(account: Account, credentials: AntigravityCredentials, session: URLSession, now: Date) async
        -> ProviderReading<AntigravityCredentials> {
        var credentials = credentials
        if credentials.accessToken.isEmpty || Self.isExpired(credentials.expiresAt, now: now) {
            guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty,
                  let clientID = credentials.clientID, let clientSecret = credentials.clientSecret else {
                return ProviderReading(.failure(.loginExpired(hint: Self.loginHint)))
            }
            switch await refresh(credentials: credentials, refreshToken: refreshToken,
                                 clientID: clientID, clientSecret: clientSecret,
                                 session: session, now: now) {
            case .success(let refreshed):
                credentials = refreshed
            case .failure(let failure):
                return ProviderReading(.failure(failure))
            }
        }

        let request = cloudRequest(path: "v1internal:fetchAvailableModels",
                                   accessToken: credentials.accessToken)
        switch await HTTP.send(request, session: session) {
        case .failure(let failure):
            return ProviderReading(.failure(failure))
        case .success(let (data, response)):
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
                    return ProviderReading(.failure(.unavailable("Unexpected response")))
                }
                let quotas = Self.map(body.models ?? [:])
                guard !quotas.isEmpty else {
                    return ProviderReading(.failure(.unavailable("No Antigravity models returned")))
                }
                let plan = await fetchPlan(accessToken: credentials.accessToken, session: session)
                return ProviderReading(.success(Reading(accountID: account.id, takenAt: now, plan: plan,
                                                        identity: nil, quotas: quotas, credits: [])))
            case 401, 403:
                return ProviderReading(.failure(.loginExpired(hint: Self.loginHint)))
            case 429:
                return ProviderReading(.failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now))))
            default:
                return ProviderReading(.failure(.unavailable(HTTP.statusMessage(response.statusCode))))
            }
        }
    }

    // MARK: - OAuth refresh (in memory only)

    private static func isExpired(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return date <= now.addingTimeInterval(30)
    }

    private func refresh(credentials: AntigravityCredentials, refreshToken: String,
                         clientID: String, clientSecret: String,
                         session: URLSession, now: Date) async
        -> Result<AntigravityCredentials, ReadingFailure> {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.formBody([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("refresh_token", refreshToken),
        ])
        switch await HTTP.send(request, session: session) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let (data, response)):
            switch response.statusCode {
            case 200..<300:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
                    return .failure(.unavailable("Unexpected response"))
                }
                var refreshed = credentials
                refreshed.accessToken = accessToken
                if let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 {
                    refreshed.expiresAt = now.addingTimeInterval(expiresIn)
                } else {
                    refreshed.expiresAt = nil
                }
                if let rotated = object["refresh_token"] as? String, !rotated.isEmpty {
                    refreshed.refreshToken = rotated
                }
                return .success(refreshed)
            case 401, 403:
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    // MARK: - Requests

    private func cloudRequest(path: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.clientMetadata, forHTTPHeaderField: "Client-Metadata")
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// Plan display name from `currentTier`; any failure yields nil and never fails the Reading.
    private func fetchPlan(accessToken: String, session: URLSession) async -> String? {
        let request = cloudRequest(path: "v1internal:loadCodeAssist", accessToken: accessToken)
        guard case .success(let (data, response)) = await HTTP.send(request, session: session),
              (200..<300).contains(response.statusCode),
              let body = try? JSONDecoder().decode(CodeAssistResponse.self, from: data),
              let tier = body.currentTier else {
            return nil
        }
        let names = [tier.name, tier.id].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return names.first { !$0.isEmpty }
    }

    // MARK: - Mapping

    /// One `scoped(model id)` Window per model with a quota; the most-used model is main.
    static func map(_ models: [String: RemoteModel]) -> [Quota] {
        var quotas: [Quota] = []
        for (modelID, model) in models {
            guard model.isInternal != true,
                  let title = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let quotaInfo = model.quotaInfo,
                  let remaining = quotaInfo.remainingFraction else { continue }
            let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            quotas.append(Quota(
                window: Window(identity: .scoped(id.isEmpty ? title : id), title: title, isMain: false,
                               resetsAt: resetDate(quotaInfo.resetTime), length: nil),
                percentUsed: (1 - remaining) * 100))
        }
        quotas.sort {
            let order = $0.window.title.localizedCaseInsensitiveCompare($1.window.title)
            if order == .orderedSame {
                return $0.window.identityID < $1.window.identityID
            }
            return order == .orderedAscending
        }
        if let index = quotas.indices.max(by: { quotas[$0].percentUsed < quotas[$1].percentUsed }) {
            quotas[index].window.isMain = true
        }
        return quotas
    }

    private static func resetDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        return HTTP.date(value)
    }

    // MARK: - Response bodies

    private struct ModelsResponse: Decodable {
        let models: [String: RemoteModel]?
    }

    struct RemoteModel: Decodable {
        let displayName: String?
        let quotaInfo: ModelQuotaInfo?
        let isInternal: Bool?
    }

    struct ModelQuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?

        private enum CodingKeys: String, CodingKey {
            case remainingFraction, resetTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                remainingFraction = value
            } else if let value = try? container.decodeIfPresent(String.self, forKey: .remainingFraction) {
                remainingFraction = Double(value)
            } else {
                remainingFraction = nil
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: .resetTime) {
                resetTime = value
            } else if let value = try? container.decodeIfPresent(Double.self, forKey: .resetTime) {
                resetTime = String(value)
            } else {
                resetTime = nil
            }
        }
    }

    private struct CodeAssistResponse: Decodable {
        let currentTier: Tier?

        struct Tier: Decodable {
            let id: String?
            let name: String?
        }
    }
}

private extension Window {
    /// Stable tie-breaker for model names that differ only in case.
    var identityID: String {
        switch identity {
        case .session, .week, .month: return ""
        case .scoped(let id): return id
        }
    }
}
