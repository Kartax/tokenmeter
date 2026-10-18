import SwiftUI

/// Settings window content with the Accounts and General tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding()
        .frame(width: 520, height: 360)
    }
}

struct AccountsSettingsView: View {
    var body: some View {
        Text("No Accounts yet")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
