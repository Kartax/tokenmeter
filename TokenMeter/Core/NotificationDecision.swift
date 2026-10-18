import Foundation

// MARK: - Seam B: the notification decision (spec #1, "Notification decision")

/// Per-Account notification settings the decision needs: the crossing threshold and whether
/// all Windows (not only main ones) are visible.
struct AccountNotificationSettings: Equatable, Sendable {
    var threshold: NotificationThreshold
    var showAllWindows: Bool

    init(threshold: NotificationThreshold, showAllWindows: Bool) {
        self.threshold = threshold
        self.showAllWindows = showAllWindows
    }
}

/// A quota's notification key: Account + Window identity + that Window's reset time. A Credit
/// balance's key: Account + balance identity + its renewal time. Reset times can be nil.
struct NotifiedKey: Hashable, Codable, Sendable {
    var accountID: UUID

    /// What the key covers, with that subject's period's end. A Window's key: Window identity +
    /// its reset time; a Credit balance's key: balance identity + its renewal time.
    enum Subject: Hashable, Sendable {
        case window(WindowIdentity, resetAt: Date?)
        case credit(String, renewsAt: Date?)
    }

    var subject: Subject

    init(accountID: UUID, window: WindowIdentity, resetAt: Date?) {
        self.accountID = accountID
        self.subject = .window(window, resetAt: resetAt)
    }

    init(accountID: UUID, credit: String, renewsAt: Date?) {
        self.accountID = accountID
        self.subject = .credit(credit, renewsAt: renewsAt)
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, window, credit, resetAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountID, forKey: .accountID)
        switch subject {
        case .window(let identity, let resetAt):
            try c.encode(identity, forKey: .window)
            try c.encodeIfPresent(resetAt, forKey: .resetAt)
        case .credit(let id, let renewsAt):
            try c.encode(id, forKey: .credit)
            try c.encodeIfPresent(renewsAt, forKey: .resetAt)
        }
    }

    /// Decodes the subject from a Window identity or a Credit identity, keeping the config's
    /// already-notified keys decodable across launches.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(UUID.self, forKey: .accountID)
        if let window = try? c.decodeIfPresent(WindowIdentity.self, forKey: .window) {
            subject = .window(window, resetAt: try c.decodeIfPresent(Date.self, forKey: .resetAt))
        } else if let credit = try c.decodeIfPresent(String.self, forKey: .credit) {
            subject = .credit(credit, renewsAt: try c.decodeIfPresent(Date.self, forKey: .resetAt))
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "NotifiedKey without a Window or Credit subject"))
        }
    }
}

/// The already-notified set, pruned to keys whose Window or Credit balance has not reset yet.
struct NotifiedKeySet: Equatable, Sendable {
    var keys: Set<NotifiedKey>

    init(keys: Set<NotifiedKey>) {
        self.keys = keys
    }

    /// Keys whose reset (or renewal) time has already passed are stale.
    private static func isStale(_ key: NotifiedKey, now: Date) -> Bool {
        switch key.subject {
        case .window(_, let resetAt), .credit(_, let resetAt):
            guard let resetAt else { return false }
            return resetAt <= now
        }
    }

    /// The set without keys that are no longer active (the Window reset or the balance
    /// renewed); they must not block a new period's crossing.
    func pruned(now: Date) -> NotifiedKeySet {
        NotifiedKeySet(keys: keys.filter { !Self.isStale($0, now: now) })
    }
}

/// One notification: what to show and its stable identity within one reset period.
struct OutgoingNotification: Equatable, Identifiable, Sendable {
    var title: String
    var body: String

    /// Stable within the reset period: the key's identity.
    var id: String {
        switch key.subject {
        case .window(let window, let resetAt): "\(key.accountID)-\(window)-\(resetAt ?? .distantPast)"
        case .credit(let credit, let renewsAt): "\(key.accountID)-credit-\(credit)-\(renewsAt ?? .distantPast)"
        }
    }

    var key: NotifiedKey

    init(key: NotifiedKey, title: String, body: String) {
        self.key = key
        self.title = title
        self.body = body
    }
}

