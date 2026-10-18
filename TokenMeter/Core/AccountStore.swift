import Foundation
import Observation

/// App state shared by the popover and Settings: the configured Accounts (persisted in the
/// config file), plus the last Reading and last failure per Account (in memory).
@MainActor @Observable
final class AccountStore {
    /// Accounts in display order.
    private(set) var accounts: [Account]
    private(set) var readings: [UUID: Reading] = [:]
    private(set) var failures: [UUID: ReadingFailure] = [:]
    /// Accounts with a fetch in flight; a refresh of one of these is never duplicated.
    private(set) var refreshing: Set<UUID> = []

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
        accounts = (config.load().accounts ?? []).sorted { $0.order < $1.order }
    }

    /// Time of the newest Reading, for the popover footer.
    var lastUpdated: Date? { readings.values.map(\.takenAt).max() }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func displayState(of account: Account) -> AccountDisplayState {
        AccountDisplayState(lastReading: readings[account.id], lastFailure: failures[account.id])
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
        persist()
        coreLog.info("Removed Account \(id, privacy: .public)")
    }

    /// Stores the outcome of a fetch made outside `refresh` (e.g. after replacing an API key).
    func record(_ result: Result<Reading, ReadingFailure>, for id: UUID) {
        switch result {
        case .success(let reading):
            readings[id] = reading
            failures[id] = nil
        case .failure(let failure):
            failures[id] = failure
        }
    }

    // MARK: - Refresh

    /// Refreshes every Account in parallel.
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account.id) }
            }
        }
    }

    func refresh(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }), !refreshing.contains(id) else { return }
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
}
