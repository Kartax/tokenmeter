import Foundation

/// Text for reset/renewal times and Credit balances (English only, 24-hour clock).
struct DisplayFormat {
    var timeZone: TimeZone = .current

    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Relative within 24 h ("in 2 h 14 m"), weekday and time within a week ("Mon 09:00"),
    /// otherwise day and month ("3 Nov").
    func resetTime(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        if interval < 86400 {
            let minutes = max(1, Int(interval / 60))
            let (h, m) = (minutes / 60, minutes % 60)
            if h == 0 { return "in \(m) m" }
            return m == 0 ? "in \(h) h" : "in \(h) h \(m) m"
        }
        return string(date, format: interval < 7 * 86400 ? "EEE HH:mm" : "d MMM")
    }

    /// "$41.20 of $60 left, renews 3 Nov"; parts are omitted when unknown.
    func creditLine(_ balance: CreditBalance, now: Date) -> String {
        var line = money(balance.remaining, currency: balance.currency)
        if let allowance = balance.allowance {
            line += " of \(money(allowance, currency: balance.currency))"
        }
        line += " left"
        if let renewsAt = balance.renewsAt {
            line += ", renews \(resetTime(renewsAt, now: now))"
        }
        return line
    }

    /// Whole amounts without decimals ("$60"), others with two ("$41.20").
    func money(_ amount: Decimal, currency: String) -> String {
        let isWhole = amount == amount.rounded(scale: 0)
        return amount.formatted(.currency(code: currency)
            .precision(.fractionLength(isWhole ? 0 : 2))
            .locale(Locale(identifier: "en_US")))
    }

    /// Age of a Reading ("just now", "5 min ago", "at 09:14", "on 3 Nov") for "Updated …"/"taken …".
    func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) min ago"
        case ..<(24 * 60): return "at " + string(date, format: "HH:mm")
        default: return "on " + string(date, format: "d MMM")
        }
    }

    private func string(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Self.locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// Colour level of a Quota bar.
enum UsageLevel: Equatable {
    case normal, warning, critical
}

extension Quota {
    /// Warning from 75% used, critical from 90% and whenever the limit is reached.
    var level: UsageLevel {
        if limitReached || percentUsed >= 90 { return .critical }
        return percentUsed >= 75 ? .warning : .normal
    }
}

private extension Decimal {
    func rounded(scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
