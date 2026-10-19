import SwiftUI

/// Checks Xiaomi MiMo browser cookies by taking a Reading with them.
enum XiaomiKeyCheck {
    @MainActor
    static func check(_ cookie: String, account: Account, store: AccountStore) async -> Result<Reading, ReadingFailure> {
        await XiaomiProvider.live.read(account: account,
                                       credentials: XiaomiCredentials(cookie: cookie),
                                       session: store.session, now: Date()).outcome
    }

    /// Clear message for cookies that failed the check.
    static func message(for failure: ReadingFailure) -> String {
        switch failure {
        case .loginExpired:
            "The MiMo console login is missing or expired. Copy the Cookie header from a signed-in platform.xiaomimimo.com request; it must contain api-platform_serviceToken and userId."
        case .rateLimited(let retryAfter?):
            "Xiaomi MiMo is rate limiting requests. Try again in \(Int(retryAfter.rounded(.up))) s."
        case .rateLimited(nil):
            "Xiaomi MiMo is rate limiting requests. Try again in a minute."
        case .unavailable(let message):
            "Could not check the cookies: \(message)"
        }
    }

    static func normalized(_ cookie: String) -> String {
        XiaomiProvider.normalizedCookie(cookie)
    }
}

/// Add-Account form: label plus the console Cookie header, validated before the Account is created.
struct XiaomiAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.xiaomi.displayName
    @State private var cookie = ""
    @State private var checking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Label", text: $label)
            SecureField("Cookie header", text: $cookie)
            Text("The MiMo console has no API-key usage endpoint, so TokenMeter uses the same browser session as the console. Sign in at [platform.xiaomimimo.com](https://platform.xiaomimimo.com), open the developer tools on any `/api/v1` request and paste its **Cookie** request header. It must contain `api-platform_serviceToken` and `userId`. It is stored in your Keychain.")
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
                Text("Checking cookies…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Add") { Task { await add() } }
                .keyboardShortcut(.defaultAction)
                .disabled(checking || XiaomiKeyCheck.normalized(cookie).isEmpty)
        }
    }

    private func add() async {
        let value = XiaomiKeyCheck.normalized(cookie)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let account = Account(kind: .xiaomi, label: trimmedLabel.isEmpty ? nil : trimmedLabel)
        checking = true
        errorMessage = nil
        defer { checking = false }
        switch await XiaomiKeyCheck.check(value, account: account, store: store) {
        case .success(let reading):
            do {
                try XiaomiProvider.credentialSource.save(XiaomiCredentials(cookie: value), for: account)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            errorMessage = XiaomiKeyCheck.message(for: failure)
        }
    }
}

/// Xiaomi MiMo-specific Account settings: replace the cookies after the console session expires.
struct XiaomiAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var cookie = ""
    @State private var checking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Text("The MiMo console session expires periodically. Paste a fresh **Cookie** header from platform.xiaomimimo.com; it must contain `api-platform_serviceToken` and `userId`.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SecureField("New cookie header", text: $cookie)
        HStack {
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            Button("Replace Cookies") { Task { await replace() } }
                .disabled(checking || XiaomiKeyCheck.normalized(cookie).isEmpty)
        }
    }

    private func replace() async {
        let value = XiaomiKeyCheck.normalized(cookie)
        checking = true
        message = nil
        defer { checking = false }
        switch await XiaomiKeyCheck.check(value, account: account, store: store) {
        case .success(let reading):
            do {
                try XiaomiProvider.credentialSource.save(XiaomiCredentials(cookie: value), for: account)
            } catch {
                message = (error.localizedDescription, true)
                return
            }
            store.record(.success(reading), for: account.id)
            cookie = ""
            message = ("Cookies saved.", false)
        case .failure(let failure):
            message = (XiaomiKeyCheck.message(for: failure), true)
        }
    }
}
