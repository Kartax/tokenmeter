import Foundation

/// Venice.ai: an API key pasted in Settings, stored in TokenMeter's Keychain item.
struct VeniceCredentials: Codable, Equatable, Sendable {
    var apiKey: String
}

/// Reads `GET /api/v1/billing/balance`. Venice funds inference from staked DIEM first (1 DIEM
/// = $1 per epoch, refreshed at 00:00 UTC), then bundled credits, then USD, then earned credits.
/// See https://docs.venice.ai/api-reference/endpoint/billing/balance
struct VeniceProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.venice.ai/api/v1")!
    static let loginHint = "Check API key"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_VENICE_BASE_URL` override).
    static let live = VeniceProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_VENICE_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<VeniceCredentials>(missingHint: loginHint)

    var baseURL: URL = VeniceProvider.defaultBaseURL

    func read(account: Account, credentials: VeniceCredentials, session: URLSession, now: Date) async
        -> ProviderReading<VeniceCredentials> {
        var request = URLRequest(url: baseURL.appendingPathComponent("billing/balance"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let body = try? JSONDecoder().decode(BalanceResponse.self, from: data),
                          let balances = body.balances else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    let mapped = Self.map(balances, consumptionCurrency: body.consumptionCurrency,
                                          epochAllocation: body.diemEpochAllocation, now: now)
                    return .success(Reading(accountID: account.id, takenAt: now, plan: nil, identity: nil,
                                            quotas: mapped.quotas, credits: mapped.credits))
                case 401, 403:
                    return .failure(.loginExpired(hint: Self.loginHint))
                case 429:
                    return .failure(.rateLimited(retryAfter: HTTP.retryAfter(response, now: now)))
                default:
                    return .failure(.unavailable(HTTP.statusMessage(response.statusCode)))
                }
            }
        return ProviderReading(result)
    }

    // MARK: - Mapping

    /// A DIEM epoch quota when the Account stakes DIEM, plus one CreditBalance per reported
    /// balance. `isMain` marks what the next request will charge (DIEM, then the active credit);
    /// the rest stay visible under "Show all Windows".
    static func map(_ balances: BalanceResponse.Balances, consumptionCurrency: String?,
                    epochAllocation: Decimal?, now: Date) -> (quotas: [Quota], credits: [CreditBalance]) {
        var quotas: [Quota] = []
        var credits: [CreditBalance] = []

        if let allocation = epochAllocation, allocation > 0, let remaining = balances.diem {
            let allocationValue = NSDecimalNumber(decimal: allocation).doubleValue
            let remainingValue = NSDecimalNumber(decimal: remaining).doubleValue
            let used = (allocationValue - remainingValue) / allocationValue * 100
            quotas.append(Quota(
                window: Window(identity: .scoped("diem_epoch"), title: "Daily DIEM", isMain: true,
                               resetsAt: nextEpoch(after: now), length: 86400),
                percentUsed: used))
        }

        let active = consumptionCurrency?.uppercased()
        var mainAssigned = false
        func isMain(_ currency: String) -> Bool {
            guard active == currency else { return false }
            mainAssigned = true
            return true
        }

        // Spend order after DIEM: bundled credits, then USD; earned credits are a separate grant.
        if let bundled = balances.bundledCredits {
            credits.append(CreditBalance(id: "bundled", title: "Bundled credits", remaining: bundled,
                                         allowance: nil, currency: CreditBalance.creditsUnit,
                                         renewsAt: nil, isMain: isMain("BUNDLED_CREDITS")))
        }
        if let earned = balances.earnedCredits {
            credits.append(CreditBalance(id: "earned", title: "Earned credits", remaining: earned,
                                         allowance: nil, currency: CreditBalance.creditsUnit,
                                         renewsAt: nil, isMain: isMain("EARNED_CREDITS")))
        }
        if let usd = balances.usd {
            credits.append(CreditBalance(id: "usd", title: "USD credits", remaining: usd,
                                         allowance: nil, currency: "USD",
                                         renewsAt: nil, isMain: isMain("USD")))
        }

        // Without DIEM, an unmatched consumption currency still gets one main balance to show.
        if !mainAssigned, quotas.isEmpty, let first = credits.indices.first {
            credits[first].isMain = true
        }
        return (quotas, credits)
    }

    /// The next 00:00 UTC, when Venice refreshes the DIEM epoch.
    private static func nextEpoch(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    }

    struct BalanceResponse: Decodable {
        var canConsume: Bool?
        var consumptionCurrency: String?
        var balances: Balances?
        var diemEpochAllocation: Decimal?

        struct Balances: Decodable {
            var diem: Decimal?
            var usd: Decimal?
            var bundledCredits: Decimal?
            var earnedCredits: Decimal?
        }
    }
}
