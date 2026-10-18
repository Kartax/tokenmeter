import SwiftUI

/// Settings window content with the Accounts and General tabs.
struct SettingsView: View {
    var store: AccountStore

    var body: some View {
        TabView {
            AccountsSettingsView(store: store)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding()
        .frame(width: 520, height: 360)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {}
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
