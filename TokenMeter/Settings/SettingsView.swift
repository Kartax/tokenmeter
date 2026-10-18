import SwiftUI

/// Settings window content with the Accounts and General tabs.
struct SettingsView: View {
    var store: AccountStore
    @Environment(SettingsRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            AccountsSettingsView(store: store)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsRouter.Tab.accounts)
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsRouter.Tab.general)
        }
        .padding()
        .frame(width: 520, height: 360)
    }
}

struct GeneralSettingsView: View {
    @Bindable var store: AccountStore

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $store.pollIntervalMinutes) {
                    ForEach(AccountStore.pollIntervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
            }
            NotificationsSection(store: store)
            AppBehaviourSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The global "Notifications" switch (off by default). Turning it on requests the system's
/// notification permission — the only time it is asked for.
struct NotificationsSection: View {
    @Bindable var store: AccountStore

    var body: some View {
        Section {
            Toggle("Notifications", isOn: Binding(
                get: { store.notificationsEnabled },
                set: { store.setNotificationsEnabled($0) }
            ))
        } footer: {
            Text("Notify when usage crosses an Account's threshold or credits run low.")
        }
    }
}
