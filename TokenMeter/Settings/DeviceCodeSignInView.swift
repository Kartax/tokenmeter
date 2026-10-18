import AppKit
import SwiftUI

/// Device-code sign-in for any `DeviceCodeFlow` (Codex, Nous): requests a one-time code, shows it,
/// opens the browser on the verification page, waits for approval, and hands the credentials to
/// `complete`. Cancel stops polling. Expiry and server refusals are shown with "Try Again".
///
/// Host it in a sheet (it brings no padding or frame of its own beyond its content).
struct DeviceCodeSignInView<Flow: DeviceCodeFlow>: View {
    /// e.g. "Sign in with ChatGPT".
    var title: String
    var flow: Flow
    var session: URLSession
    /// Stores the approved credentials (Keychain first, then a first Reading). Returns an error
    /// message to show, or nil when signed in.
    var complete: @MainActor (Flow.Credentials) async -> String?
    /// Called once when the view should close: nil when signed in, otherwise the message to show
    /// next to the Account (cancelled, expired, refused).
    var onFinish: @MainActor (_ failureMessage: String?) -> Void

    private enum Phase: Equatable {
        case requesting
        case waiting(DeviceCode)
        case finishing
        case failed(String)
    }

    @State private var phase = Phase.requesting
    @State private var attempt = 0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .task(id: attempt) { await run() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .requesting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Requesting a code…").foregroundStyle(.secondary)
            }
        case .waiting(let code):
            Text("Enter this code on the page that opened in your browser:")
            HStack(spacing: 12) {
                Text(code.userCode)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    copied = true
                }
            }
            Link("Open \(code.verificationURL.host() ?? "the verification page") again", destination: code.verificationURL)
                .font(.callout)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Waiting for approval · code expires \(DisplayFormat().resetTime(code.expiresAt, now: context.date))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        case .finishing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Signed in. Taking a first Reading…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch phase {
        case .failed(let message):
            Button("Close") { onFinish(message) }
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { attempt += 1 }
                .keyboardShortcut(.defaultAction)
        case .finishing:
            EmptyView()
        case .requesting, .waiting:
            Button("Cancel") { onFinish(DeviceCodeFailure.cancelled.message) }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// One sign-in attempt; cancelled (with polling) when the view disappears or retries.
    private func run() async {
        phase = .requesting
        copied = false
        let challenge: DeviceCodeChallenge<Flow.Pending>
        switch await flow.requestCode(session: session, now: Date()) {
        case .success(let started): challenge = started
        case .failure(let failure):
            if !Task.isCancelled { phase = .failed(failure.message) }
            return
        }
        guard !Task.isCancelled else { return }
        phase = .waiting(challenge.code)
        NSWorkspace.shared.open(challenge.code.verificationURL)

        switch await flow.awaitApproval(challenge, session: session, clock: .live) {
        case .success(let credentials):
            phase = .finishing
            if let message = await complete(credentials) {
                phase = .failed(message)
            } else {
                onFinish(nil)
            }
        case .failure(.cancelled):
            return
        case .failure(let failure):
            if !Task.isCancelled { phase = .failed(failure.message) }
        }
    }
}
