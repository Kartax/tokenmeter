import SwiftUI

/// Checks a Mistral Admin API key by taking a Reading with it.
enum MistralKeyCheck {
    @MainActor
    static func check(_ key: String, account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        await MistralProvider.live.read(account: account, credentials: MistralCredentials(adminKey: key),
                                        session: store.session, now: Date()).outcome
    }

    /// Clear message for a key that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "Mistral needs an Organization Admin API key from an Enterprise plan. Create one at backoffice.mistral.ai; standard inference keys do not work."
        case .rateLimited(let retryAfter?):
            "Mistral is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Mistral is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label plus Admin API key, validated before the Account is created.
struct MistralAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.mistral.displayName
    @State private var adminKey = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("Admin API key", text: $adminKey)
            Text("Mistral's spend limit is an Organization Admin API, so it needs an **Enterprise** plan and an Admin API key created at [backoffice.mistral.ai](https://backoffice.mistral.ai). Standard inference keys do not work. The key is stored in your Keychain.")
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
                .disabled(checking || MistralKeyCheck.normalized(adminKey).isEmpty)
        }
    }

    private func add() async {
        let key = MistralKeyCheck.normalized(adminKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .mistral, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await MistralKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try MistralProvider.credentialSource.save(MistralCredentials(adminKey: key), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = MistralKeyCheck.message(for: failure)
        }
    }
}

/// Mistral-specific Account settings: replace the Admin API key (e.g. after it was revoked).
struct MistralAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var adminKey = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("Replacing this key needs another **Admin** API key from an Enterprise plan (backoffice.mistral.ai); inference keys cannot read the Organization spend limit.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SecureField("New Admin API key", text: $adminKey)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Key") { Task { await replace() } }
                .disabled(checking || MistralKeyCheck.normalized(adminKey).isEmpty)
        }
    }

    private func replace() async {
        let key = MistralKeyCheck.normalized(adminKey)
        checking = true
        message = nil
        defer { checking = false }
        switch await MistralKeyCheck.check(key, account: account, store: store) {
        case .success(let reading):
            do {
                try MistralProvider.credentialSource.save(MistralCredentials(adminKey: key), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            adminKey = ""
            message = ("Key saved.", false)
        case .failure(let failure):
            message = (MistralKeyCheck.message(for: failure), true)
        }
    }
}
