import Foundation

/// MiniMax's region split is a separate account on each host (Global / China mainland).
enum MiniMaxRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case global
    case cn

    var id: Self { self }

    var displayName: String {
        switch self {
        case .global: "Global"
        case .cn: "China"
        }
    }

    /// Token Plan remains host for the region.
    var baseURL: URL {
        switch self {
        case .global: URL(string: "https://www.minimax.io")!
        case .cn: URL(string: "https://api.minimaxi.com")!
        }
    }
}

/// MiniMax Token Plan: an API key plus the region it belongs to, stored in TokenMeter's Keychain item.
struct MiniMaxCredentials: Codable, Equatable, Sendable {
    var apiKey: String
    var region: MiniMaxRegion

    init(apiKey: String, region: MiniMaxRegion = .global) {
        self.apiKey = apiKey
        self.region = region
    }

    private enum CodingKeys: String, CodingKey {
        case apiKey, region
    }

    /// `region` is optional so a credential written before the region was stored still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        region = (try? container.decodeIfPresent(MiniMaxRegion.self, forKey: .region)) ?? .global
    }
}

/// Reads `GET /v1/token_plan/remains`. The response reports the Token Plan interval budget per
/// model; `current_interval_usage_count` is the number of prompts **remaining** despite its name,
/// so used is `total - remaining`. A remaining percentage is the fallback when counts are absent.
struct MiniMaxProvider: Provider {
    static let defaultBaseURL = URL(string: "https://www.minimax.io")!
    static let loginHint = "Check MiniMax API key"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_MINIMAX_BASE_URL` override).
    static let live = MiniMaxProvider(baseURLOverride:
        ProviderRegistry.debugBaseURL("TOKENMETER_MINIMAX_BASE_URL"))
    static let credentialSource = KeychainCredentialSource<MiniMaxCredentials>(missingHint: loginHint)

    /// Debug/smoke-test host override; otherwise the credentials' region host is used.
    var baseURLOverride: URL?

    func read(account: Account, credentials: MiniMaxCredentials, session: URLSession, now: Date) async
        -> ProviderReading<MiniMaxCredentials> {
        let baseURL = baseURLOverride ?? credentials.region.baseURL
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/token_plan/remains"))
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: Result<Reading, ReadingFailure> = await HTTP.send(request, session: session)
            .flatMap { data, response in
                switch response.statusCode {
                case 200..<300:
                    guard let body = try? JSONDecoder().decode(RemainsResponse.self, from: data) else {
                        return .failure(.unavailable("Unexpected response"))
                    }
                    if let base = body.baseResponse, let status = base.statusCode, status != 0 {
                        return .failure(Self.apiFailure(status: status, message: base.statusMessage))
                    }
                    guard let mapped = Self.map(body, region: credentials.region, now: now) else {
                        return .failure(.unavailable("Missing usage data"))
                    }
                    return .success(Reading(accountID: account.id, takenAt: now, plan: mapped.plan,
                                            identity: nil, quotas: [mapped.quota], credits: []))
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

    /// A failed `base_resp`: authentication errors become `loginExpired`, everything else the
    /// server's own short message.
    private static func apiFailure(status: Int, message: String?) -> ReadingFailure {
        let text = message ?? "status_code \(status)"
        let lower = text.lowercased()
        let authCodes = [401, 403, 1004]
        let authWords = ["api key", "apikey", "unauthorized", "forbidden", "login", "log in",
                         "sign in", "authentication", "auth failed", "登录"]
        if authCodes.contains(status) || authWords.contains(where: { lower.contains($0) }) {
            return .loginExpired(hint: loginHint)
        }
        return .unavailable(text)
    }

    // MARK: - Mapping

    /// One main `session` Window from the most constrained usable model bucket. Plan comes from
    /// the response's plan/title fields, falling back to the chosen bucket's.
    static func map(_ body: RemainsResponse, region: MiniMaxRegion, now: Date)
        -> (plan: String?, quota: Quota)? {
        var chosen: (remains: RemainsResponse.ModelRemains, percentUsed: Double)?
        for remains in body.modelRemains {
            guard let percentUsed = Self.percentUsed(for: remains) else { continue }
            if let current = chosen {
                // Lowest remaining percentage (highest usage) identifies the tightest bucket.
                if percentUsed > current.percentUsed {
                    chosen = (remains, percentUsed)
                }
            } else {
                chosen = (remains, percentUsed)
            }
        }
        guard let chosen else { return nil }

        let end = Self.date(chosen.remains.endTime, now: now)
        let resetsAt = end ?? Self.date(chosen.remains.remainsTime, now: now)
        var length: TimeInterval?
        if let start = Self.date(chosen.remains.startTime, now: now), let end {
            let interval = end.timeIntervalSince(start)
            if interval > 0 { length = interval }
        }

        let plan = Self.planName(body, chosen: chosen.remains, region: region)
        let quota = Quota(window: Window(identity: .session, title: "Session", isMain: true,
                                         resetsAt: resetsAt, length: length),
                          percentUsed: chosen.percentUsed)
        return (plan, quota)
    }

    /// Percent used from explicit used fields, then total − remaining, then remaining percent.
    static func percentUsed(for remains: RemainsResponse.ModelRemains) -> Double? {
        if let total = remains.totalCount, total > 0 {
            if let used = remains.usedCount {
                return Double(used) / Double(total) * 100
            }
            if let remaining = remains.remainingCount ?? remains.usageCount {
                return Double(max(0, total - remaining)) / Double(total) * 100
            }
        }
        if let remainingPercent = remains.remainingPercent {
            return 100 - remainingPercent
        }
        return nil
    }

    /// Response-level plan fields win over the chosen model bucket's.
    private static func planName(_ body: RemainsResponse, chosen: RemainsResponse.ModelRemains,
                                 region: MiniMaxRegion) -> String? {
        let candidates = [body.currentSubscribeTitle, body.planName, body.plan, body.title,
                          chosen.currentSubscribeTitle, chosen.planName, chosen.plan, chosen.title]
        guard let name = candidates.compactMap({ $0 }).first else { return nil }
        guard region == .cn, !name.hasSuffix("(CN)") else { return name }
        return "\(name) (CN)"
    }

    /// End times are epoch milliseconds, epoch seconds, or ISO 8601. Small numbers are treated as
    /// a relative duration (`remains_time` is milliseconds when large, seconds otherwise).
    private static func date(_ value: MiniMaxTimeValue?, now: Date) -> Date? {
        guard let value else { return nil }
        if let string = value.string {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let date = HTTP.date(trimmed) { return date }
            guard let number = Double(trimmed) else { return nil }
            return date(epoch: number, now: now)
        }
        guard let number = value.number else { return nil }
        return date(epoch: number, now: now)
    }

    private static func date(epoch value: Double, now: Date) -> Date? {
        guard value > 0 else { return nil }
        if value >= 1_000_000_000_000 { return Date(timeIntervalSince1970: value / 1000) }
        if value >= 1_000_000_000 { return Date(timeIntervalSince1970: value) }
        return now.addingTimeInterval(value >= 1_000_000 ? value / 1000 : value)
    }

    // MARK: - Response

    struct RemainsResponse: Decodable {
        struct BaseResponse: Decodable {
            var statusCode: Int?
            var statusMessage: String?

            private enum CodingKeys: String, CodingKey {
                case statusCode = "status_code"
                case statusMessage = "status_msg"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                statusCode = container.flexibleInt(.statusCode)
                statusMessage = container.optionalString(.statusMessage)
            }
        }

        struct ModelRemains: Decodable {
            var totalCount: Int?
            /// Despite the name, this is the number of prompts **remaining**.
            var usageCount: Int?
            var remainingCount: Int?
            var remainingPercent: Double?
            /// Explicit used counts, preferred when the response provides them.
            var usedCount: Int?
            var startTime: MiniMaxTimeValue?
            var endTime: MiniMaxTimeValue?
            var remainsTime: MiniMaxTimeValue?
            var currentSubscribeTitle: String?
            var planName: String?
            var plan: String?
            var title: String?

            private enum CodingKeys: String, CodingKey {
                case totalCount = "current_interval_total_count"
                case usageCount = "current_interval_usage_count"
                case remainingCount = "current_interval_remaining_count"
                case remainingPercent = "current_interval_remaining_percent"
                case usedCount = "current_interval_used_count"
                case legacyUsedCount = "used_count"
                case startTime = "start_time"
                case endTime = "end_time"
                case remainsTime = "remains_time"
                case currentSubscribeTitle = "current_subscribe_title"
                case planName = "plan_name"
                case plan
                case title
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                totalCount = container.flexibleInt(.totalCount)
                usageCount = container.flexibleInt(.usageCount)
                remainingCount = container.flexibleInt(.remainingCount)
                remainingPercent = container.flexibleDouble(.remainingPercent)
                usedCount = container.flexibleInt(.usedCount) ?? container.flexibleInt(.legacyUsedCount)
                startTime = container.optionalTime(.startTime)
                endTime = container.optionalTime(.endTime)
                remainsTime = container.optionalTime(.remainsTime)
                currentSubscribeTitle = container.optionalString(.currentSubscribeTitle)
                planName = container.optionalString(.planName)
                plan = container.optionalString(.plan)
                title = container.optionalString(.title)
            }
        }

        var baseResponse: BaseResponse?
        var modelRemains: [ModelRemains]
        var currentSubscribeTitle: String?
        var planName: String?
        var plan: String?
        var title: String?

        private enum CodingKeys: String, CodingKey {
            case baseResp = "base_resp"
            case data
            case modelRemains = "model_remains"
            case currentSubscribeTitle = "current_subscribe_title"
            case planName = "plan_name"
            case plan
            case title
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The live endpoint wraps the payload in `data`; recorded and older shapes are flat.
            let nested = try? container.decode(RemainsResponse.self, forKey: .data)
            let topBase = try? container.decode(BaseResponse.self, forKey: .baseResp)
            baseResponse = nested?.baseResponse ?? topBase
            modelRemains = nested?.modelRemains
                ?? (try? container.decodeIfPresent([ModelRemains].self, forKey: .modelRemains)) ?? []
            currentSubscribeTitle = nested?.currentSubscribeTitle
                ?? container.optionalString(.currentSubscribeTitle)
            planName = nested?.planName ?? container.optionalString(.planName)
            plan = nested?.plan ?? container.optionalString(.plan)
            title = nested?.title ?? container.optionalString(.title)
        }
    }
}

/// A timestamp that the API may encode as a number (epoch) or a string (epoch or ISO 8601).
struct MiniMaxTimeValue: Decodable, Sendable {
    var number: Double?
    var string: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self.number = number
            return
        }
        if let string = try? container.decode(String.self) {
            self.string = string
            return
        }
        throw DecodingError.typeMismatch(
            MiniMaxTimeValue.self,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "Expected an epoch or ISO 8601 value"))
    }
}

private extension KeyedDecodingContainer {
    /// Counts arrive as numbers or numeric strings.
    func flexibleInt(_ key: K) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func flexibleDouble(_ key: K) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func optionalString(_ key: K) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func optionalTime(_ key: K) -> MiniMaxTimeValue? {
        try? decodeIfPresent(MiniMaxTimeValue.self, forKey: key)
    }
}
