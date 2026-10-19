import SwiftUI

/// Checks the borrowed Kimi Code login by taking a Reading with it.
enum KimiKeyCheck {
    @MainActor
    static func check(account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        switch KimiProvider.credentialSource.load(for: account) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let credentials):
            return await KimiProvider.live.read(account: account, credentials: credentials,
                                                session: store.session, now: Date()).outcome
        }
    }

    /// Clear message for a login that could not be read.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "No valid Kimi Code login found. Run `kimi login` and try again."
        case .rateLimited(let retryAfter?):
            "Kimi is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Kimi is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not read Kimi usage: \(message)"
        }
    }
}

/// Add-Account form: label only. The login itself is borrowed from Kimi Code.
struct KimiAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.kimi.displayName
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            Text("Kimi Code login: \(loginPath). Run `kimi login` first; TokenMeter only reads this file and never changes it.")
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

    private var loginPath: String {
        (KimiCredentialSource.defaultFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    private func add() async {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .kimi, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await KimiKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = KimiKeyCheck.message(for: failure)
        }
    }
}

/// Kimi-specific Account settings: where the borrowed login lives, and a re-check.
struct KimiAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        LabeledContent("Login",
                       value: (KimiCredentialSource.defaultFileURL.path as NSString).abbreviatingWithTildeInPath)
        Text("TokenMeter borrows this Kimi Code login on every refresh and never modifies it. If it has expired, run `kimi login` again.")
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
            Button("Check Login") { Task { await check() } }
                .disabled(checking)
        }
    }

    private func check() async {
        checking = true
        message = nil
        defer { checking = false }
        switch await KimiKeyCheck.check(account: account, store: store) {
        case .success(let reading):
            store.record(.success(reading), for: account.id)
            message = ("Login is valid.", false)
        case .failure(let failure):
            message = (KimiKeyCheck.message(for: failure), true)
        }
    }
}
