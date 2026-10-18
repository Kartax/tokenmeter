import Foundation

/// ChatGPT OAuth endpoints used by the Codex CLI (ADR 0003): device-code sign-in and refresh.
struct CodexAuth: Sendable {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let defaultBaseURL = URL(string: "https://auth.openai.com")!
    /// Refresh error codes meaning the grant is dead and only a new sign-in helps.
    static let deadGrantCodes: Set<String> = [
        "invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
    ]

    /// Honours the DEBUG `TOKENMETER_CODEX_BASE_URL` override (see `CodexProvider.live`).
    static let live = CodexAuth(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_CODEX_BASE_URL") ?? defaultBaseURL)

    var baseURL: URL = CodexAuth.defaultBaseURL

    // MARK: - Refresh

    /// Exchanges the refresh token for new tokens (fields the server omits keep their old value).
    /// A rejected grant is `.loginExpired("Sign in again")`; anything else keeps the old credentials.
    func refresh(_ credentials: CodexCredentials, session: URLSession, now: Date) async
        -> Result<CodexCredentials, ReadingFailure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The ChatGPT refresh takes JSON (as the Codex CLI sends it), unlike the code exchange.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email",
        ])
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
                      let accessToken = tokens.access_token else {
                    return .failure(.unavailable("Unexpected response"))
                }
                coreLog.info("Codex tokens refreshed")
                return .success(CodexCredentials(accessToken: accessToken,
                                                 refreshToken: tokens.refresh_token ?? credentials.refreshToken,
                                                 idToken: tokens.id_token ?? credentials.idToken))
            case 400, 401:
                coreLog.notice("Codex refresh rejected (\(response.statusCode), \(HTTP.errorCode(data) ?? "no code", privacy: .public))")
                return .failure(.loginExpired(hint: CodexProvider.loginHint))
            case 403 where HTTP.errorCode(data).map(Self.deadGrantCodes.contains) == true:
                return .failure(.loginExpired(hint: CodexProvider.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var id_token: String?
    }
}
