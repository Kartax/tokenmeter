import Foundation

/// "Sign in with ChatGPT": the Codex CLI's device-code flow (ADR 0003, spec #1 Codex contract).
struct CodexDeviceCodeFlow: DeviceCodeFlow {
    /// The CLI gives up after 15 minutes; used when the server sends no `expires_at`.
    static let codeLifetime: TimeInterval = 15 * 60
    static let redirectURI = "https://auth.openai.com/deviceauth/callback"

    struct Pending: Equatable, Sendable {
        var deviceAuthID: String
        var userCode: String
        /// Seconds between polls.
        var interval: TimeInterval
    }

    var auth: CodexAuth = .live

    /// Step 1: `POST /api/accounts/deviceauth/usercode`; the user enters the code at `/codex/device`.
    func requestCode(session: URLSession, now: Date) async -> Result<DeviceCodeChallenge<Pending>, DeviceCodeFailure> {
        let request = jsonRequest("api/accounts/deviceauth/usercode", ["client_id": CodexAuth.clientID])
        switch await HTTP.send(request, session: session) {
        case .failure(let failure):
            return .failure(.unavailable(failure.message))
        case .success(let (data, response)):
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.refused(HTTP.serverMessage(data) ?? HTTP.statusMessage(response.statusCode)))
            }
            guard let body = try? JSONDecoder().decode(UserCodeResponse.self, from: data),
                  let deviceAuthID = body.device_auth_id, let userCode = body.user_code ?? body.usercode else {
                return .failure(.unavailable("Unexpected response"))
            }
            let code = DeviceCode(userCode: userCode,
                                  verificationURL: auth.baseURL.appendingPathComponent("codex/device"),
                                  expiresAt: HTTP.date(body.expires_at) ?? now.addingTimeInterval(Self.codeLifetime))
            let interval = max(1, body.interval ?? 5)
            return .success(DeviceCodeChallenge(code: code, pending: Pending(deviceAuthID: deviceAuthID,
                                                                             userCode: userCode, interval: interval)))
        }
    }

    /// Steps 3–4: polls `POST /api/accounts/deviceauth/token` every `interval` seconds (403/404 mean
    /// "not approved yet"), then exchanges the authorization code at `/oauth/token`.
    func awaitApproval(_ challenge: DeviceCodeChallenge<Pending>, session: URLSession, clock: PollClock) async
        -> Result<CodexCredentials, DeviceCodeFailure> {
        let pending = challenge.pending
        let request = jsonRequest("api/accounts/deviceauth/token",
                                  ["device_auth_id": pending.deviceAuthID, "user_code": pending.userCode])
        while true {
            do {
                try await clock.sleep(pending.interval)
            } catch {
                return .failure(.cancelled)
            }
            guard clock.now() < challenge.code.expiresAt else { return .failure(.expired) }

            let result = await HTTP.send(request, session: session)
            if Task.isCancelled { return .failure(.cancelled) }
            guard case .success(let (data, response)) = result else {
                continue // A network blip; keep polling until the code expires.
            }
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(AuthorizationResponse.self, from: data),
                      let code = body.authorization_code, let verifier = body.code_verifier else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return await exchange(code: code, verifier: verifier, session: session)
            case 403, 404:
                continue
            default:
                return .failure(.refused(HTTP.serverMessage(data) ?? HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    /// Authorization-code grant with the PKCE verifier from the device-auth server.
    private func exchange(code: String, verifier: String, session: URLSession) async
        -> Result<CodexCredentials, DeviceCodeFailure> {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody([
            ("grant_type", "authorization_code"),
            ("client_id", CodexAuth.clientID),
            ("code", code),
            ("redirect_uri", Self.redirectURI),
            ("code_verifier", verifier),
        ])
        switch await HTTP.send(request, session: session) {
        case .failure(let failure):
            return .failure(.unavailable(failure.message))
        case .success(let (data, response)):
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.refused(HTTP.serverMessage(data) ?? HTTP.statusMessage(response.statusCode)))
            }
            guard let tokens = try? JSONDecoder().decode(CodexAuth.TokenResponse.self, from: data),
                  let accessToken = tokens.access_token, let refreshToken = tokens.refresh_token else {
                return .failure(.unavailable("Unexpected response"))
            }
            coreLog.info("Codex sign-in approved")
            return .success(CodexCredentials(accessToken: accessToken, refreshToken: refreshToken,
                                             idToken: tokens.id_token ?? ""))
        }
    }

    private func jsonRequest(_ path: String, _ body: [String: String]) -> URLRequest {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct UserCodeResponse: Decodable {
        var device_auth_id: String?
        var user_code: String?
        var usercode: String?
        /// Seconds; the server sends a string ("5"), a number is accepted too.
        var interval: TimeInterval?
        var expires_at: String?

        private enum CodingKeys: String, CodingKey { case device_auth_id, user_code, usercode, interval, expires_at }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            device_auth_id = try? c.decodeIfPresent(String.self, forKey: .device_auth_id)
            user_code = try? c.decodeIfPresent(String.self, forKey: .user_code)
            usercode = try? c.decodeIfPresent(String.self, forKey: .usercode)
            interval = (try? c.decodeIfPresent(String.self, forKey: .interval)).flatMap { $0.flatMap(TimeInterval.init) }
                ?? (try? c.decodeIfPresent(TimeInterval.self, forKey: .interval)) ?? nil
            expires_at = try? c.decodeIfPresent(String.self, forKey: .expires_at)
        }
    }

    private struct AuthorizationResponse: Decodable {
        var authorization_code: String?
        var code_verifier: String?
    }
}

extension ReadingFailure {
    /// One short line for sign-in failures (device-code sheets and their providers).
    var message: String {
        switch self {
        case .loginExpired(let hint): hint
        case .rateLimited: "Rate limited"
        case .unavailable(let message): message
        }
    }
}
