import SwiftUI
import AppKit
import ServiceManagement

/// General-tab rows for app behaviour: launch at login, the daily update check, and the version.
struct AppBehaviourSection: View {
    /// Login-item registration is owned by the OS, so it's re-read rather than persisted.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Bindable private var updateChecker = UpdateChecker.shared

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            Toggle("Check for updates daily", isOn: $updateChecker.isEnabled)
            LabeledContent("Version") {
                HStack(spacing: 8) {
                    Text(Self.versionString)
                        .textSelection(.enabled)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
            }
        }
        // The Settings window is cached and the user may change Login Items in System
        // Settings meanwhile, so re-read the OS-owned state whenever a window becomes key.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            appLog.info("Launch at login \(enabled ? "registered" : "unregistered", privacy: .public)")
        } catch {
            appLog.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// "0.1.0 (1)": marketing version plus build number.
    private static var versionString: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(UpdateChecker.bundleVersion) (\(build))"
    }
}
