import Observation
import Foundation

/// Opens the Settings window on a given tab or Account, e.g. from the popover's "Sign in again"
/// link. `AppDelegate` owns one, injects it with `.environment(_:)` into the popover and Settings,
/// and sets `showWindow`.
@MainActor @Observable
final class SettingsRouter {
    enum Tab: Hashable { case accounts, general }

    var tab: Tab = .accounts
    /// Account the Accounts tab should select; the tab consumes it (sets it back to nil).
    var accountToSelect: UUID?
    /// Brings the Settings window to the front.
    @ObservationIgnored var showWindow: () -> Void = {}

    /// Shows the Account's settings in the Accounts tab.
    func showAccount(_ id: UUID) {
        tab = .accounts
        accountToSelect = id
        showWindow()
    }
}

extension ProviderKind {
    /// Whether an expired login is fixed in Settings (sign in again, replace the API key), so the
    /// popover links to the Account there. Claude is fixed by running `claude` (ADR 0001).
    var recoversInSettings: Bool { self != .claude }
}
