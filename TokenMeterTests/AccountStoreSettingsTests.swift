import XCTest
@testable import TokenMeter

/// Account order, per-Account "show all Windows", the poll interval and the already-notified
/// keys persist across launches.
@MainActor
final class AccountStoreSettingsTests: XCTestCase {
    private var configDirectory: URL!
    /// Fixed decision clock (notifications compare reset times against it).
    private var now = date("2026-10-18T12:00:00Z")

    override func setUp() async throws {
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStoreSettingsTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configDirectory)
    }

    private var config: ConfigStore { ConfigStore(url: configDirectory.appendingPathComponent("config.json")) }

    private func makeStore() -> AccountStore {
        let reader = ScriptedReader()
        return AccountStore(config: config, readerFor: { _ in reader }, now: { [unowned self] in now })
    }

    func testDraggingAnAccountReordersThemAndTheOrderPersists() {
        let store = makeStore()
        for label in ["A", "B", "C"] { store.add(Account(kind: .ollama, label: label)) }

        store.move(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(store.accounts.map(\.label), ["C", "A", "B"])

        store.move(fromOffsets: [1], toOffset: 3)
        XCTAssertEqual(store.accounts.map(\.label), ["C", "B", "A"])
        XCTAssertEqual(makeStore().accounts.map(\.label), ["C", "B", "A"])
    }

    func testShowAllWindowsIsPerAccountAndPersists() {
        let store = makeStore()
        let account = Account(kind: .ollama, label: "A")
        let other = Account(kind: .ollama, label: "B")
        store.add(account)
        store.add(other)

        store.setShowAllWindows(true, for: account.id)
        XCTAssertEqual(makeStore().accounts.map(\.showAllWindows), [true, false])

        store.setShowAllWindows(false, for: account.id)
        XCTAssertEqual(makeStore().accounts.map(\.showAllWindows), [false, false])
    }

    func testPollIntervalDefaultsToFiveMinutesAndPersists() {
        let store = makeStore()
        XCTAssertEqual(store.pollIntervalMinutes, 5)

        store.pollIntervalMinutes = 1
        XCTAssertEqual(makeStore().pollIntervalMinutes, 1)
    }

    func testUnsupportedStoredPollIntervalFallsBackToFiveMinutes() {
        config.update { $0.pollIntervalMinutes = 7 }
        XCTAssertEqual(makeStore().pollIntervalMinutes, 5)
    }

    // MARK: - Already-notified keys

    func testAlreadyNotifiedKeysPersistAndPruneOnLoad() {
        // A past period's key is dropped on load; an active one survives a relaunched store.
        let store = makeStore()
        let account = Account(kind: .ollama, label: "A")
        store.add(account)
        let past = date("2026-03-01T09:00:00Z")
        let week = date("2026-10-25T09:00:00Z")
        let session = date("2026-10-18T17:00:00Z")
        store.record(.success(Reading(accountID: account.id, takenAt: now, quotas: [], credits: [])), for: account.id)
        store.decideNotifications(
            for: account, previous: store.readings[account.id],
            new: Reading(accountID: account.id, takenAt: now,
                         quotas: [Quota(window: Window(identity: .session, title: "Session", isMain: true,
                                       resetsAt: session), percentUsed: 91),
                                  Quota(window: Window(identity: .week, title: "Week", isMain: true,
                                        resetsAt: week), percentUsed: 91)],
                         credits: []),
            notificationsEnabled: true)
        XCTAssertFalse(store.notifiedKeys.isEmpty, "the crossing's keys are persisted with the config")

        // Relaunch: the past key is pruned, the fresh one kept.
        config.update { $0.alreadyNotified = [
            NotifiedKey(accountID: account.id, window: .session, resetAt: past),
            NotifiedKey(accountID: account.id, window: .week, resetAt: week),
        ] }
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.notifiedKeys, Set([
            NotifiedKey(accountID: account.id, window: .week, resetAt: week),
        ]))
    }
}
