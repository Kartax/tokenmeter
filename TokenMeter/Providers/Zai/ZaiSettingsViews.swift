import SwiftUI

/// Checks a Z.ai API key by taking a Reading with it.
enum ZaiKeyCheck {
    @MainActor
    static func check(_ key: String, account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        await ZaiProvider.live.read(account: account, credentials: ZaiCredentials(apiKey: key),
                                    session: store.session, now: Date()).outcome
    }

    /// Clear message for a key that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "Z.ai rejected this API key. Create or copy a key in the Z.ai console under API Keys and paste it here."
        case .rateLimited(let retryAfter?):
            "Z.ai is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Z.ai is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label plus API key, validated before the Account is created.
struct ZaiAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.zai.displayName
    @State private var apiKey = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("API key", text: $apiKey)
            Text("The key is used for the GLM Coding Plan quota and web-search usage. It is stored in your Keychain.")
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
                .disabled(checking || ZaiKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func add() async {
        let key = ZaiKeyCheck.normalized(apiKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .zai, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await ZaiKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try ZaiProvider.credentialSource.save(ZaiCredentials(apiKey: key), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = ZaiKeyCheck.message(for: failure)
        }
    }
}

/// Z.ai-specific Account settings: replace the API key (e.g. after it was revoked).
struct ZaiAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var apiKey = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("Replacing this key takes a fresh Reading of the GLM Coding Plan quota.")
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
                .disabled(checking || ZaiKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func replace() async {
        let key = ZaiKeyCheck.normalized(apiKey)
        checking = true
        message = nil
        defer { checking = false }
        switch await ZaiKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try ZaiProvider.credentialSource.save(ZaiCredentials(apiKey: key), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Key saved.", false)
        case .failure(let failure):
            message = (ZaiKeyCheck.message(for: failure), true)
        }
    }
}
