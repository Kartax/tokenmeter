import Foundation
import Observation

extension Notification.Name {
    /// Carries `[OutgoingNotification]` decided by `AccountStore` (seam B) to the sender.
    static let tokenMeterNotification = Notification.Name("org.kartax.TokenMeter.notification")
    /// The global Notifications switch changed; `userInfo["enabled"]` carries the new value.
    static let tokenMeterNotificationsSwitch = Notification.Name("org.kartax.TokenMeter.notificationsSwitch")
}

/// App state shared by the popover and Settings: the configured Accounts and the last Reading
/// per Account (both persisted in the config file), plus the last failure per Account.
@MainActor @Observable
final class AccountStore {
    /// Accounts in display order.
    private(set) var accounts: [Account]
    /// Last Reading per Account; persisted so the next launch has stale data to show.
    private(set) var readings: [UUID: Reading] {
        didSet { persistReadings() }
    }
    private(set) var failures: [UUID: ReadingFailure] = [:]
    /// Accounts with a fetch in flight; a refresh of one of these is never duplicated.
    private(set) var refreshing: Set<UUID> = []
    /// Accounts whose Reading was restored from the last session and not refreshed since.
    private var restored: Set<UUID> = []
    /// End of each rate-limited Account's back-off; refreshes skip the Account until then.
    @ObservationIgnored private var backOffUntil: [UUID: Date] = [:]
    /// Notification keys already sent (seam B's already-notified set). A silenced decision
    /// (global switch off, or the Account threshold off) keeps the keys, so re-enabling cannot
    /// re-fire within the same reset periods; keys whose period has reset are pruned on load.
    private(set) var notifiedKeys: Set<NotifiedKey> = []

    /// Poll intervals offered in General, in minutes.
    static let pollIntervals = [1, 2, 5, 15, 30]
    static let defaultPollInterval = 5
    /// Background poll interval in minutes (General tab). A change applies at once.
    var pollIntervalMinutes: Int {
        didSet {
            guard pollIntervalMinutes != oldValue else { return }
            let minutes = pollIntervalMinutes
            config.update { $0.pollIntervalMinutes = minutes }
            coreLog.info("Poll interval set to \(minutes, privacy: .public) min")
            if pollTask != nil { startPolling() }
        }
    }
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    let session: URLSession
    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private let readerFor: (ProviderKind) -> (any AccountReader)?
    @ObservationIgnored private let now: () -> Date

    init(config: ConfigStore = ConfigStore(),
         session: URLSession = .shared,
         readerFor: @escaping (ProviderKind) -> (any AccountReader)? = ProviderRegistry.reader(for:),
         now: @escaping () -> Date = Date.init) {
        self.config = config
        self.session = session
        self.readerFor = readerFor
        self.now = now
        let stored = config.load()
        let accounts = (stored.accounts ?? []).sorted { $0.order < $1.order }
        let ids = Set(accounts.map(\.id))
        let readings = (stored.readings ?? []).filter { ids.contains($0.accountID) }
        self.accounts = accounts
        notificationsEnabled = stored.notificationsEnabled ?? false
        self.readings = Dictionary(readings.map { ($0.accountID, $0) }) { _, latest in latest }
        pollIntervalMinutes = stored.pollIntervalMinutes.flatMap { Self.pollIntervals.contains($0) ? $0 : nil }
            ?? Self.defaultPollInterval
        restored = Set(self.readings.keys)
        // A restart must not repeat notifications: load the set; entries whose Window or Credit
        // balance has reset meanwhile drop out (a new period may notify again).
        notifiedKeys = NotifiedKeySet(keys: stored.alreadyNotified ?? []).pruned(now: now()).keys
    }

