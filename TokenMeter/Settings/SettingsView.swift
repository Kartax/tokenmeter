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
            AppBehaviourSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
