import SwiftUI

/// Saves approved GitHub credentials and takes the first Reading with them.
enum CopilotSignIn {
    static let title = "Sign in with GitHub"

    /// Saves `credentials` to the Account's Keychain item (before any use), then reads the Account
    /// with them. Throws when the Keychain refuses.
    @MainActor
    static func store(_ credentials: CopilotCredentials, for account: Account, session: URLSession) async throws
        -> Result<Reading, ReadingFailure> {
        try CopilotProvider.credentialSource.save(credentials, for: account)
        let reader = CredentialedReader(provider: CopilotProvider.live, source: CopilotProvider.credentialSource)
        return await reader.read(account, session: session, now: Date())
    }

    static func isSignedIn(_ account: Account) -> Bool {
        if case .success = CopilotProvider.credentialSource.load(for: account) { true } else { false }
    }
}

/// Add-Account form: a label, then "Sign in with GitHub". The Account is added once signed in.
struct CopilotAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.copilot.displayName
    @State private var signingIn = false
    @State private var message: String?
    /// Fixed for the whole form so the Keychain item and the Account share one id.
    @State private var accountID = UUID()

    var body: some View {
        if signingIn {
            DeviceCodeSignInView(title: CopilotSignIn.title, flow: CopilotDeviceCodeFlow(), session: store.session,
                                 complete: complete, onFinish: { failure in
                signingIn = false
                message = failure
            })
        } else {
            Form {
                TextField("Label", text: $label)
                Text("TokenMeter signs in through GitHub's Copilot device flow and keeps the token in your Keychain. It never reads your editor's login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(CopilotSignIn.title) {
                    message = nil
                    signingIn = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var account: Account {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return Account(id: accountID, kind: .copilot, label: trimmed.isEmpty ? nil : trimmed)
    }

    private func complete(_ credentials: CopilotCredentials) async -> String? {
        let account = account
        do {
            let outcome = try await CopilotSignIn.store(credentials, for: account, session: store.session)
            store.add(account, firstReading: try? outcome.get())
            if case .failure = outcome { store.record(outcome, for: account.id) }
            onDone(account.id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Copilot-specific Account settings: sign in (again) or sign out without removing the Account.
struct CopilotAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var signedIn = false
    @State private var signingIn = false
    @State private var message: String?

    var body: some View {
        LabeledContent("GitHub", value: signInState)
        HStack {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if signedIn {
                Button("Sign Out") { signOut() }
                    .disabled(store.refreshing.contains(account.id))
            }
            Button(signedIn ? "Sign In Again…" : "\(CopilotSignIn.title)…") {
                message = nil
                signingIn = true
            }
        }
        .onAppear { signedIn = CopilotSignIn.isSignedIn(account) }
        .onChange(of: store.failures[account.id]) { signedIn = CopilotSignIn.isSignedIn(account) }
        .sheet(isPresented: $signingIn) {
            DeviceCodeSignInView(title: CopilotSignIn.title, flow: CopilotDeviceCodeFlow(), session: store.session,
                                 complete: complete, onFinish: { failure in
                signingIn = false
                message = failure
            })
            .padding(20)
            .frame(width: 420)
        }
    }

    private var signInState: String {
        guard signedIn else { return "Signed out" }
        if case .loginExpired = store.displayState(of: account) { return "Sign-in expired" }
        return "Signed in"
    }

    private func complete(_ credentials: CopilotCredentials) async -> String? {
        do {
            store.record(try await CopilotSignIn.store(credentials, for: account, session: store.session), for: account.id)
            signedIn = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func signOut() {
        do {
            try store.signOut(account.id, hint: CopilotProvider.loginHint)
            signedIn = false
            message = "Signed out. The token was deleted from the Keychain."
        } catch {
            message = error.localizedDescription
        }
    }
}
