import SwiftUI

/// Checks Cursor's borrowed local login by taking a Reading with it.
enum CursorKeyCheck {
    @MainActor
    static func check(account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        let credentials: CursorCredentials
        switch CursorProvider.credentialSource.load(for: account) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let loaded):
            credentials = loaded
        }
        return await CursorProvider.live.read(account: account, credentials: credentials,
                                               session: store.session, now: Date()).outcome
    }

    /// Clear message for a login that could not be read.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "No valid Cursor login found. Open Cursor or run `cursor agent login`, then try again."
        case .rateLimited(let retryAfter?):
            "Cursor is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Cursor is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not read Cursor usage: \(message)"
        }
    }
}

/// Add-Account form for Cursor: no secret field — TokenMeter borrows the login Cursor stores.
struct CursorAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.cursor.displayName
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            Text("TokenMeter reads the login Cursor keeps on this Mac. It never stores, copies or refreshes your Cursor token.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("Reading usage…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Add") { Task { await add() } }
                .keyboardShortcut(.defaultAction)
                .disabled(checking)
        }
    }

    private func add() async {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .cursor, label: trimmed.isEmpty ? nil : trimmed)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await CursorKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = CursorKeyCheck.message(for: failure)
        }
    }
}

/// Cursor-specific Account settings: where the borrowed login comes from and a manual check.
struct CursorAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        LabeledContent("Login", value: "Cursor app / `cursor agent`")
        Text("Read from Cursor's local storage or the `cursor-access-token` Keychain item on every refresh. If it has expired, open Cursor or run `cursor agent login`.")
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
            Button("Check Now") { Task { await check() } }
                .disabled(checking)
        }
    }

    private func check() async {
        checking = true
        message = nil
        defer { checking = false }
        switch await CursorKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.record(.success(reading), for: account.id)
            message = ("Login is valid.", false)
        case .failure(let failure):
            message = (CursorKeyCheck.message(for: failure), true)
        }
    }
}
