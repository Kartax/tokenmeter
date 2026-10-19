import SwiftUI

/// Checks an OpenCode Zen/Go API key by taking a Reading with it.
enum OpenCodeKeyCheck {
    @MainActor
    static func check(_ key: String, account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        await OpenCodeProvider.live.read(account: account, credentials: OpenCodeCredentials(apiKey: key),
                                         session: store.session, now: Date()).outcome
    }

    /// Clear message for a key that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "OpenCode rejected this API key. Create or copy a key at opencode.ai/auth and paste it here."
        case .rateLimited(let retryAfter?):
            "OpenCode is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "OpenCode is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label plus API key, validated before the Account is created.
struct OpenCodeAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.opencode.displayName
    @State private var apiKey = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("OpenCode API key", text: $apiKey)
            Text("The key must belong to an OpenCode Go subscription. Create one at [opencode.ai/auth](https://opencode.ai/auth). It is stored in your Keychain.")
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
                .disabled(checking || OpenCodeKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func add() async {
        let key = OpenCodeKeyCheck.normalized(apiKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .opencode, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await OpenCodeKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try OpenCodeProvider.credentialSource.save(OpenCodeCredentials(apiKey: key), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = OpenCodeKeyCheck.message(for: failure)
        }
    }
}

/// OpenCode-specific Account settings: replace the API key (e.g. after it was revoked).
struct OpenCodeAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var apiKey = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("Replace the key after revoking it or switching to another OpenCode Go subscription.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SecureField("New OpenCode API key", text: $apiKey)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Key") { Task { await replace() } }
                .disabled(checking || OpenCodeKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func replace() async {
        let key = OpenCodeKeyCheck.normalized(apiKey)
        checking = true
        message = nil
        defer { checking = false }
        switch await OpenCodeKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try OpenCodeProvider.credentialSource.save(OpenCodeCredentials(apiKey: key), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Key saved.", false)
        case .failure(let failure):
            message = (OpenCodeKeyCheck.message(for: failure), true)
        }
    }
}
