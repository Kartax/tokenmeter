import Foundation
import Observation
import OSLog

private let updateLog = Logger(subsystem: "org.kartax.TokenMeter", category: "update")

/// Checks GitHub daily for a newer published release of TokenMeter. This is not an
/// auto-updater: it only reports the newer version, and the popover links to the homepage.
///
/// Releases are tagged `vX.Y.Z` in `Kartax/tokenmeter`; the unauthenticated GitHub API
/// (60 requests/hour per IP) is plenty for one check per day.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Public homepage the "New version available" row opens.
    static let homepageURL = URL(string: "https://kartax.github.io/tokenmeter/")!

    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/Kartax/tokenmeter/releases/latest")!

    /// The bundle's marketing version (CFBundleShortVersionString), e.g. "0.1.0".
    nonisolated static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Persistence key for the "Check for updates daily" toggle.
    /// Interim UserDefaults storage until the JSON config store (#3) lands; fold it into
    /// `AppConfig.checkForUpdates` (nil → true) there.
    private static let enabledKey = "checkForUpdates"

    /// Version of a newer release, without the leading "v"; nil when there is nothing to offer.
    private(set) var availableUpdate: String?

    /// The "Check for updates daily" setting (on by default). Turning it off stops the
    /// daily check and hides any offered update; turning it on checks right away.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            updateLog.info("Daily update check \(self.isEnabled ? "enabled" : "disabled", privacy: .public)")
            if isEnabled {
                start()
            } else {
                pollTask?.cancel()
                pollTask = nil
                availableUpdate = nil
            }
        }
    }

    private let session: URLSession
    private let currentVersion: String
    private let defaults: UserDefaults
    private let interval: Duration = .seconds(24 * 60 * 60)
    private var pollTask: Task<Void, Never>?

    init(session: URLSession = .shared,
         currentVersion: String = UpdateChecker.bundleVersion,
         defaults: UserDefaults = .standard) {
        self.session = session
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Checks now and then once a day while enabled. Call once on launch.
    func start() {
        pollTask?.cancel()
        guard isEnabled else {
            updateLog.info("Daily update check is off; not contacting GitHub")
            return
        }
        pollTask = Task { [weak self, interval] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Asks GitHub for the latest release and offers it when it is newer than the bundle.
    /// Makes no request while the setting is off. Failures, including 404 while no release
    /// exists yet, are silent: nothing is offered.
    func check() async {
        guard isEnabled else { return }
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                updateLog.info("Update check: GitHub returned \(status, privacy: .public)")
                return
            }
            let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
            // The setting may have been turned off while the request was in flight.
            guard isEnabled else { return }
            availableUpdate = Self.newerVersion(tag: tag, than: currentVersion)
            updateLog.info("Update check: latest \(tag, privacy: .public), running \(self.currentVersion, privacy: .public)")
        } catch {
            updateLog.info("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct Release: Decodable { let tag_name: String }

    /// The tag's version without "v" when it is newer than `current`, else nil.
    private static func newerVersion(tag: String, than current: String) -> String? {
        guard let latest = ReleaseVersion(tag), let running = ReleaseVersion(current),
              latest > running else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
