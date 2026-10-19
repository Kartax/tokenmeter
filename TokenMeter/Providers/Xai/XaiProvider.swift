import Foundation

/// xAI: a Management API key plus the team ID, pasted in Settings and stored in TokenMeter's
/// Keychain item. Inference API keys are rejected by the Management API.
struct XaiCredentials: Codable, Equatable, Sendable {
    var apiKey: String
    var teamID: String
}

/// Reads the xAI Management API billing endpoints:
///
/// - `GET /v1/billing/teams/{teamID}/prepaid/balance` (required): prepaid credit. The ledger is
///   inverted — a $10 top-up is `"-1000"` — so remaining USD is `-Decimal(total.val) / 100`.
/// - `GET /v1/billing/teams/{teamID}/postpaid/invoice/preview` (best effort): postpaid spending
///   limit and current invoice amount, when both are present.
///
/// See https://docs.x.ai/docs/management-api/billing
struct XaiProvider: Provider {
    static let defaultBaseURL = URL(string: "https://management-api.x.ai")!
    static let loginHint = "Use a Management API key"
    static let teamNotFoundMessage = "Team ID not found — check the xAI team ID"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_XAI_BASE_URL` override).
    static let live = XaiProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_XAI_BASE_URL")
                                      ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<XaiCredentials>(missingHint: loginHint)

    var baseURL: URL = XaiProvider.defaultBaseURL

    func read(account: Account, credentials: XaiCredentials, session: URLSession, now: Date) async
        -> ProviderReading<XaiCredentials> {
        let teamID = credentials.teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTeamID(teamID) else {
            return ProviderReading(.failure(.unavailable(Self.teamNotFoundMessage)))
        }

        let prepaid = await fetchPrepaid(teamID: teamID, key: credentials.apiKey, session: session, now: now)
        switch prepaid {
        case .failure(let failure):
            return ProviderReading(.failure(failure))
        case .success(let prepaidBalance):
            var credits = [prepaidBalance]
            // The preview is enrichment only: any failure leaves the posted prepaid balance alone.
            if let postpaid = await fetchPostpaid(teamID: teamID, key: credentials.apiKey, session: session) {
                credits.append(postpaid)
            }
            return ProviderReading(.success(Reading(
                accountID: account.id, takenAt: now, plan: nil, identity: nil, quotas: [], credits: credits)))
        }
    }

    // MARK: - Requests

    private func fetchPrepaid(teamID: String, key: String, session: URLSession, now: Date) async
        -> Result<CreditBalance, ReadingFailure> {
        let request = request(teamID: teamID, path: ["prepaid", "balance"], key: key)
        return await HTTP.send(request, session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(BalanceResponse.self, from: data),
                      let balance = Self.prepaidBalance(body) else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return .success(balance)
            case 401, 403:
                return .failure(.loginExpired(hint: Self.loginHint))
            case 404:
                return .failure(.unavailable(Self.teamNotFoundMessage))
            case 429:
                return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
            default:
                return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
            }
        }
    }

    /// Nil when the preview is missing, failed, or does not report both values; never fabricates.
    private func fetchPostpaid(teamID: String, key: String, session: URLSession) async -> CreditBalance? {
        let request = request(teamID: teamID, path: ["postpaid", "invoice", "preview"], key: key)
        guard case .success(let (data, response)) = await HTTP.send(request, session: session),
              (200..<300).contains(response.statusCode),
              let body = try? JSONDecoder().decode(InvoicePreviewResponse.self, from: data) else {
            return nil
        }
        return Self.postpaidBalance(body)
    }

    private func request(teamID: String, path: [String], key: String) -> URLRequest {
        var url = baseURL.appendingPathComponent("v1")
            .appendingPathComponent("billing")
            .appendingPathComponent("teams")
            .appendingPathComponent(teamID)
        for component in path {
            url = url.appendingPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Mapping

    /// Prepaid credit from the inverted ledger. A body without a parseable `total.val` fails
    /// instead of reading as $0.
    static func prepaidBalance(_ body: BalanceResponse) -> CreditBalance? {
        guard let total = body.total, let cents = decimalCents(total.val) else { return nil }
        return CreditBalance(id: "prepaid", title: "Prepaid credits", remaining: -cents / 100,
                             allowance: nil, currency: "USD", renewsAt: nil, isMain: true)
    }

    /// Postpaid limit minus the current invoice preview, when both cent amounts parse.
    static func postpaidBalance(_ body: InvoicePreviewResponse) -> CreditBalance? {
        let limitValue = body.effectiveSpendingLimit ?? body.coreInvoice?.effectiveSpendingLimit
        guard let amount = decimalCents(body.coreInvoice?.amountAfterVat?.raw),
              let limit = decimalCents(limitValue?.raw) else { return nil }
        return CreditBalance(id: "postpaid", title: "Postpaid remaining",
                             remaining: (limit - amount) / 100, allowance: limit / 100,
                             currency: "USD", renewsAt: nil, isMain: false)
    }

    /// A team ID is one path component, so a stray `/` can never move the request to another route.
    static func isValidTeamID(_ teamID: String) -> Bool {
        !teamID.isEmpty && teamID != "." && teamID != ".." && !teamID.contains("/")
    }

    /// Parses a USD-cent amount, rejecting junk instead of treating it as zero.
    private static func decimalCents(_ value: String?) -> Decimal? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Wire types

    struct BalanceResponse: Decodable {
        var total: Total?

        struct Total: Decodable {
            var val: String
        }
    }

    struct InvoicePreviewResponse: Decodable {
        var coreInvoice: CoreInvoice?
        var effectiveSpendingLimit: CentsValue?

        struct CoreInvoice: Decodable {
            var amountAfterVat: CentsValue?
            /// Some responses nest the limit inside the invoice; accepted as a fallback.
            var effectiveSpendingLimit: CentsValue?
        }
    }

    /// A cent amount that may arrive as a string, a number, or `{"val": "…"}`.
    struct CentsValue: Decodable {
        var raw: String

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode(String.self) {
                raw = value
            } else if let value = try? single.decode(Int64.self) {
                raw = String(value)
            } else if let value = try? single.decode(Decimal.self) {
                raw = NSDecimalNumber(decimal: value).stringValue
            } else {
                raw = try decoder.container(keyedBy: ValKey.self).decode(String.self, forKey: .val)
            }
        }

        private enum ValKey: CodingKey { case val }
    }
}
