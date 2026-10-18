import Foundation

/// Nous Portal: reads `GET /api/oauth/account` with TokenMeter's own Nous tokens.
/// Mapping per spec #1: monthly Credit balance (main), purchased credits (non-main), Plan and
/// identity. Money arrives as a number or a decimal string; a missing field is never zero, and a
/// rolled-over balance (remaining > monthly) gets no percent — a Credit balance cannot carry one.
struct NousProvider: Provider {
    static let defaultBaseURL = URL(string: "https://portal.nousresearch.com")!
    static let loginHint = "Sign in again"
    /// Refresh the access token when it expires within this many seconds.
    static let refreshMargin: TimeInterval = 300

    /// The instance the app uses. DEBUG `TOKENMETER_NOUS_BASE_URL` points both the account and
    /// the token endpoints at one local stub server.
    static let live: NousProvider = {
        let debug = ProviderRegistry.debugBaseURL("TOKENMETER_NOUS_BASE_URL")
        return NousProvider(baseURL: debug ?? defaultBaseURL, auth: .live)
    }()
    static let credentialSource = KeychainCredentialSource<NousCredentials>(missingHint: loginHint)

    var baseURL: URL = NousProvider.defaultBaseURL
    var auth = NousAuth()

    func read(account: Account, credentials: NousCredentials, session: URLSession, now: Date) async
        -> ProviderReading<NousCredentials> {
        await read(account: account, credentials: credentials, session: session, now: now, persist: { _ in })
    }

    /// Refreshes first when the access token's `exp` is near, and once more on a 401. Rotated
    /// tokens go to `persist` before they are used.
    func read(account: Account, credentials: NousCredentials, session: URLSession, now: Date,
              persist: @Sendable (NousCredentials) -> Void) async -> ProviderReading<NousCredentials> {
        var current = credentials
        var rotated: NousCredentials?
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

        var accountResponse = await fetchAccount(current, session: session, now: now)
        if case .failure(.loginExpired) = accountResponse, rotated == nil {
            switch await auth.refresh(current, session: session, now: now) {
            case .success(let new):
                persist(new)
                (current, rotated) = (new, new)
                accountResponse = await fetchAccount(current, session: session, now: now)
            case .failure(let failure):
                return ProviderReading(.failure(failure))
            }
        }
        let outcome = accountResponse.flatMap { response -> Result<Reading, ReadingFailure> in
            if let reading = Self.reading(from: response, accountID: account.id, takenAt: now) {
                return .success(reading)
            }
            return .failure(.unavailable("Unexpected response"))
        }
        return ProviderReading(outcome, rotatedCredentials: rotated)
    }

    // MARK: - /api/oauth/account

    private func fetchAccount(_ credentials: NousCredentials, session: URLSession, now: Date) async
        -> Result<AccountResponse, ReadingFailure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/oauth/account"))
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(AccountResponse.self, from: data) else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return .success(body)
            case 401, 403:
                // A 403 from a Vercel security checkpoint is edge trouble, not a dead grant.
                if response.statusCode == 403, HTTP.errorCode(data) == nil, !HTTP.isJSON(data) {
                    return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
                }
                return .failure(.loginExpired(hint: Self.loginHint))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    // MARK: - Mapping (tolerant: every field optional, malformed parts skipped)

    static func reading(from body: AccountResponse, accountID: UUID, takenAt: Date) -> Reading? {
        var credits: [CreditBalance] = []
        if let monthly = body.subscription?.mainCreditBalance {
            credits.append(monthly)
        }
        if let purchased = body.purchasedCreditBalance {
            credits.append(purchased)
        }
        guard !credits.isEmpty else { return nil } // "Unexpected response", not all-zero

        let identity = [body.user?.email, body.organisation?.name].compactMap { $0 }.first { !$0.isEmpty }
        let plan = [body.subscription?.plan, body.subscription?.tier].compactMap { $0 }.first { !$0.isEmpty }
        return Reading(accountID: accountID, takenAt: takenAt, plan: plan, identity: identity,
                       quotas: [], credits: credits)
    }
}