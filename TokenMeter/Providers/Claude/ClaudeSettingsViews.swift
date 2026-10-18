import AppKit
import SwiftUI

/// Which Claude Code login a Claude Account reads.
enum ClaudeLogin: Equatable {
    case defaultLogin
    /// A `CLAUDE_CONFIG_DIR` directory (absolute path).
    case configDirectory(String)

    /// The value stored in `Account.claudeConfigDirectory`.
    var configDirectory: String? {
        switch self {
        case .defaultLogin: nil
        case .configDirectory(let path): path
        }
    }

    /// Directory as shown to the user, with the home directory abbreviated to `~`.
    var displayPath: String {
        (configDirectory ?? ClaudeCredentialSource.defaultConfigDirectory).abbreviatingWithTildeInPath
    }

    init(account: Account) {
        self = account.claudeConfigDirectory.map(ClaudeLogin.configDirectory) ?? .defaultLogin
    }

    /// The default directory picked explicitly means the default login.
    init(pickedDirectory url: URL) {
        let path = url.standardizedFileURL.path
        let defaultPath = URL(fileURLWithPath: ClaudeCredentialSource.defaultConfigDirectory).standardizedFileURL.path
        self = path == defaultPath ? .defaultLogin : .configDirectory(path)
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}

/// Explains the one-time macOS Keychain prompt before TokenMeter first reads Claude Code's item.
struct ClaudeKeychainNotice: View {
    var service: String

