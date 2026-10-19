import SwiftUI

/// Checks an xAI Management API key and team ID by taking a Reading with them.
enum XaiKeyCheck {
    @MainActor
    static func check(_ key: String, teamID: String, account: Account, store: AccountStore) async
        -> Result<Reading, ReadingFailure> {
        await XaiProvider.live.read(
            account: account,
            credentials: XaiCredentials(apiKey: key, teamID: teamID),
            session: store.session, now: Date()).outcome
    }

    /// Clear message for credentials that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "xAI needs a **Management** API key; inference API keys are rejected. Create one in the xAI Console under Settings › Management Keys and paste it here."
        case .rateLimited(let retryAfter?):
            "xAI is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "xAI is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            message == XaiProvider.teamNotFoundMessage
                ? "Check the team ID: \(message)."
                : "Could not check the billing balance: \(message)"
        }
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidTeamID(_ value: String) -> Bool {
        XaiProvider.isValidTeamID(normalized(value))
    }
}

private let xaiManagementKeyNote = """
    xAI requires a Management API key and the team ID to read billing. Inference API keys are rejected by the Management API. Create a Management key in the xAI Console under Settings › Management Keys; the team ID is shown in the console URL and team settings.
    """

/// Add-Account form: Management API key plus team ID, validated before the Account is created.
struct XaiAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.xai.displayName
    @State private var apiKey = ""
    @State private var teamID = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("Management API key", text: $apiKey)
            TextField("Team ID", text: $teamID)
            Text(xaiManagementKeyNote)
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
                Text("Checking credentials…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Add") { Task { await add() } }
                .keyboardShortcut(.defaultAction)
                .disabled(checking || !isComplete)
        }
    }

    private var isComplete: Bool {
        !XaiKeyCheck.normalized(apiKey).isEmpty && XaiKeyCheck.isValidTeamID(teamID)
    }

    private func add() async {
        let key = XaiKeyCheck.normalized(apiKey)
        let team = XaiKeyCheck.normalized(teamID)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .xai, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await XaiKeyCheck.check(key, teamID: team, account: account, store: store) {
        case .success(let reading):
            do {
                try XaiProvider.credentialSource.save(XaiCredentials(apiKey: key, teamID: team), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = XaiKeyCheck.message(for: failure)
        }
    }
}

/// xAI-specific Account settings: replace the Management API key and team ID.
struct XaiAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var apiKey = ""
    @State private var teamID = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("Replacing these needs another **Management** API key; inference API keys are rejected.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SecureField("New Management API key", text: $apiKey)
        TextField("Team ID", text: $teamID)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Credentials") { Task { await replace() } }
                .disabled(checking || apiKey.isEmpty || !XaiKeyCheck.isValidTeamID(teamID))
        }
    }

    private func replace() async {
        let key = XaiKeyCheck.normalized(apiKey)
        let team = XaiKeyCheck.normalized(teamID)
        checking = true
        message = nil
        defer { checking = false }
        switch await XaiKeyCheck.check(key, teamID: team, account: account, store: store) {
        case .success(let reading):
            do {
                try XaiProvider.credentialSource.save(XaiCredentials(apiKey: key, teamID: team), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            apiKey = ""
            message = ("Credentials saved.", false)
        case .failure(let failure):
            message = (XaiKeyCheck.message(for: failure), true)
        }
    }
}
