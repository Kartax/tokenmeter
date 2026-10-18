import SwiftUI
import AppKit
import OSLog

/// Logger for the app; filter with `log stream --predicate 'subsystem == "org.kartax.TokenMeter"'`.
let appLog = Logger(subsystem: "org.kartax.TokenMeter", category: "app")

@main
struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives entirely in the AppKit status item (see AppDelegate); this app
        // has no normal window. A `Settings` scene satisfies the `App` protocol without
        // showing anything (the app is LSUIElement, so it's never surfaced).
        Settings { EmptyView() }
    }
}