    /// Refreshes every Account once per poll interval, counted from now. Call once on launch;
    /// changing the interval restarts it.
    func startPolling() {
        pollTask?.cancel()
        let minutes = pollIntervalMinutes
        coreLog.info("Polling every \(minutes, privacy: .public) min")
        pollTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
                guard let self else { return }
                await self.refreshAll(.scheduled)
            }
        }
    }

    /// Time of the newest Reading, for the popover footer.
    var lastUpdated: Date? { readings.values.map(\.takenAt).max() }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func displayState(of account: Account) -> AccountDisplayState {
        let reading = readings[account.id], failure = failures[account.id]
        if failure == nil, let reading, restored.contains(account.id) {
            return .stale(reading, note: "From last session")
        }
        return AccountDisplayState(lastReading: reading, lastFailure: failure)
    }

    // MARK: - Account management

    /// Adds an Account whose secrets the caller has already saved, with the Reading taken while
    /// validating them (if any).
    func add(_ account: Account, firstReading: Reading? = nil) {
        var account = account
        account.order = (accounts.map(\.order).max() ?? -1) + 1
        accounts.append(account)
        if let firstReading { record(.success(firstReading), for: account.id) }
        persist()
        coreLog.info("Added \(account.kind.rawValue, privacy: .public) Account \(account.id, privacy: .public)")
    }

    func rename(_ id: UUID, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].label != label else { return }
        accounts[index].label = label
        persist()
    }

    /// "Show all Windows": also show non-main Windows and Credit balances in the popover.
    func setShowAllWindows(_ showAll: Bool, for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].showAllWindows != showAll else { return }
        accounts[index].showAllWindows = showAll
        persist()
    }

    /// Drag reordering in Settings (`onMove` semantics); the popover follows this order.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { accounts[$0] }
        var reordered = accounts.indices.filter { !source.contains($0) }.map { accounts[$0] }
        reordered.insert(contentsOf: moving, at: destination - source.count { $0 < destination })
        for index in reordered.indices { reordered[index].order = index }
        guard reordered != accounts else { return }
        accounts = reordered
        persist()
    }

    /// Removes the Account and deletes every secret TokenMeter stored for it.
    func remove(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        do {
            try readerFor(account.kind)?.deleteSecrets(for: account)
        } catch {
            coreLog.error("Deleting secrets of \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        accounts.removeAll { $0.id == id }
        readings[id] = nil
        failures[id] = nil
        backOffUntil[id] = nil
        let removed = notifiedKeys.filter { $0.accountID == id }
        if !removed.isEmpty {
            notifiedKeys.subtract(removed)
            config.update { $0.alreadyNotified = notifiedKeys }
        }
        persist()
        coreLog.info("Removed Account \(id, privacy: .public)")
    }

    /// Signs the Account out without removing it (Codex, Nous): deletes its secrets and forgets
    /// its Reading, so it shows `.loginExpired(hint)` until it signs in again.
    func signOut(_ id: UUID, hint: String) throws {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        try readerFor(account.kind)?.deleteSecrets(for: account)
        readings[id] = nil
        failures[id] = .loginExpired(hint: hint)
        persist()
        coreLog.info("Signed out Account \(id, privacy: .public)")
    }

    /// Back-off after a rate limit whose response didn't say how long to wait.
    static let defaultBackOff: TimeInterval = 60

    /// Stores the outcome of a fetch made outside `refresh` (e.g. after replacing an API key).
    /// A rate limit starts the Account's back-off; any other outcome ends it.
    func record(_ result: Result<Reading, ReadingFailure>, for id: UUID) {
        backOffUntil[id] = nil
        switch result {
        case .success(let reading):
            if let account = accounts.first(where: { $0.id == id }) {
                decideNotifications(for: account, new: reading)
            }
            readings[id] = reading
            restored.remove(id)
            failures[id] = nil
        case .failure(let failure):
            failures[id] = failure
            if case .rateLimited(let retryAfter) = failure {
                backOffUntil[id] = now() + (retryAfter ?? Self.defaultBackOff)
            }
        }
    }

    /// True while the Account waits out a rate limit.
    private func isBackedOff(_ id: UUID) -> Bool {
        guard let until = backOffUntil[id] else { return false }
        return now() < until
    }

    /// Global "Notifications" switch (General tab), persisted as `AppConfig.notificationsEnabled`.
    var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            config.update { $0.notificationsEnabled = notificationsEnabled }
            coreLog.info("Notifications \(self.notificationsEnabled ? "enabled" : "disabled", privacy: .public)")
            NotificationCenter.default.post(name: .tokenMeterNotificationsSwitch, object: nil,
                                            userInfo: ["enabled": notificationsEnabled])
        }
    }

    /// Sets the global switch. Requesting UNUserNotificationCenter permission is the caller's
    /// job (App layer) when this turns it on.
    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    /// Sets one Account's notification threshold (Off/80/90/95) and persists it.
    func setNotificationThreshold(_ threshold: NotificationThreshold, for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].threshold != threshold else { return }
        accounts[index].threshold = threshold
        persist()
    }

    // MARK: - Notifications (seam B)

    /// Applies the notification decision to one Account's fresh Reading: posts what it returns
    /// and persists the updated already-notified set with the config.
    func decideNotifications(for account: Account, new: Reading) {
        let (toSend, updated) = NotificationDecision.decide(
            new: new, account: account,
            settings: AccountNotificationSettings(threshold: account.threshold,
                                                  showAllWindows: account.showAllWindows),
            notificationsEnabled: notificationsEnabled, notified: NotifiedKeySet(keys: notifiedKeys),
            now: now())
        let changed = updated.keys != notifiedKeys
        notifiedKeys = updated.keys
        if !toSend.isEmpty {
            NotificationCenter.default.post(name: .tokenMeterNotification, object: toSend)
            coreLog.info("Notifications decided for \(account.id, privacy: .public): \(toSend.count, privacy: .public) to send")
        }
        if changed {
            config.update { $0.alreadyNotified = updated.keys }
        }
    }

    // MARK: - Refresh

    /// A popover opened within this long of the newest Reading doesn't trigger a refresh.
    static let freshness: TimeInterval = 60

    /// Refreshes every Account in parallel. A popover-triggered refresh only runs when the
    /// newest Reading is older than `freshness`.
    func refreshAll(_ trigger: RefreshTrigger) async {
        if trigger == .popoverOpened, let lastUpdated, now().timeIntervalSince(lastUpdated) <= Self.freshness {
            coreLog.info("Refresh (popover) skipped: newest Reading is \(Int(self.now().timeIntervalSince(lastUpdated)), privacy: .public) s old")
            return
        }
        coreLog.info("Refresh (\(trigger.rawValue, privacy: .public)) of \(self.accounts.count, privacy: .public) Accounts")
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account.id) }
            }
        }
    }

    /// Refreshes one Account unless a fetch for it is already in flight or it is backed off.
    func refresh(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }), !refreshing.contains(id) else { return }
        guard !isBackedOff(id) else {
            coreLog.info("Skipping \(id, privacy: .public): backed off after a rate limit")
            return
        }
        guard let reader = readerFor(account.kind) else {
            record(.failure(.unavailable("\(account.kind.displayName) is not supported yet")), for: id)
            return
        }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        let result = await reader.read(account, session: session, now: now())
        // The Account may have been removed while the fetch was in flight.
        guard accounts.contains(where: { $0.id == id }) else { return }
        record(result, for: id)
        switch result {
        case .success:
            coreLog.info("Reading for \(id, privacy: .public): ok")
        case .failure(let failure):
            coreLog.notice("Reading for \(id, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
        }
    }

    private func persist() {
        let accounts = accounts
        config.update { $0.accounts = accounts }
    }

    private func persistReadings() {
        let readings = accounts.compactMap { readings[$0.id] }
        config.update { $0.readings = readings }
    }
}

/// What started a refresh of all Accounts.
enum RefreshTrigger: String, Sendable {
    case launch, scheduled, popoverOpened = "popover", manual
}
