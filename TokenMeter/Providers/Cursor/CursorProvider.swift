import Foundation

/// Cursor's app login, borrowed for one fetch. Deliberately not `Encodable`: TokenMeter never
/// stores, copies or refreshes this token. It lives in memory for the requests of one Reading.
struct CursorCredentials: Equatable, Sendable {
    var accessToken: String
}

extension CursorCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never reveals the token, even if the value ends up in a log or debugger print.
    var description: String { "CursorCredentials(accessToken: <redacted>)" }
    var debugDescription: String { description }
}

/// Reads Cursor's own login (Cursor app or `cursor agent`), fresh on every fetch: the
/// `cursorAuth/accessToken` row in `state.vscdb`, else the `cursor-access-token` Keychain item.
/// Nothing is ever written back: Cursor owns and refreshes this token.
struct CursorCredentialSource: CredentialSource {
    /// Cursor's VS Code global storage database.
    static var databasePath: String {
        NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    static let databaseKey = "cursorAuth/accessToken"
    static let keychainService = "cursor-access-token"

    /// Injected so the lookup order can be exercised without Cursor installed.
    var databaseToken: @Sendable (_ path: String) -> String? = CursorCredentialSource.readDatabaseToken
    var keychainItem: @Sendable () throws -> Data? = CursorCredentialSource.readKeychainItem

    func load(for account: Account) -> Result<CursorCredentials, ReadingFailure> {
        if let token = databaseToken(Self.databasePath), !token.isEmpty {
            return .success(CursorCredentials(accessToken: token))
        }
        do {
            if let data = try keychainItem(), let token = Self.parse(data) {
                return .success(CursorCredentials(accessToken: token))
            }
        } catch let failure as KeychainStore.Failure where failure.cursorIsAccessDenied {
            return .failure(.unavailable("Keychain access denied — allow TokenMeter in the prompt"))
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
        return .failure(.loginExpired(hint: CursorProvider.loginHint))
    }

    /// Never called: Cursor refreshes its own login.
    func save(_ credentials: CursorCredentials, for account: Account) throws {}

    /// Nothing to delete: TokenMeter stores no Cursor secret.
    func delete(for account: Account) throws {}

    /// Runs the read-only lookup through the system `sqlite3` binary (the app is not sandboxed).
    @Sendable static func readDatabaseToken(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            path,
            "SELECT value FROM ItemTable WHERE key='\(databaseKey)' LIMIT 1;",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The generic-password item Cursor's agent login writes; no account filter, so it matches
    /// regardless of which macOS user attribute Cursor used.
    @Sendable static func readKeychainItem() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainStore.Failure(status: status)
        }
    }

    /// The item holds the token as plain text; tolerate a JSON object with `accessToken`.
    static func parse(_ data: Data) -> String? {
        if let string = String(data: data, encoding: .utf8) {
            let token = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, !token.hasPrefix("{") { return token }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (object["accessToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }
}

private extension KeychainStore.Failure {
    /// The user denied (or cancelled) the Keychain prompt.
    var cursorIsAccessDenied: Bool {
        status == errSecAuthFailed || status == errSecUserCanceled
    }
}

/// Cursor subscription usage through its dashboard Connect-RPC service.
/// `GetPlanInfo` probes the borrowed login; `GetCurrentPeriodUsage` supplies the billing-cycle
/// percentage and the Auto/API breakdown.
struct CursorProvider: Provider {
    static let defaultBaseURL = URL(string: "https://api2.cursor.sh")!
    static let loginHint = "Open Cursor or run `cursor agent login`"

    /// The instance the app uses (honours the DEBUG `TOKENMETER_CURSOR_BASE_URL` override).
    static let live = CursorProvider(baseURL: ProviderRegistry.debugBaseURL("TOKENMETER_CURSOR_BASE_URL")
                                         ?? defaultBaseURL)
    static let credentialSource = CursorCredentialSource()

    var baseURL: URL = CursorProvider.defaultBaseURL

    func read(account: Account, credentials: CursorCredentials, session: URLSession, now: Date) async
        -> ProviderReading<CursorCredentials> {
        let plan: PlanInfo
        switch await fetchPlan(credentials, session: session, now: now) {
        case .failure(let failure):
            return ProviderReading(.failure(failure))
        case .success(let info):
            plan = info
        }

        switch await fetchUsage(credentials, session: session, now: now) {
        case .failure(let failure):
            return ProviderReading(.failure(failure))
        case .success(let usage):
            guard let quotas = Self.map(usage, plan: plan) else {
                return ProviderReading(.failure(.unavailable("Unexpected response")))
            }
            return ProviderReading(.success(Reading(accountID: account.id, takenAt: now, plan: plan.planName,
                                                    identity: nil, quotas: quotas, credits: [])))
        }
    }

    // MARK: - Requests

    private func request(_ method: String, _ credentials: CursorCredentials) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("aiserver.v1.DashboardService/\(method)"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return request
    }

    private func fetchPlan(_ credentials: CursorCredentials, session: URLSession, now: Date) async
        -> Result<PlanInfo, ReadingFailure> {
        await HTTP.send(request("GetPlanInfo", credentials), session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(PlanResponse.self, from: data),
                      let info = body.planInfo else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return .success(info)
            default:
                return .failure(Self.failure(for: response, now: now))
            }
        }
    }

    private func fetchUsage(_ credentials: CursorCredentials, session: URLSession, now: Date) async
        -> Result<UsageResponse.PlanUsage, ReadingFailure> {
        await HTTP.send(request("GetCurrentPeriodUsage", credentials), session: session).flatMap { data, response in
            switch response.statusCode {
            case 200..<300:
                guard let body = try? JSONDecoder().decode(UsageResponse.self, from: data),
                      let usage = body.planUsage else {
                    return .failure(.unavailable("Unexpected response"))
                }
                return .success(usage)
            default:
                return .failure(Self.failure(for: response, now: now))
            }
        }
    }

    private static func failure(for response: HTTPURLResponse, now: Date) -> ReadingFailure {
        switch response.statusCode {
        case 401, 403:
            .loginExpired(hint: loginHint)
        case 429:
            .rateLimited(retryAfter: HTTP.retryAfter(response, now: now))
        default:
            .unavailable(HTTP.statusMessage(response.statusCode))
        }
    }

    // MARK: - Mapping

    /// The main "Billing cycle" Window always exists; "Auto" and "API" are added only when the
    /// response reports their percentages. Nil when no main percentage can be derived.
    private static func map(_ usage: UsageResponse.PlanUsage, plan: PlanInfo) -> [Quota]? {
        let start = epochDate(usage.billingCycleStart)
        let end = epochDate(usage.billingCycleEnd) ?? epochDate(plan.billingCycleEnd)
        let length = start.flatMap { start in end.map { $0.timeIntervalSince(start) } }.flatMap {
            $0 > 0 ? $0 : nil
        }

        let limit = usage.limit?.value ?? plan.includedAmountCents?.value
        let percent: Double?
        if let total = usage.totalPercentUsed {
            percent = total
        } else if let limit, limit > 0 {
            if let remaining = usage.remaining {
                percent = (limit - remaining) / limit * 100
            } else {
                percent = usage.includedSpend.map { $0 / limit * 100 }
            }
        } else {
            percent = nil
        }
        guard let percent else { return nil }

        func window(_ identity: WindowIdentity, _ title: String, isMain: Bool) -> Window {
            Window(identity: identity, title: title, isMain: isMain, resetsAt: end, length: length)
        }

        var quotas = [Quota(window: window(.month, "Billing cycle", isMain: true), percentUsed: percent)]
        if let auto = usage.autoPercentUsed {
            quotas.append(Quota(window: window(.scoped("auto"), "Auto", isMain: false), percentUsed: auto))
        }
        if let api = usage.apiPercentUsed {
            quotas.append(Quota(window: window(.scoped("api"), "API", isMain: false), percentUsed: api))
        }
        return quotas
    }

    /// Epoch milliseconds, as a string (or a number for lenience).
    private static func epochDate(_ value: FlexibleNumber?) -> Date? {
        guard let milliseconds = value?.value else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    // MARK: - Response bodies

    private struct PlanResponse: Decodable {
        var planInfo: PlanInfo?
    }

    private struct PlanInfo: Decodable {
        var planName: String?
        var billingCycleEnd: FlexibleNumber?
        var includedAmountCents: FlexibleNumber?
    }

    private struct UsageResponse: Decodable {
        var planUsage: PlanUsage?

        struct PlanUsage: Decodable {
            var totalPercentUsed: Double?
            var autoPercentUsed: Double?
            var apiPercentUsed: Double?
            var includedSpend: Double?
            /// Not always present; when it is, it wins over `includedSpend` for the fallback.
            var remaining: Double?
            var limit: FlexibleNumber?
            var billingCycleStart: FlexibleNumber?
            var billingCycleEnd: FlexibleNumber?
        }
    }
}

/// A JSON number or numeric string (`1500`, `"1500"`, 19.25); nil for anything else.
private struct FlexibleNumber: Decodable {
    var value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = Double(string.trimmingCharacters(in: .whitespaces))
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else {
            value = nil
        }
    }
}
