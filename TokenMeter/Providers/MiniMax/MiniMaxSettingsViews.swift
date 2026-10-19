import SwiftUI

/// Checks a MiniMax Token Plan API key by taking a Reading with it.
enum MiniMaxKeyCheck {
    @MainActor
    static func check(_ key: String, region: MiniMaxRegion, account: Account, store: AccountStore) async
        -> Result<Reading, ReadingFailure> {
        await MiniMaxProvider.live.read(account: account,
                                        credentials: MiniMaxCredentials(apiKey: key, region: region),
                                        session: store.session, now: Date()).outcome
    }

    /// Clear message for a key that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "MiniMax rejected this API key. Create a Token Plan key for the selected region and paste it here."
        case .rateLimited(let retryAfter?):
            "MiniMax is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "MiniMax is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label, region and API key, validated before the Account is created.
struct MiniMaxAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.minimax.displayName
    @State private var apiKey = ""
    @State private var region: MiniMaxRegion = .global
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            Picker("Region", selection: $region) {
                ForEach(MiniMaxRegion.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            SecureField("Token Plan API key", text: $apiKey)
            Text("Use the MiniMax Token Plan API key that belongs to the selected region. It is stored in your Keychain.")
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
                .disabled(checking || MiniMaxKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func add() async {
        let key = MiniMaxKeyCheck.normalized(apiKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .minimax, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await MiniMaxKeyCheck.check(key, region: region, account: account, store: store) {
        case .success(let reading):
            do {
                try MiniMaxProvider.credentialSource.save(
                    MiniMaxCredentials(apiKey: key, region: region), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = MiniMaxKeyCheck.message(for: failure)
        }
    }
}

/// MiniMax-specific Account settings: replace the key after it was revoked, and confirm the region.
struct MiniMaxAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var apiKey = ""
    @State private var region: MiniMaxRegion
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    init(store: AccountStore, account: Account) {
        self.store = store
        self.account = account
        let credentials = try? MiniMaxProvider.credentialSource.load(for: account).get()
        _region = State(initialValue: credentials?.region ?? .global)
    }

    var body: some View {
        Text("The Token Plan API key is tied to a MiniMax region. Replacing it needs a key for that region.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Picker("Region", selection: $region) {
            ForEach(MiniMaxRegion.allCases) { region in
                Text(region.displayName).tag(region)
            }
        }
        SecureField("New Token Plan API key", text: $apiKey)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Key") { Task { await replace() } }
                .disabled(checking || MiniMaxKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func replace() async {
        let key = MiniMaxKeyCheck.normalized(apiKey)
        checking = true
        message = nil
        defer { checking = false }
        switch await MiniMaxKeyCheck.check(key, region: region, account: account, store: store) {
        case .success(let reading):
            do {
                try MiniMaxProvider.credentialSource.save(
                    MiniMaxCredentials(apiKey: key, region: region), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Key saved.", false)
        case .failure(let failure):
            message = (MiniMaxKeyCheck.message(for: failure), true)
        }
    }
}
