import Foundation

/// "Sign in with Nous Portal": the Hermes Agent device-code flow (RFC 8628, ADR 0003).
/// The portal is an OpenID Provider, so error responses follow RFC 6749 §5.2: a JSON object
/// `{"error": "<code>", "error_description": "…"}` with HTTP 400.
struct NousDeviceCodeFlow: DeviceCodeFlow {
    struct Pending: Equatable, Sendable {
        var deviceCode: String
        /// Seconds between polls; raised by 1 s on every `slow_down`, capped.
        var interval: TimeInterval
    }

    /// `slow_down` raises the interval by this much (RFC 8628 §3.5).
    static let slowDownStep: TimeInterval = 1
    /// The interval never grows beyond this.
    static let intervalCap: TimeInterval = 30
    /// Non-JSON 408/429/5xx back off no longer than this (without `Retry-After`).
    static let backOffCap: TimeInterval = 60

    var auth = NousAuth.live

    /// Step 1: `POST /api/oauth/device/code` with `client_id=hermes-cli`, `scope=inference:invoke`.
    func requestCode(session: URLSession, now: Date) async
        -> Result<DeviceCodeChallenge<Pending>, DeviceCodeFailure> {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("api/oauth/device/code"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody([("client_id", NousAuth.clientID), ("scope", NousAuth.scope)])

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

    /// Step 3: polls `POST /api/oauth/token` with the device grant every `interval` seconds until
    /// the code expires. `authorization_pending` keeps polling; `slow_down` raises the interval by
    /// 1 s (cap 30 s); non-JSON 408/429/5xx back off (`Retry-After`, cap 60 s).
    func awaitApproval(_ challenge: DeviceCodeChallenge<Pending>, session: URLSession, clock: PollClock) async
        -> Result<NousCredentials, DeviceCodeFailure> {
        let pending = challenge.pending
        let request = tokenRequest([
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("client_id", NousAuth.clientID),
            ("device_code", pending.deviceCode),
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
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(NousAuth.TokenResponse.self, from: data),
                      let accessToken = body.access_token, let refreshToken = body.refresh_token else {
                    return .failure(.unavailable("Unexpected response"))
                }
                coreLog.info("Nous sign-in approved")
                return .success(NousCredentials(accessToken: accessToken, refreshToken: refreshToken))
            case 400:
                // RFC 6749 §5.2: the error code decides; `error_description` carries the words.
                switch HTTP.errorCode(data) {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval = min(interval + Self.slowDownStep, Self.intervalCap)
                    continue
                case .some:
                    return .failure(.refused(HTTP.serverMessage(data) ?? HTTP.statusMessage(response.statusCode)))
                case nil:
                    // No error field: fall back to the server's text, else treat as refused.
                    if let message = HTTP.serverMessage(data) { return .failure(.refused(message)) }
                    return .failure(.unavailable("Unexpected response"))
                }
            case let status where [408, 429].contains(status) || status >= 500:
                if !HTTP.isJSON(data) {
                    // Edge back-off, honouring `Retry-After` but never beyond `backOffCap`.
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
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody(fields)
        return request
    }

    private static func isJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
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
}

/// A JSON number-or-string number: `900` or `"900"`.
struct FlexibleSeconds: Decodable, Sendable {
    var value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self), let double = TimeInterval(string) {
            value = double
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number or numeric string")
        }
    }
}