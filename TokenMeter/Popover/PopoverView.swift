import SwiftUI

/// Compact popover content: Account rows (later tickets) or the empty state, plus a footer.
struct PopoverView: View {
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("No Accounts yet — open Settings")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            Divider()
            PopoverFooter(onOpenSettings: onOpenSettings, onQuit: onQuit)
        }
        .frame(width: 300)
    }
}

private struct PopoverFooter: View {
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        HStack {
            Button("Settings…", action: onOpenSettings)
            Spacer()
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
