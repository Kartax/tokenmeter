import SwiftUI

/// Accounts tab: the Account list with add/remove, and the selected Account's details.
struct AccountsSettingsView: View {
    var store: AccountStore
    @State private var selection: UUID?
    @State private var adding: ProviderKind?
    @Environment(SettingsRouter.self) private var router

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        AccountListRow(account: account, state: store.displayState(of: account))
                            .tag(account.id)
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                }
                .overlay {
                    if store.accounts.isEmpty {
                        Text("No Accounts yet").foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Menu {
                        ForEach(ProviderRegistry.addable) { kind in
                            Button(kind.displayName) { adding = kind }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add Account")
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 180)
            Divider()
            if let account = store.accounts.first(where: { $0.id == selection }) {
                AccountDetailView(store: store, account: account) { selection = nil }
                    .id(account.id)
            } else {
                VStack {
                    Text(store.accounts.isEmpty ? "Add an Account with +" : "Select an Account")
                        .foregroundStyle(.secondary)
                    ClaudeDefaultLoginOffer(store: store) { adding = .claude }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $adding) { kind in
            AddAccountSheet(kind: kind, store: store) { added in
                adding = nil
                if let added { selection = added }
            }
        }
        .onChange(of: router.accountToSelect, initial: true) { _, requested in
            guard let requested else { return }
            selection = requested
            router.accountToSelect = nil
        }
    }
}

extension ProviderKind: Identifiable {
    var id: Self { self }
}

private struct AccountListRow: View {
    var account: Account
    var state: AccountDisplayState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: account.kind.symbolName)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.label).lineLimit(1)
                Text(account.kind.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(state.indicatorColor)
                .frame(width: 7, height: 7)
                .help(state.statusText(now: .now))
        }
    }
}

/// The "Add Account" sheet; each Provider supplies its own form.
private struct AddAccountSheet: View {
    var kind: ProviderKind
    var store: AccountStore
    /// Called with the new Account's id, or nil when cancelled.
    var onDone: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add \(kind.displayName) Account", systemImage: kind.symbolName)
                .font(.headline)
            switch kind {
            case .ollama:
                OllamaAddAccountForm(store: store, onDone: onDone)
            case .claude:
                ClaudeAddAccountForm(store: store, onDone: onDone)
            case .codex:
                CodexAddAccountForm(store: store, onDone: onDone)
            case .nous:
                Text("\(kind.displayName) is not supported yet.")
                Button("Close") { onDone(nil) }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Settings for one Account: label, Plan, identity, state, Provider-specific settings, removal.
private struct AccountDetailView: View {
    var store: AccountStore
    var account: Account
    var onRemoved: () -> Void
    @State private var label: String
    @State private var confirmRemove = false

    init(store: AccountStore, account: Account, onRemoved: @escaping () -> Void) {
        self.store = store
        self.account = account
        self.onRemoved = onRemoved
        _label = State(initialValue: account.label)
    }

    var body: some View {
        Form {
            LabeledContent("Provider") {
                Label(account.kind.displayName, systemImage: account.kind.symbolName)
            }
            TextField("Label", text: $label)
                .onChange(of: label) { _, new in
                    let trimmed = new.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { store.rename(account.id, to: trimmed) }
                }
            LabeledContent("Plan", value: reading?.plan ?? "—")
            LabeledContent("Signed in as", value: reading?.identity ?? "—")
            LabeledContent("Status") {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(store.displayState(of: account).statusText(now: context.date))
                        .foregroundStyle(store.displayState(of: account).indicatorColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            Toggle(isOn: Binding(get: { account.showAllWindows },
                                 set: { store.setShowAllWindows($0, for: account.id) })) {
                Text("Show all Windows")
                Text("Also show model-scoped Windows and extra Credit balances in the popover.")
            }
            switch account.kind {
            case .ollama:
                OllamaAccountSettings(store: store, account: account)
            case .claude:
                ClaudeAccountSettings(account: account)
            case .codex:
                CodexAccountSettings(store: store, account: account)
            case .nous:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Remove Account…", role: .destructive) { confirmRemove = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove “\(account.label)”?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                store.remove(account.id)
                onRemoved()
            }
        } message: {
            Text("Secrets TokenMeter stored for this Account are deleted from the Keychain.")
        }
    }

    private var reading: Reading? { store.readings[account.id] }
}

extension AccountDisplayState {
    /// One short line for Settings.
    func statusText(now: Date) -> String {
        let format = DisplayFormat()
        switch self {
        case .loading: return "Loading…"
        case .ok(let reading): return "OK · updated \(format.age(of: reading.takenAt, now: now))"
        case .stale(let reading?, let note): return "Stale · \(note) · taken \(format.age(of: reading.takenAt, now: now))"
        case .stale(nil, let note): return "Stale · \(note)"
        case .loginExpired(let hint): return "Login expired — \(hint)"
        case .error(let message): return message
        }
    }

    var indicatorColor: Color {
        switch self {
        case .loading: .secondary
        case .ok: .green
        case .stale: .yellow
        case .loginExpired: .orange
        case .error: .red
        }
    }
}
