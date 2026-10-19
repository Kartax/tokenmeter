import Foundation

/// GitHub OAuth endpoints used by the Copilot clients (ADR 0003 pattern: reuse the public client ID
/// of an official client). The device flow returns a long-lived `gho_` token; TokenMeter stores it
/// and has no refresh grant.
struct CopilotAuth: Sendable {
    /// VS Code's public Copilot OAuth app, also used by other Copilot clients.
    static let clientID = "Iv1.b507a08c87ecfe98"
    static let scope = "read:user"
    static let defaultBaseURL = URL(string: "https://github.com")!

    /// Honours the DEBUG `TOKENMETER_COPILOT_BASE_URL` override (see `CopilotProvider.live`).
    static let live = CopilotAuth(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_COPILOT_BASE_URL")
                                      ?? defaultBaseURL)

    var baseURL: URL = CopilotAuth.defaultBaseURL
}

/// "Sign in with GitHub": GitHub's OAuth device flow (RFC 8628).
struct CopilotDeviceCodeFlow: DeviceCodeFlow {
    struct Pending: Equatable, Sendable {
        var deviceCode: String
        /// Seconds between polls; raised by 5 s on every `slow_down`, capped.
        var interval: TimeInterval
    }

    /// GitHub asks for 5 more seconds after `slow_down` (RFC 8628 §3.5).
    static let slowDownStep: TimeInterval = 5
    static let intervalCap: TimeInterval = 30
    /// Non-JSON 408/429/5xx back off no longer than this (without `Retry-After`).
    static let backOffCap: TimeInterval = 60

    var auth = CopilotAuth.live

    /// Step 1: `POST /login/device/code` with the Copilot client ID and `read:user` scope.
    func requestCode(session: URLSession, now: Date) async
        -> Result<DeviceCodeChallenge<Pending>, DeviceCodeFailure> {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("login/device/code"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody([("client_id", CopilotAuth.clientID), ("scope", CopilotAuth.scope)])

        switch await HTTP.send(request, session: session) {
        case .failure(let failure):
            return .failure(.unavailable(failure.message))
        case .success(let (data, response)):
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.refused(HTTP.serverMessage(data) ?? HTTP.statusMessage(response.statusCode)))
            }
            guard let body = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data),
                  let deviceCode = body.device_code, let userCode = body.user_code,
                  let verificationURL = body.verificationURL else {
                return .failure(.unavailable("Unexpected response"))
            }
            let interval = max(1, body.interval?.value ?? 5)
            return .success(DeviceCodeChallenge(
                code: DeviceCode(userCode: userCode, verificationURL: verificationURL,
                                 expiresAt: now.addingTimeInterval(body.expiresIn ?? 900)),
                pending: Pending(deviceCode: deviceCode, interval: interval)))
        }
    }

    /// Step 3: polls `POST /login/oauth/access_token` until the user approves the code. GitHub
    /// reports `authorization_pending`, `slow_down`, `expired_token` and `access_denied` as JSON on
    /// both 200 and 400 responses.
    func awaitApproval(_ challenge: DeviceCodeChallenge<Pending>, session: URLSession, clock: PollClock) async
        -> Result<CopilotCredentials, DeviceCodeFailure> {
        let pending = challenge.pending
        let request = tokenRequest([
            ("client_id", CopilotAuth.clientID),
            ("device_code", pending.deviceCode),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
        var interval = pending.interval
        while true {
            do {
                try await clock.sleep(interval)
            } catch {
                return .failure(.cancelled)
            }
            guard clock.now() < challenge.code.expiresAt else { return .failure(.expired) }

            let result = await HTTP.send(request, session: session)
            if Task.isCancelled { return .failure(.cancelled) }
            guard case .success(let (data, response)) = result else {
                continue // A network blip; keep polling until the code expires.
            }

            if let body = try? JSONDecoder().decode(TokenResponse.self, from: data), let error = body.error {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval = min(interval + Self.slowDownStep, Self.intervalCap)
                    continue
                case "expired_token":
                    return .failure(.expired)
                case "access_denied":
                    return .failure(.refused(body.error_description ?? "Access denied."))
                default:
                    return .failure(.refused(body.error_description ?? error))
                }
            }

            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data),
                      let token = body.access_token, !token.isEmpty else {
                    return .failure(.unavailable("Unexpected response"))
                }
                coreLog.info("Copilot sign-in approved")
                return .success(CopilotCredentials(token: token))
            case let status where [408, 429].contains(status) || status >= 500:
                if !HTTP.isJSON(data) {
                    let retryAfter = HTTP.retryAfter(response, now: clock.now()).map { min($0, Self.backOffCap) }
                    do { try await clock.sleep(retryAfter ?? Self.backOffCap) } catch { return .failure(.cancelled) }
                    continue
                }
                return .failure(.refused(HTTP.serverMessage(data) ?? HTTP.statusMessage(response.statusCode)))
            default:
                return .failure(.refused(HTTP.serverMessage(data) ?? HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    private func tokenRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("login/oauth/access_token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody(fields)
        return request
    }

    private struct DeviceCodeResponse: Decodable {
        var device_code: String?
        var user_code: String?
        var verification_uri: String?
        var verification_uri_complete: String?
        var expires_in: FlexibleSeconds?
        var interval: FlexibleSeconds?

        var verificationURL: URL? {
            (verification_uri_complete ?? verification_uri).flatMap(URL.init(string:))
        }

        var expiresIn: TimeInterval { expires_in?.value ?? 900 }
    }

    private struct TokenResponse: Decodable {
        var access_token: String?
        var token_type: String?
        var scope: String?
        var error: String?
        var error_description: String?
    }
}
