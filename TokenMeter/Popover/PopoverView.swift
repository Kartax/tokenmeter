import SwiftUI

/// Compact popover content: one row per Account (or the empty state), plus a footer.
struct PopoverView: View {
    var store: AccountStore
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                Text("No Accounts yet — open Settings")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.accounts) { account in
                        AccountRowView(account: account, state: store.displayState(of: account))
                    }
                }
                .padding(12)
            }
            Divider()
            UpdateRow()
            PopoverFooter(store: store, onOpenSettings: onOpenSettings, onQuit: onQuit)
        }
        .frame(width: 300)
    }
}

private struct PopoverFooter: View {
    var store: AccountStore
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        HStack {
            if let updated = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Updated \(DisplayFormat().age(of: updated, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await store.refreshAll(.manual) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(store.isRefreshing || store.accounts.isEmpty)
            Spacer()
            Button("Settings…", action: onOpenSettings)
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
