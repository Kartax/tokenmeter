import XCTest
@testable import TokenMeter

/// Account order, per-Account "show all Windows" and the poll interval persist across launches.
@MainActor
final class AccountStoreSettingsTests: XCTestCase {
    private var configDirectory: URL!

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
        return AccountStore(config: config, readerFor: { _ in reader })
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
}
