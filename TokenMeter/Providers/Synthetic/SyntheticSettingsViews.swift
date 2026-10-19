import SwiftUI

/// Checks a Synthetic API key by taking a Reading with it.
enum SyntheticKeyCheck {
    @MainActor
    static func check(_ key: String, account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        await SyntheticProvider.live.read(account: account, credentials: SyntheticCredentials(apiKey: key),
                                          session: store.session, now: Date()).outcome
    }

    /// Clear message for a key that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "Synthetic rejected this API key. Create one at dev.synthetic.new and paste it here."
        case .rateLimited(let retryAfter?):
            "Synthetic is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Synthetic is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label plus API key, validated before the Account is created.
struct SyntheticAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.synthetic.displayName
    @State private var apiKey = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("API key", text: $apiKey)
            Text("Synthetic API keys are created at [dev.synthetic.new](https://dev.synthetic.new/docs/api/getting-started). The key is stored in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        HStack {
            if checking {
                ProgressView().controlSize(.small)
                Text("Checking key…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Add") { Task { await add() } }
                .keyboardShortcut(.defaultAction)
                .disabled(checking || SyntheticKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func add() async {
        let key = SyntheticKeyCheck.normalized(apiKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .synthetic, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await SyntheticKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try SyntheticProvider.credentialSource.save(SyntheticCredentials(apiKey: key), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = SyntheticKeyCheck.message(for: failure)
        }
    }
}

/// Synthetic-specific Account settings: replace the API key (e.g. after it was revoked).
struct SyntheticAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var apiKey = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("The quotas come from Synthetic's `/v2/quotas` endpoint; replacing the key validates it first.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SecureField("New API key", text: $apiKey)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Key") { Task { await replace() } }
                .disabled(checking || SyntheticKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func replace() async {
        let key = SyntheticKeyCheck.normalized(apiKey)
        checking = true
        message = nil
        defer { checking = false }
        switch await SyntheticKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try SyntheticProvider.credentialSource.save(SyntheticCredentials(apiKey: key), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Key saved.", false)
        case .failure(let failure):
            message = (SyntheticKeyCheck.message(for: failure), true)
        }
    }
}
