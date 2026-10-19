import SwiftUI

/// Checks a Venice.ai API key by taking a Reading with it.
enum VeniceKeyCheck {
    @MainActor
    static func check(_ key: String, account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        await VeniceProvider.live.read(account: account, credentials: VeniceCredentials(apiKey: key),
                                       session: store.session, now: Date()).outcome
    }

    /// Clear message for a key that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "Venice.ai needs an Admin API key to read billing; inference keys are rejected. Create an Admin key at venice.ai/settings/api and paste it here."
        case .rateLimited(let retryAfter?):
            "Venice.ai is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Venice.ai is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label plus API key, validated before the Account is created.
struct VeniceAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.venice.displayName
    @State private var apiKey = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("Admin API key", text: $apiKey)
            Text("Venice.ai requires an **Admin** API key to read billing; inference keys are rejected. Create one at [venice.ai/settings/api](https://venice.ai/settings/api). It is stored in your Keychain.")
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
                .disabled(checking || VeniceKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func add() async {
        let key = VeniceKeyCheck.normalized(apiKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .venice, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await VeniceKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try VeniceProvider.credentialSource.save(VeniceCredentials(apiKey: key), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = VeniceKeyCheck.message(for: failure)
        }
    }
}

/// Venice-specific Account settings: replace the API key (e.g. after it was revoked).
struct VeniceAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var apiKey = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("Replacing this key needs another **Admin** API key; the daily DIEM progress uses the billing endpoint.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SecureField("New Admin API key", text: $apiKey)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Key") { Task { await replace() } }
                .disabled(checking || VeniceKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func replace() async {
        let key = VeniceKeyCheck.normalized(apiKey)
        checking = true
        message = nil
        defer { checking = false }
        switch await VeniceKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try VeniceProvider.credentialSource.save(VeniceCredentials(apiKey: key), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Key saved.", false)
        case .failure(let failure):
            message = (VeniceKeyCheck.message(for: failure), true)
        }
    }
}
