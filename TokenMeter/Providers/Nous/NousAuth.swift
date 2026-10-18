import Foundation

/// Nous Portal OAuth endpoints used by Hermes Agent (RFC 8628, ADR 0003): device-code sign-in
/// and refresh. Unlike a conventional token request, the refresh token rides in the
/// `x-nous-refresh-token` header, not the form body.
struct NousAuth: Sendable {
    static let clientID = "hermes-cli"
    static let scope = "inference:invoke"
    static let defaultBaseURL = URL(string: "https://portal.nousresearch.com")!
    /// Refresh error codes meaning the single-use grant is dead and only a new sign-in helps.
    static let deadGrantCodes: Set<String> = ["invalid_grant", "invalid_token", "refresh_token_reused"]

    /// Honours the DEBUG `TOKENMETER_NOUS_BASE_URL` override (see `NousProvider.live`).
    static let live = NousAuth(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_NOUS_BASE_URL") ?? defaultBaseURL)

    var baseURL: URL = NousAuth.defaultBaseURL

    // MARK: - Refresh

    /// Exchanges the refresh token for the rotated pair (an omitted `refresh_token` keeps the old
    /// one). A dead grant is `.loginExpired("Sign in again")`; anything else keeps the credentials.
    func refresh(_ credentials: NousCredentials, session: URLSession, now: Date) async
        -> Result<NousCredentials, ReadingFailure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.refreshToken, forHTTPHeaderField: "x-nous-refresh-token")
        request.httpBody = HTTP.formBody([
            ("grant_type", "refresh_token"),
            ("client_id", Self.clientID),
        ])
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
                      let accessToken = tokens.access_token else {
                    return .failure(.unavailable("Unexpected response"))
                }
                coreLog.info("Nous tokens refreshed")
                return .success(NousCredentials(accessToken: accessToken,
                                                refreshToken: tokens.refresh_token ?? credentials.refreshToken))
            case 400, 401:
                coreLog.notice("Nous refresh rejected (\(response.statusCode), \(HTTP.errorCode(data) ?? "no code", privacy: .public))")
                return .failure(.loginExpired(hint: NousProvider.loginHint))
            case 403 where HTTP.errorCode(data).map(Self.deadGrantCodes.contains) == true:
                return .failure(.loginExpired(hint: NousProvider.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                // A Vercel security checkpoint (non-JSON 403/429) or 5xx is edge trouble, not a
                // dead grant: keep the credentials.
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var expires_in: FlexibleSeconds?
    }
}