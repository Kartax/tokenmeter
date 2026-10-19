import SwiftUI

/// Checks a Coding Plan API key by taking a Reading with it.
enum AlibabaKeyCheck {
    @MainActor
    static func check(_ key: String, region: AlibabaRegion, account: Account, store: AccountStore) async
        -> Result<Reading, ReadingFailure> {
        await AlibabaProvider.live.read(account: account,
                                        credentials: AlibabaCredentials(apiKey: key, region: region),
                                        session: store.session, now: Date()).outcome
    }

    /// Clear message for a key or region that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "Alibaba Cloud needs a Coding Plan API key (sk-sp-...) for the selected region. Create one in the Model Studio or Bailian console and paste it here."
        case .rateLimited(let retryAfter?):
            "Alibaba Cloud is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Alibaba Cloud is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the key: \(message)"
        }
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Add-Account form: label, region and Coding Plan API key, validated before the Account is created.
struct AlibabaAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.alibaba.displayName
    @State private var region: AlibabaRegion = .intl
    @State private var apiKey = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            Picker("Region", selection: $region) {
                ForEach(AlibabaRegion.allCases, id: \.self) { region in
                    Text(region.displayName).tag(region)
                }
            }
            SecureField("Coding Plan API key", text: $apiKey)
            Text("Use a **Coding Plan** API key (`sk-sp-...`) from the Alibaba Cloud Model Studio or Bailian console. It is stored in your Keychain.")
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
                .disabled(checking || AlibabaKeyCheck.normalized(apiKey).isEmpty)
        }
    }

    private func add() async {
        let key = AlibabaKeyCheck.normalized(apiKey)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .alibaba, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        let credentials = AlibabaCredentials(apiKey: key, region: region)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await AlibabaKeyCheck.check(key, region: region, account: account, store: store) {
        case .success(let reading):
            do {
                try AlibabaProvider.credentialSource.save(credentials, for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = AlibabaKeyCheck.message(for: failure)
        }
    }
}

/// Alibaba Cloud Account settings: change the region, replace the key, or both.
struct AlibabaAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var region: AlibabaRegion = .intl
    @State private var apiKey = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Picker("Region", selection: $region) {
            ForEach(AlibabaRegion.allCases, id: \.self) { region in
                Text(region.displayName).tag(region)
            }
        }
        SecureField("New Coding Plan API key", text: $apiKey)
        Text("Leave the key empty to keep the saved one. Changing the region re-checks the saved key against that console.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Save") { Task { await save() } }
                .disabled(checking)
        }
        .onAppear {
            if let saved = try? AlibabaProvider.credentialSource.load(for: account).get() {
                region = saved.region
            }
        }
    }

    private func save() async {
        guard let saved = try? AlibabaProvider.credentialSource.load(for: account).get() else {
            message = ("No saved key for this Account. Remove and add it again.", true)
            return
        }
        let enteredKey = AlibabaKeyCheck.normalized(apiKey)
        let credentials = AlibabaCredentials(apiKey: enteredKey.isEmpty ? saved.apiKey : enteredKey, region: region)
        checking = true
        message = nil
        defer { checking = false }
        switch await AlibabaKeyCheck.check(credentials.apiKey, region: credentials.region,
                                          account: account, store: store) {
        case .success(let reading):
            do {
                try AlibabaProvider.credentialSource.save(credentials, for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Settings saved.", false)
        case .failure(let failure):
            message = (AlibabaKeyCheck.message(for: failure), true)
        }
    }
}