    var body: some View {
        Label {
            Text("macOS will ask once whether TokenMeter may use “\(service)”. Choose **Always Allow**; with “Allow” the prompt returns on every refresh. TokenMeter reads the token for each refresh and never stores, copies or refreshes it.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "key.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Offered in the Accounts tab while there is no Claude Account but Claude Code is logged in.
struct ClaudeDefaultLoginOffer: View {
    var store: AccountStore
    var onAdd: () -> Void
    @State private var available = false

    var body: some View {
        Group {
            if available && !store.accounts.contains(where: { $0.kind == .claude }) {
                VStack(spacing: 8) {
                    Label("Claude Code is logged in on this Mac", systemImage: ProviderKind.claude.symbolName)
                        .font(.headline)
                    Text("Add its login as a Claude Account to see your session and weekly Quotas.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Claude Account…", action: onAdd)
                }
                .padding()
            }
        }
        // Attribute-only lookup: no Keychain prompt.
        .task { available = ClaudeCredentialSource.hasLogin(configDirectory: nil) }
    }
}

/// Add-Account form: default Claude Code login or a `CLAUDE_CONFIG_DIR` directory, plus label.
struct ClaudeAddAccountForm: View {
    var store: AccountStore
    var onDone: (UUID?) -> Void
    @State private var login: ClaudeLogin
    @State private var label: String
    @State private var checking = false
    @State private var failure: ReadingFailure?

    init(store: AccountStore, onDone: @escaping (UUID?) -> Void) {
        self.store = store
        self.onDone = onDone
        let hasDefault = store.accounts.contains { $0.kind == .claude && $0.claudeConfigDirectory == nil }
        let login: ClaudeLogin = hasDefault ? .configDirectory("") : .defaultLogin
        _login = State(initialValue: login)
        _label = State(initialValue: Self.defaultLabel(for: login))
    }

    var body: some View {
        Form {
            Picker("Login", selection: loginChoice) {
                Text("Default Claude Code login (~/.claude)").tag(false)
                    .disabled(defaultAlreadyAdded)
                Text("Claude Code config directory…").tag(true)
            }
            .pickerStyle(.radioGroup)
            if case .configDirectory(let path) = login {
                HStack {
                    Text(path.isEmpty ? "No directory chosen" : path.abbreviatingWithTildeInPath)
                        .foregroundStyle(path.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseDirectory)
                }
                Text("The directory Claude Code uses as `CLAUDE_CONFIG_DIR` for that login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Label", text: $label)
            ClaudeKeychainNotice(service: ClaudeCredentialSource.keychainService(configDirectory: login.configDirectory))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
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
            if let failure {
                Button("Add Anyway") { add(account, failure: failure) }
                    .disabled(checking || duplicate)
            }
            Button(failure == nil ? "Add" : "Try Again") { Task { await check() } }
                .keyboardShortcut(.defaultAction)
                .disabled(checking || !isComplete || duplicate)
        }
    }

    private var defaultAlreadyAdded: Bool {
        store.accounts.contains { $0.kind == .claude && $0.claudeConfigDirectory == nil }
    }

    private var duplicate: Bool {
        store.accounts.contains { $0.kind == .claude && $0.claudeConfigDirectory == login.configDirectory }
    }

    private var isComplete: Bool { login.configDirectory?.isEmpty != true }

    private var usesDirectory: Bool {
        if case .configDirectory = login { true } else { false }
    }

    private var loginChoice: Binding<Bool> {
        Binding {
            usesDirectory
        } set: { wantsDirectory in
            guard wantsDirectory != usesDirectory else { return }
            select(wantsDirectory ? .configDirectory("") : .defaultLogin)
            if wantsDirectory { chooseDirectory() }
        }
    }

    private var problem: String? {
        if duplicate && isComplete { return "This Claude Code login is already an Account." }
        guard let failure else { return nil }
        let run = login.configDirectory.map { "CLAUDE_CONFIG_DIR=\($0.abbreviatingWithTildeInPath) claude" } ?? "claude"
        switch failure {
        case .loginExpired:
            return "No valid Claude Code login found (missing or expired). Run `\(run)` and log in, then try again."
        case .rateLimited:
            return "Claude is rate limiting requests. Add the Account now; it updates after the back-off."
        case .unavailable(let message):
            return "Could not read usage: \(message)"
        }
    }

    private var account: Account {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return Account(kind: .claude, label: trimmed.isEmpty ? Self.defaultLabel(for: login) : trimmed,
                       claudeConfigDirectory: login.configDirectory)
    }

    private static func defaultLabel(for login: ClaudeLogin) -> String {
        guard let path = login.configDirectory, !path.isEmpty else { return "Personal" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }

    private func select(_ newLogin: ClaudeLogin) {
        // Keep a label the user typed; replace the one we suggested.
        if label == Self.defaultLabel(for: login) { label = Self.defaultLabel(for: newLogin) }
        login = newLogin
        failure = nil
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Choose the Claude Code config directory (CLAUDE_CONFIG_DIR) of the login to add."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(ClaudeLogin(pickedDirectory: url))
    }

    /// Reads the login once (this is when macOS shows the Keychain prompt) and adds the Account on success.
    private func check() async {
        let account = account
        guard let reader = ProviderRegistry.reader(for: .claude) else { return }
        checking = true
        failure = nil
        defer { checking = false }
        switch await reader.read(account, session: store.session, now: Date()) {
        case .success(let reading):
            store.add(account, firstReading: reading)
            onDone(account.id)
        case .failure(let failure):
            self.failure = failure
        }
    }

    private func add(_ account: Account, failure: ReadingFailure) {
        store.add(account)
        store.record(.failure(failure), for: account.id)
        onDone(account.id)
    }
}

/// Claude-specific Account settings: which Claude Code login is read, and from where.
struct ClaudeAccountSettings: View {
    var account: Account

    var body: some View {
        let login = ClaudeLogin(account: account)
        let service = ClaudeCredentialSource.keychainService(configDirectory: login.configDirectory)
        LabeledContent("Claude Code login", value: login == .defaultLogin ? "Default (\(login.displayPath))"
                                                                          : login.displayPath)
        LabeledContent("Keychain item", value: service)
        ClaudeKeychainNotice(service: service)
        Text(verbatim: "If the login has expired, run `\(runCommand(login))` to log in again; TokenMeter picks up the new token on the next refresh.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func runCommand(_ login: ClaudeLogin) -> String {
        login.configDirectory.map { "CLAUDE_CONFIG_DIR=\($0.abbreviatingWithTildeInPath) claude" } ?? "claude"
    }
}
