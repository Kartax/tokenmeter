import Foundation
import SwiftUI

/// Checks Gemini CLI's local login by taking a Reading with it.
enum GeminiKeyCheck {
    @MainActor
    static func check(account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        switch GeminiProvider.credentialSource.load(for: account) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let credentials):
            return await GeminiProvider.live.read(account: account, credentials: credentials,
                                                  session: store.session, now: Date()).outcome
        }
    }

    /// Clear message for a login that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "No valid Gemini CLI login found. Run `gemini` to sign in, then try again."
        case .rateLimited(let retryAfter?):
            "Gemini is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Gemini is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not read Gemini usage: \(message)"
        }
    }

    /// The credential file as shown to the user, with the home directory abbreviated to `~`.
    static var displayedCredentialsPath: String {
        (GeminiCredentialSource.credentialsPath as NSString).abbreviatingWithTildeInPath
    }
}

/// Add-Account form: label only; the login itself is borrowed from Gemini CLI.
struct GeminiAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.gemini.displayName
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            Text("TokenMeter reads the Gemini CLI login from \(GeminiKeyCheck.displayedCredentialsPath) on every refresh and never stores, copies or writes it back. Run `gemini` to sign in first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            if checking {
                ProgressView().controlSize(.small)
                Text("Reading usage…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Add") { Task { await add() } }
                .keyboardShortcut(.defaultAction)
                .disabled(checking)
        }
    }

    private func add() async {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .gemini, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await GeminiKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = GeminiKeyCheck.message(for: failure)
        }
    }
}

/// Gemini-specific Account settings: where the borrowed login lives and a way to re-check it.
struct GeminiAccountSettings: View {
    var store: AccountStore? = nil
    var account: Account
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        LabeledContent("Gemini CLI login", value: GeminiKeyCheck.displayedCredentialsPath)
        Text("If the login has expired, run `gemini` to sign in again; TokenMeter picks up the new token on the next refresh and never writes the file.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            if store != nil {
                Button("Check Login") { Task { await check() } }
                    .disabled(checking)
            }
        }
    }

    private func check() async {
        guard let store else { return }
        checking = true
        message = nil
        defer { checking = false }
        switch await GeminiKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.record(.success(reading), for: account.id)
            message = ("Login works.", false)
        case .failure(let failure):
            message = (GeminiKeyCheck.message(for: failure), true)
        }
    }
}
