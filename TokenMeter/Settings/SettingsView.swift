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
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsRouter.Tab.general)
        }
        .padding()
        .frame(width: 520, height: 360)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            AppBehaviourSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
