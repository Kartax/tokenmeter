import Foundation

/// Non-secret configuration, persisted as JSON. Every field is optional (immich `AppConfig`
/// pattern): defaults are applied by readers, so old and new files decode without migrations.
/// Never put secrets here; they belong in the Keychain (`KeychainStore`).
struct AppConfig: Codable, Equatable {
    /// Configured Accounts. Entries that fail to decode (e.g. an unknown Provider) are dropped.
    var accounts: [Account]?
    /// Daily update check (General tab); nil means on.
    var checkForUpdates: Bool?
    /// Last Reading per Account, shown stale right after launch. Undecodable entries are dropped.
    var readings: [Reading]?
    /// Background poll interval in minutes (General tab); see `AccountStore.pollIntervals`.
    var pollIntervalMinutes: Int?
    /// Notification keys already sent, per Account + Window/Credit identity + reset/renewal
    /// time; persisted so a restart doesn't repeat a notification.
    var alreadyNotified: Set<NotifiedKey>?
    /// Global Notifications switch (General tab); nil means off (permission never requested).
    var notificationsEnabled: Bool?

    init(accounts: [Account]? = nil, checkForUpdates: Bool? = nil) {
        self.accounts = accounts
        self.checkForUpdates = checkForUpdates
    }

    private enum CodingKeys: String, CodingKey {
        case accounts, checkForUpdates, readings, pollIntervalMinutes, alreadyNotified, notificationsEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try? c.decodeIfPresent([Lossy<Account>].self, forKey: .accounts)?.compactMap(\.value)
        checkForUpdates = try? c.decodeIfPresent(Bool.self, forKey: .checkForUpdates)
        readings = try? c.decodeIfPresent([Lossy<Reading>].self, forKey: .readings)?.compactMap(\.value)
        pollIntervalMinutes = try? c.decodeIfPresent(Int.self, forKey: .pollIntervalMinutes)
        alreadyNotified = try? c.decodeIfPresent(Set<NotifiedKey>.self, forKey: .alreadyNotified)
        notificationsEnabled = try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)
    }
}

/// Decodes an element or yields nil instead of failing the whole array.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Reads and atomically writes `AppConfig` at `~/Library/Application Support/TokenMeter/config.json`.
struct ConfigStore: Sendable {
    let url: URL

    static let defaultURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TokenMeter", isDirectory: true)
        .appendingPathComponent("config.json")

    init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    /// The stored config, or an empty one when the file is missing or unreadable.
    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return config
    }

    func save(_ config: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            coreLog.error("Writing config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read-modify-write.
    func update(_ change: (inout AppConfig) -> Void) {
        var config = load()
        change(&config)
        save(config)
    }
}
