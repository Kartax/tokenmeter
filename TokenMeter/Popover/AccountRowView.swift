import SwiftUI

/// One Account in the popover: header plus the content for its display state.
struct AccountRowView: View {
    var account: Account
    var state: AccountDisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            case .ok(let reading):
                ReadingView(reading: reading, showAll: account.showAllWindows)
            case .stale(let reading, let note):
                if let reading {
                    ReadingView(reading: reading, showAll: account.showAllWindows)
                        .opacity(0.45)
                }
                StaleLine(takenAt: reading?.takenAt, note: note)
            case .loginExpired(let hint):
                LoginExpiredLine(account: account, hint: hint)
            case .error(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Personal"
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: account.kind.symbolName)
                .foregroundStyle(.secondary)
            Text(title).font(.headline).lineLimit(1)
        }
    }

    private var title: String {
        account.label
    }
}

/// "Login expired — <hint>"; the hint links to the Account in Settings when that's where the
/// login is fixed (e.g. Codex "Sign in again", Ollama and Venice "Check API key").
private struct LoginExpiredLine: View {
    var account: Account
    var hint: String
    @Environment(SettingsRouter.self) private var router: SettingsRouter?

    var body: some View {
        if account.kind.recoversInSettings, let router {
            HStack(spacing: 4) {
                Label("Login expired —", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(hint) { router.showAccount(account.id) }
                    .buttonStyle(.link)
                    .help("Open this Account in Settings")
            }
            .font(.caption)
        } else {
            Label("Login expired — \(hint)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct StaleLine: View {
    var takenAt: Date?
    var note: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Label(text(now: context.date), systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func text(now: Date) -> String {
        guard let takenAt else { return "Stale · \(note)" }
        return "Stale · \(note) · taken \(DisplayFormat().age(of: takenAt, now: now))"
    }
}

/// Quotas as bars with percent used and reset time; Credit balances with an allowance get a bar
/// from their remaining amount, others stay one line. Only main entries unless the Account shows
/// all Windows.
struct ReadingView: View {
    var reading: Reading
    var showAll: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(quotas.enumerated()), id: \.offset) { _, quota in
                    QuotaView(quota: quota, now: context.date)
                }
                ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                    CreditView(credit: credit, now: context.date)
                }
            }
        }
    }

    private var quotas: [Quota] { reading.quotas.filter { showAll || $0.window.isMain } }
    private var credits: [CreditBalance] { reading.credits.filter { showAll || $0.isMain } }
}

private struct QuotaView: View {
    var quota: Quota
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(quota.window.title).font(.caption)
                Spacer()
                detail.font(.caption).foregroundStyle(.secondary)
            }
            UsageBar(fraction: quota.percentUsed / 100, color: quota.level.color)
        }
    }

    /// "42% used · resets in 2 h 14 m"; over the limit: "100% · limit reached · resets …".
    private var detail: Text {
        var text = quota.limitReached
            ? Text("100% · ") + Text("limit reached").foregroundColor(.red)
            : Text("\(Int(quota.percentUsed.rounded()))% used")
        if let resetsAt = quota.window.resetsAt {
            text = text + Text(" · resets \(DisplayFormat().resetTime(resetsAt, now: now))")
        }
        return text
    }
}

/// A Credit balance: title and, when the Provider reports an allowance, percent used with a bar,
/// followed by the remaining amount.
private struct CreditView: View {
    var credit: CreditBalance
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(credit.title).font(.caption)
                Spacer()
                if let percentUsed = credit.percentUsed {
                    Text("\(Int(percentUsed.rounded()))% used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let percentUsed = credit.percentUsed {
                UsageBar(fraction: percentUsed / 100,
                         color: UsageLevel(percentUsed: percentUsed).color)
            }
            Text(DisplayFormat().creditLine(credit, now: now)).font(.callout)
        }
    }
}

/// Horizontal bar filled to `fraction` in the usage level's colour.
private struct UsageBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

private extension UsageLevel {
    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}
