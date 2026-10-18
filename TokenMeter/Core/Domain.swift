import Foundation

// Domain vocabulary follows CONTEXT.md: Provider, Account, Plan, Window, Quota, Credit balance, Reading.

/// The compiled-in Providers (ADR 0004). Implementations are listed in `ProviderRegistry`.
enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, ollama, nous

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .ollama: "Ollama Cloud"
        case .nous: "Nous Portal"
        }
    }

    /// SF Symbol used as the Provider icon in Settings and the popover.
    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .ollama: "cloud"
        case .nous: "brain"
        }
    }
}

/// Per-Account notification threshold (percent used).
enum NotificationThreshold: String, Codable, CaseIterable, Sendable {
    case off, p80 = "80", p90 = "90", p95 = "95"

    static let `default` = NotificationThreshold.p90
}

/// One configured login at a Provider. Non-secret; persisted in the config file.
/// Secrets live in the Keychain under the Account's `id` (see `KeychainStore`).
struct Account: Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: ProviderKind
    var label: String
    var order: Int
    var threshold: NotificationThreshold
    var showAllWindows: Bool
    /// Claude: optional `CLAUDE_CONFIG_DIR` path (nil = default login). Unused by other Providers.
    var claudeConfigDirectory: String?

    init(id: UUID = UUID(), kind: ProviderKind, label: String, order: Int = 0,
         threshold: NotificationThreshold = .default, showAllWindows: Bool = false,
         claudeConfigDirectory: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.order = order
        self.threshold = threshold
        self.showAllWindows = showAllWindows
        self.claudeConfigDirectory = claudeConfigDirectory
    }
}

extension Account: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, label, order, threshold, showAllWindows, claudeConfigDirectory
    }

    /// Only `id` and `kind` are required; everything else falls back to a default so the
    /// config format can grow without migrations (immich `AppConfig` pattern).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? kind.displayName
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        threshold = (try? c.decodeIfPresent(NotificationThreshold.self, forKey: .threshold)) ?? .default
        showAllWindows = try c.decodeIfPresent(Bool.self, forKey: .showAllWindows) ?? false
        claudeConfigDirectory = try c.decodeIfPresent(String.self, forKey: .claudeConfigDirectory)
    }
}

/// Identity of a Window. Windows are identified by their data (e.g. window length), never by
/// the slot they occupy in a Provider response.
enum WindowIdentity: Hashable, Codable, Sendable {
    case session
    case week
    case month
    /// Model- or feature-scoped Window, e.g. `scoped("seven_day_sonnet")`.
    case scoped(String)
}

/// A period with its own usage limit and reset time.
struct Window: Equatable, Codable, Sendable {
    var identity: WindowIdentity
    var title: String
    var isMain: Bool
    var resetsAt: Date?
    /// Length of the Window in seconds, when known.
    var length: TimeInterval?
}

/// How much of a Window's limit is used.
struct Quota: Equatable, Codable, Sendable {
    var window: Window
    /// Percent used, clamped to 0…100.
    var percentUsed: Double
    /// True when the Provider reported usage at or above 100%.
    var limitReached: Bool

    /// Clamps `percentUsed` into 0…100 and keeps "limit reached" separately.
    init(window: Window, percentUsed raw: Double) {
        self.window = window
        self.percentUsed = min(max(raw, 0), 100)
        self.limitReached = raw >= 100
    }
}

/// A monetary amount an Account can still spend.
struct CreditBalance: Equatable, Codable, Sendable {
    /// Stable identity within the Provider (e.g. "included", "purchased"); part of the notification key.
    var id: String
    var title: String
    var remaining: Decimal
    var allowance: Decimal?
    /// ISO 4217 code, e.g. "USD".
    var currency: String
    var renewsAt: Date?
    var isMain: Bool
}

/// The Quotas and Credit balances fetched for one Account at one moment.
struct Reading: Equatable, Codable, Sendable {
    var accountID: UUID
    var takenAt: Date
    /// Plan display name, e.g. "Max 5x", "Pro".
    var plan: String?
    /// Signed-in identity: email or account/org name.
    var identity: String?
    var quotas: [Quota]
    var credits: [CreditBalance]
}

/// Why a Reading could not be taken.
enum ReadingFailure: Error, Equatable, Sendable {
    /// Credentials are missing, expired or revoked; `hint` is the user action ("Check API key").
    case loginExpired(hint: String)
    /// The Provider throttled us; retry after this many seconds when the server said so.
    case rateLimited(retryAfter: TimeInterval?)
    /// Anything else, as one short line ("Server returned 500").
    case unavailable(String)
}

/// What an Account row shows, derived from the last Reading and the last failure.
enum AccountDisplayState: Equatable {
    /// No Reading and no failure yet.
    case loading
    case ok(Reading)
    /// The latest fetch failed transiently; show the last Reading (if any) greyed with its time.
    case stale(Reading?, note: String)
    case loginExpired(hint: String)
    case error(String)

    /// `lastFailure` must be the failure of the latest fetch (nil once a fetch succeeded).
    init(lastReading: Reading?, lastFailure: ReadingFailure?) {
        switch (lastFailure, lastReading) {
        case (nil, nil): self = .loading
        case (nil, let reading?): self = .ok(reading)
        case (.loginExpired(let hint)?, _): self = .loginExpired(hint: hint)
        case (.rateLimited?, let reading): self = .stale(reading, note: "Rate limited")
        case (.unavailable(let message)?, let reading?): self = .stale(reading, note: message)
        case (.unavailable(let message)?, nil): self = .error(message)
        }
    }
}
