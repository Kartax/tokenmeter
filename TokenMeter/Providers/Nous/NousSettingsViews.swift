import SwiftUI

/// Saves approved Nous credentials and takes the first Reading with them.
enum NousSignIn {
    static let title = "Sign in with Nous Portal"

    /// Saves `credentials` to the Account's Keychain item (before any use), then reads the Account
    /// with them. Throws when the Keychain refuses.
    @MainActor
    static func store(_ credentials: NousCredentials, for account: Account, session: URLSession) async throws
        -> Result<Reading, ReadingFailure> {
        try NousProvider.credentialSource.save(credentials, for: account)
        let reader = CredentialedReader(provider: NousProvider.live, source: NousProvider.credentialSource)
        return await reader.read(account, session: session, now: Date())
    }

    static func isSignedIn(_ account: Account) -> Bool {
        if case .success = NousProvider.credentialSource.load(for: account) { true } else { false }
    }
}

/// Add-Account form: a label, then "Sign in with Nous Portal". The Account is added once signed in.
struct NousAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var label = ProviderKind.nous.displayName
    @State private var signingIn = false
    @State private var message: String?
    /// Fixed for the whole form so the Keychain item and the Account share one id.
    @State private var accountID = UUID()

    var body: some View {
        if signingIn {
            DeviceCodeSignInView(title: NousSignIn.title, flow: NousDeviceCodeFlow(), session: store.session,
                                 complete: complete, onFinish: { failure in
                signingIn = false
                message = failure
            })
            .padding(20)
            .frame(width: 420)
        } else {
            Form {
                TextField("Label", text: $label)
                Text("TokenMeter signs in with its own Nous Portal login (device code) and keeps the tokens in your Keychain. No Hermes Agent installation is needed.")
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
                Button(NousSignIn.title) {
                    message = nil
                    signingIn = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var account: Account {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return Account(id: accountID, kind: .nous, label: trimmed.isEmpty ? nil : trimmed)
    }

    private func complete(_ credentials: NousCredentials) async -> String? {
        let account = account
        do {
            let outcome = try await NousSignIn.store(credentials, for: account, session: store.session)
            store.add(account, firstReading: try? outcome.get())
            if case .failure = outcome { store.record(outcome, for: account.id) }
            onDone(account.id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Nous-specific Account settings: sign in (again) or sign out without removing the Account.
struct NousAccountSettings: View {
    var store: AccountStore
    var account: Account
    @State private var signedIn = false
    @State private var signingIn = false
    @State private var message: String?

    var body: some View {
        LabeledContent("Nous Portal", value: signInState)
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
            Button(signedIn ? "Sign In Again…" : "\(NousSignIn.title)…") {
                message = nil
                signingIn = true
            }
        }
        .onAppear { signedIn = NousSignIn.isSignedIn(account) }
        .onChange(of: store.failures[account.id]) { signedIn = NousSignIn.isSignedIn(account) }
        .sheet(isPresented: $signingIn) {
            DeviceCodeSignInView(title: NousSignIn.title, flow: NousDeviceCodeFlow(), session: store.session,
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

    private func complete(_ credentials: NousCredentials) async -> String? {
        do {
            store.record(try await NousSignIn.store(credentials, for: account, session: store.session), for: account.id)
            signedIn = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func signOut() {
        do {
            try store.signOut(account.id, hint: NousProvider.loginHint)
            signedIn = false
            message = "Signed out. Tokens were deleted from the Keychain."
        } catch {
            message = error.localizedDescription
        }
    }
}