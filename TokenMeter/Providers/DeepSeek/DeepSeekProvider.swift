import Foundation

/// DeepSeek: an API key pasted in Settings, stored in TokenMeter's Keychain item.
struct DeepSeekCredentials: Codable, Equatable, Sendable {
    var apiKey: String
}

/// Reads `GET /user/balance`: one CreditBalance per currency DeepSeek reports. A balance of zero
/// is real when `is_available` is false, so the balances are mapped either way.
/// See https://api-docs.deepseek.com/api/get-user-balance
struct DeepSeekProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api.deepseek.com")!
    static let loginHint = "Check API key"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_DEEPSEEK_BASE_URL` override).
    static let live = DeepSeekProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_DEEPSEEK_BASE_URL")
                                           ?? defaultBaseURL)
    static let credentialSource = KeychainCredentialSource<DeepSeekCredentials>(missingHint: loginHint)

    var baseURL: URL = DeepSeekProvider.defaultBaseURL

    func read(account: Account, credentials: DeepSeekCredentials, session: URLSession, now: Date) async
        -> ProviderReading<DeepSeekCredentials> {
        var request = URLRequest(url: baseURL.appendingPathComponent("user/balance"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let body = try? JSONDecoder().decode(BalanceResponse.self, from: data) else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    let credits = Self.map(body)
                    guard !credits.isEmpty else { return .failure(.unavailable("Unexpected response")) }
                    return .success(Reading(accountID: account.id, takenAt: now, plan: nil, identity: nil,
                                            quotas: [], credits: credits))
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

    /// One balance per currency, in response order; the first mapped balance is the main one.
    /// Entries whose currency or amount is missing or unparseable are skipped.
    static func map(_ body: BalanceResponse) -> [CreditBalance] {
        body.balanceInfos.enumerated().map { index, info in
            CreditBalance(id: info.currency.lowercased(), title: "\(info.currency) balance",
                          remaining: info.total, allowance: nil, currency: info.currency,
                          renewsAt: nil, isMain: index == 0)
        }
    }

    struct BalanceResponse: Decodable {
        /// Decoded for completeness; balances are mapped whether or not the key is usable.
        var isAvailable: Bool
        var balanceInfos: [BalanceInfo]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isAvailable = (try? container.decode(Bool.self, forKey: .isAvailable)) ?? true
            let raw = try container.decodeIfPresent([Lenient<RawBalanceInfo>].self, forKey: .balanceInfos) ?? []
            balanceInfos = raw.compactMap(\.value?.balance)
        }

        struct BalanceInfo: Equatable, Sendable {
            var currency: String
            var total: Decimal
        }

        private struct RawBalanceInfo: Decodable {
            var currency: String?
            var total: FlexibleDecimal?

            enum CodingKeys: String, CodingKey {
                case currency
                case total = "total_balance"
            }

            var balance: BalanceInfo? {
                guard let currency = currency?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !currency.isEmpty, let total else { return nil }
                return BalanceInfo(currency: currency, total: total.value)
            }
        }

        /// A decimal encoded as either a JSON number or a string.
        private struct FlexibleDecimal: Decodable {
            var value: Decimal

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let decimal = try? container.decode(Decimal.self), decimal.isFinite {
                    value = decimal
                    return
                }
                guard let string = try? container.decode(String.self),
                      let decimal = Decimal(string: string.trimmingCharacters(in: .whitespacesAndNewlines),
                                            locale: Locale(identifier: "en_US_POSIX")),
                      decimal.isFinite else {
                    throw DecodingError.dataCorruptedError(in: container,
                                                           debugDescription: "Expected a decimal amount")
                }
                value = decimal
            }
        }

        /// Decodes `value` only when it is well-formed; a malformed entry becomes nil instead of
        /// failing the whole response.
        private struct Lenient<Value: Decodable>: Decodable {
            var value: Value?

            init(from decoder: Decoder) throws {
                value = try? Value(from: decoder)
            }
        }
    }
}
