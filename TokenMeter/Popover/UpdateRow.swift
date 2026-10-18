import SwiftUI
import AppKit

/// "New version available (vX.Y.Z)" row, shown only while the update checker offers a
/// newer release; clicking it opens the homepage.
struct UpdateRow: View {
    private let updateChecker = UpdateChecker.shared

    var body: some View {
        if let version = updateChecker.availableUpdate {
            Button {
                NSWorkspace.shared.open(UpdateChecker.homepageURL)
            } label: {
                Label("New version available (v\(version))", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
        }
    }
}
