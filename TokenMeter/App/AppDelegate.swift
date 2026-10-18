import SwiftUI
import AppKit

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
        appLog.info("TokenMeter launched")
        Task { await store.refreshAll() }
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
