import SwiftUI

/// Checks a DeepSeek API key by taking a Reading with it.
enum DeepSeekKeyCheck {
    @MainActor
    static func check(_ key: String, account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        await DeepSeekProvider.live.read(account: account, credentials: DeepSeekCredentials(apiKey: key),
                                         session: store.session, now: Date()).outcome
    }

    /// Clear message for a key that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "DeepSeek rejected this API key. Create a new key at platform.deepseek.com/api_keys and paste it here."
        case .rateLimited(let retryAfter?):
            "DeepSeek is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "DeepSeek is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label plus API key, validated before the Account is created.
struct DeepSeekAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.deepseek.displayName
    @State private var apiKey = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("DeepSeek API key", text: $apiKey)
            Text("Create a key at [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys). It is stored in your Keychain.")
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
                .disabled(checking || DeepSeekKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func add() async {
        let key = DeepSeekKeyCheck.normalized(apiKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .deepseek, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await DeepSeekKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try DeepSeekProvider.credentialSource.save(DeepSeekCredentials(apiKey: key), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = DeepSeekKeyCheck.message(for: failure)
        }
    }
}

/// DeepSeek-specific Account settings: replace the API key (e.g. after it was revoked).
struct DeepSeekAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var apiKey = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("Replacing this key validates it against DeepSeek's balance endpoint.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SecureField("New DeepSeek API key", text: $apiKey)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Key") { Task { await replace() } }
                .disabled(checking || DeepSeekKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func replace() async {
        let key = DeepSeekKeyCheck.normalized(apiKey)
        checking = true
        message = nil
        defer { checking = false }
        switch await DeepSeekKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try DeepSeekProvider.credentialSource.save(DeepSeekCredentials(apiKey: key), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Key saved.", false)
        case .failure(let failure):
            message = (DeepSeekKeyCheck.message(for: failure), true)
        }
    }
}