/// The pure seam-B decision. No I/O; the caller persists the returned set and sends the
/// returned notifications.
enum NotificationDecision {
    /// A Credit balance notifies when a known allowance is drawn down below 10% remaining.
    static let creditNoticeFraction: Decimal = 0.1
    static let creditNoticePercent = 10

    static func decide(new: Reading, account: Account,
                       settings: AccountNotificationSettings, notificationsEnabled: Bool,
                       notified: NotifiedKeySet, now: Date)
        -> (notifications: [OutgoingNotification], notified: NotifiedKeySet) {
        // The global switch and the Account threshold both silence everything; the set stays
        // intact so re-enabling can't re-fire within the same reset periods.
        guard notificationsEnabled, settings.threshold != .off else {
            return ([], notified)
        }

        let visible: (Quota) -> Bool = { settings.showAllWindows || $0.window.isMain }
        let creditVisible: (CreditBalance) -> Bool = { settings.showAllWindows || $0.isMain }
        let updatedInput = notified.pruned(now: now)
        let result = notifications(
            new: new, visible: visible, creditVisible: creditVisible, threshold: settings.threshold,
            accountID: account.id, notifiedKeys: updatedInput.keys, now: now)
        let updated = NotifiedKeySet(keys: result.keys)
        return (result.notifications, updated)
    }

    private static func notifications(new: Reading, visible: (Quota) -> Bool,
                                      creditVisible: (CreditBalance) -> Bool,
                                      threshold: NotificationThreshold, accountID: UUID,
                                      notifiedKeys: Set<NotifiedKey>, now: Date)
        -> (notifications: [OutgoingNotification], keys: Set<NotifiedKey>) {
        var notifications: [OutgoingNotification] = []
        var keys = notifiedKeys

        // Quotas: one notification per Window per reset period, at the Account's threshold.
        // A without-reset-time Window would repeat forever; never notify such a Window.
        guard let thresholdPercent = threshold.percent else { return ([], keys) }
        for quota in new.quotas {
            guard visible(quota), let resetsAt = quota.window.resetsAt else { continue }
            let key = NotifiedKey(accountID: accountID, window: quota.window.identity, resetAt: resetsAt)
            guard quota.percentUsed >= thresholdPercent, !keys.contains(key) else { continue }
            keys.insert(key)
            notifications.append(OutgoingNotification(
                key: key,
                title: "\(quota.window.title) at \(Int(quota.percentUsed.rounded()))% used",
                body: body(for: quota, now: now)))
        }

        // Credits: one notification per balance per renewal period, below 10% remaining of a
        // known allowance.
        for credit in new.credits {
            guard creditVisible(credit), let allowance = credit.allowance else { continue }
            let remaining = credit.remaining
            // Rollover credits (remaining > the monthly allowance) don't notify.
            guard remaining <= allowance else { continue }
            guard remaining / allowance < creditNoticeFraction else { continue }
            let key = NotifiedKey(accountID: accountID, credit: credit.id, renewsAt: credit.renewsAt)
            guard !keys.contains(key) else { continue }
            keys.insert(key)
            notifications.append(OutgoingNotification(
                key: key,
                title: "\(credit.title) below \(Self.creditNoticePercent)% used",
                body: body(for: credit, now: now)))
        }
        return (notifications, keys)
    }

    private static func body(for quota: Quota, now: Date) -> String {
        let format = DisplayFormat()
        var body = quota.limitReached ? "Limit reached" : "\(Int(quota.percentUsed.rounded()))% used"
        if let resetsAt = quota.window.resetsAt {
            body += " · resets \(format.resetTime(resetsAt, now: now))"
        }
        return body
    }

    private static func body(for credit: CreditBalance, now: Date) -> String {
        let format = DisplayFormat()
        var body = "\(format.money(credit.remaining, currency: credit.currency)) left"
        if let allowance = credit.allowance {
            body += " of \(format.money(allowance, currency: credit.currency))"
        }
        if let renewsAt = credit.renewsAt {
            body += " · renews \(format.resetTime(renewsAt, now: now))"
        }
        return body
    }
}