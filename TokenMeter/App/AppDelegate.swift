import SwiftUI
import AppKit
import UserNotifications

/// Sends the notifications decided in Core (seam B) and owns the permission request: the
/// system asks only when the Notifications switch is first enabled.
@MainActor
final class NotificationSender {
    static let shared = NotificationSender()

    private let center = UNUserNotificationCenter.current()

    /// Permission was granted (or already determined) for the current setting state.
    private(set) var permissionDenied = false

    func start(store: AccountStore) {
        observeDecisions(store: store)
        observeSwitch(store: store)
        // Permission is requested only when the switch is first enabled (Settings).
    }

    private func observeDecisions(store: AccountStore) {
        NotificationCenter.default.addObserver(
            forName: .tokenMeterNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let sent = note.object as? [OutgoingNotification] else { return }
            Task { @MainActor in self.send(sent) }
        }
    }

    private func observeSwitch(store: AccountStore) {
        NotificationCenter.default.addObserver(
            forName: .tokenMeterNotificationsSwitch, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["enabled"] as? Bool == true else { return }
            Task { @MainActor in self.requestPermission() }
        }
    }

    /// Asks the system for notification permission; a denial is remembered so sends stay quiet.
    func requestPermission() {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self.permissionDenied = !granted }
                }
            } else {
                Task { @MainActor in self.permissionDenied = settings.authorizationStatus == .denied }
            }
        }
    }

    /// Posts one `UNMutableNotificationContent` per decided notification.
    private func send(_ notifications: [OutgoingNotification]) {
        guard !permissionDenied else {
            appLog.info("Notifications denied; dropping \(notifications.count, privacy: .public)")
            return
        }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            // Identifying per reset period: a re-sent id replaces rather than duplicates.
            let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    appLog.error("Posting notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        appLog.info("Sent \(notifications.count, privacy: .public) notification(s)")
    }
}

/// Owns the status item, its popover, and the cached Settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private let store = AccountStore()
    private let router = SettingsRouter()

    /// Static gauge icon; a template image so the system tints it for light/dark menu bars.
    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                            accessibilityDescription: "TokenMeter")
        image?.isTemplate = true
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        router.showWindow = { [weak self] in self?.openSettings() }
        setupStatusItem()
        UpdateChecker.shared.start()
        NotificationSender.shared.start(store: store)
        appLog.info("TokenMeter launched")
        Task { await store.refreshAll(.launch) }
        store.startPolling()
    }

    /// Keep the app alive when the Settings window is closed (it's a menu bar app).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        appLog.info("TokenMeter terminating")
    }

    // MARK: - Status item and popover

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let popover = NSPopover()
        // `.transient` closes on outside clicks; NSPopover closes on Escape itself.
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            store: store,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApplication.shared.terminate(nil) }
        ).environment(router))
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            appLog.debug("Popover opened")
            Task { await store.refreshAll(.popoverOpened) }
        }
    }

    private func openSettings() {
        popover.close()
        showSettings()
    }

    // MARK: - Settings window (AppKit-hosted SwiftUI)

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(store: store).environment(router)))
            window.title = "TokenMeter Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            appLog.info("Settings window created")
        } else {
            appLog.info("Settings window reused")
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
