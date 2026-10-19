import SwiftUI

/// Checks Antigravity's borrowed local login by taking a Reading with it.
enum AntigravityKeyCheck {
    @MainActor
    static func check(account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        let credentials: AntigravityCredentials
        switch AntigravityProvider.credentialSource.load(for: account) {
        case .success(let loaded):
            credentials = loaded
        case .failure(let failure):
            return .failure(failure)
        }
        return await AntigravityProvider.live.read(account: account, credentials: credentials,
                                                   session: store.session, now: Date()).outcome
    }

    /// Clear message for a local login that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "No valid Antigravity login found. Open Antigravity or run `agy login`, then try again."
        case .rateLimited(let retryAfter?):
            "Antigravity is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Antigravity is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not read Antigravity usage: \(message)"
        }
    }
}

/// Add-Account form: no secret is entered; the local Antigravity login is checked before adding.
struct AntigravityAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.antigravity.displayName
    @State private var checking = false
    @State private var failure: ReadingFailure?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            Text("TokenMeter reads the local Antigravity login from `~/.gemini/antigravity-cli/antigravity-oauth-token` or the “gemini” Keychain item. It never stores or refreshes the borrowed token.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(AntigravityKeyCheck.message(for: failure), systemImage: "exclamationmark.triangle.fill")
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
            Button(failure == nil ? "Add" : "Try Again") { Task { await add() } }
                .keyboardShortcut(.defaultAction)
                .disabled(checking)
        }
    }

    private func add() async {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .antigravity, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        failure = nil
        defer { checking = false }
        switch await AntigravityKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            self.failure = failure
        }
    }
}

/// Antigravity Account settings: the borrowed login is read fresh on every refresh.
struct AntigravityAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("TokenMeter reads this Mac's Antigravity login each time it refreshes and never stores, copies or refreshes the token. If Antigravity is logged out, open it or run `agy login`.")
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
            Button("Check Login") { Task { await check() } }
                .disabled(checking)
        }
    }

    private func check() async {
        checking = true
        message = nil
        defer { checking = false }
        switch await AntigravityKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.record(.success(reading), for: account.id)
            message = ("Login works — quotas updated.", false)
        case .failure(let failure):
            message = (AntigravityKeyCheck.message(for: failure), true)
        }
    }
}
