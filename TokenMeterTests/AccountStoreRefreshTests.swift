import XCTest
@testable import TokenMeter

/// Refresh scheduling decisions of `AccountStore`: freshness on popover open, per-Account
/// back-off, no duplicate in-flight refresh. Uses a scripted reader and an injected clock.
@MainActor
final class AccountStoreRefreshTests: XCTestCase {
    private var configDirectory: URL!
    private var reader: ScriptedReader!
    private var clock = date("2026-10-18T12:00:00Z")

    override func setUp() async throws {
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStoreRefreshTests-\(UUID())", isDirectory: true)
        reader = ScriptedReader()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configDirectory)
    }

    private var config: ConfigStore { ConfigStore(url: configDirectory.appendingPathComponent("config.json")) }

    private func makeStore() -> AccountStore {
        AccountStore(config: config, readerFor: { [reader] _ in reader }, now: { [unowned self] in clock })
    }

    private func addAccount(to store: AccountStore, label: String = "Personal") -> Account {
        let account = Account(kind: .ollama, label: label)
        store.add(account)
        return account
    }

    func testPopoverOpenRefreshesOnlyWhenNewestReadingIsOlderThan60Seconds() async {
        let store = makeStore()
        let account = addAccount(to: store)
        await store.refreshAll(.manual)
        XCTAssertEqual(reader.calls, [account.id])

        clock += 60
        await store.refreshAll(.popoverOpened)
        XCTAssertEqual(reader.calls.count, 1, "a 60 s old Reading is fresh enough")

        clock += 1
        await store.refreshAll(.popoverOpened)
        XCTAssertEqual(reader.calls.count, 2)
        XCTAssertEqual(store.readings[account.id]?.takenAt, clock)
    }

    func testRateLimitedAccountIsSkippedByEveryTriggerUntilItsBackOffEnds() async {
        let store = makeStore()
        let limited = addAccount(to: store, label: "Limited")
        let other = addAccount(to: store, label: "Other")
        reader.respond(to: limited.id, with: .failure(.rateLimited(retryAfter: 300)))
        await store.refreshAll(.scheduled)
        XCTAssertEqual(Set(reader.calls), [limited.id, other.id])

        for (offset, trigger) in [(61.0, RefreshTrigger.popoverOpened), (122, .manual), (183, .scheduled)] {
            clock = date("2026-10-18T12:00:00Z") + offset
            await store.refreshAll(trigger)
            XCTAssertEqual(reader.calls.last, other.id, "\(trigger) refreshes the other Account")
            XCTAssertEqual(reader.calls.filter { $0 == limited.id }.count, 1, "\(trigger) skips the backed-off Account")
        }

        clock = date("2026-10-18T12:05:00Z")
        await store.refreshAll(.manual)
        XCTAssertEqual(reader.calls.filter { $0 == limited.id }.count, 2, "back-off ended")
    }

    func testRateLimitWithoutRetryAfterBacksOffForAMinute() async {
        let store = makeStore()
        let account = addAccount(to: store)
        reader.respond(to: account.id, with: .failure(.rateLimited(retryAfter: nil)))
        await store.refreshAll(.manual)

        clock += 59
        await store.refreshAll(.manual)
        XCTAssertEqual(reader.calls.count, 1)

        clock += 1
        await store.refreshAll(.manual)
        XCTAssertEqual(reader.calls.count, 2)
    }

    func testRefreshAlreadyInFlightIsNotDuplicated() async {
        let store = makeStore()
        let account = addAccount(to: store)
        reader.holdReads = true
        let scheduled = Task { await store.refreshAll(.scheduled) }
        while reader.calls.isEmpty { await Task.yield() }

        await store.refreshAll(.manual)
        await store.refresh(account.id)
        XCTAssertEqual(reader.calls, [account.id])
        XCTAssertTrue(store.isRefreshing)

        reader.releaseReads()
        await scheduled.value
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.readings[account.id])
    }

    func testLastReadingsSurviveARelaunchAsStaleUntilRefreshed() async {
        let first = makeStore()
        let account = addAccount(to: first)
        let gone = addAccount(to: first, label: "Removed later")
        await first.refreshAll(.launch)
        let reading = first.readings[account.id]!
        first.remove(gone.id)

        clock += 3600
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.displayState(of: account), .stale(reading, note: "From last session"))
        XCTAssertNil(relaunched.readings[gone.id])
        XCTAssertEqual(relaunched.lastUpdated, reading.takenAt)

        await relaunched.refreshAll(.launch)
        XCTAssertEqual(relaunched.displayState(of: account),
                       .ok(Reading(accountID: account.id, takenAt: clock, quotas: [], credits: [])))
    }
}

/// Answers each read with the scripted result for the Account (default: a Reading taken
/// `now`) and records which Accounts were read. A gate can hold reads in flight.
final class ScriptedReader: AccountReader, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [UUID] = []
    private var _results: [UUID: Result<Reading, ReadingFailure>] = [:]
    private var _holdReads = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var calls: [UUID] { lock.withLock { _calls } }

    /// While true, reads stay in flight until `releaseReads()`.
    var holdReads: Bool {
        get { lock.withLock { _holdReads } }
        set { lock.withLock { _holdReads = newValue } }
    }

    func releaseReads() {
        let waiting = lock.withLock {
            _holdReads = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func respond(to id: UUID, with result: Result<Reading, ReadingFailure>) {
        lock.withLock { _results[id] = result }
    }

    func read(_ account: Account, session: URLSession, now: Date) async -> Result<Reading, ReadingFailure> {
        await withCheckedContinuation { continuation in
            let hold = lock.withLock {
                _calls.append(account.id)
                if _holdReads { held.append(continuation) }
                return _holdReads
            }
            if !hold { continuation.resume() }
        }
        return lock.withLock {
            _results[account.id]
                ?? .success(Reading(accountID: account.id, takenAt: now, quotas: [], credits: []))
        }
    }

    func deleteSecrets(for account: Account) throws {}
}
