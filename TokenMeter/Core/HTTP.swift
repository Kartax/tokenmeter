import Foundation
import OSLog

/// Logger for Core and Providers. Never interpolate secrets; default interpolation privacy is private.
let coreLog = Logger(subsystem: "org.kartax.TokenMeter", category: "core")

/// Small helpers shared by Provider implementations.
enum HTTP {
    /// Performs the request; transport errors become `.unavailable`.
    static func send(_ request: URLRequest, session: URLSession) async -> Result<(Data, HTTPURLResponse), ReadingFailure> {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.unavailable("No HTTP response")) }
            return .success((data, http))
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
    }

    /// Seconds to wait from a `Retry-After` header (delta-seconds or HTTP-date).
    static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// One short line for an unexpected status, e.g. "Server returned 500".
    static func statusMessage(_ status: Int) -> String {
        "Server returned \(status)"
    }

    /// Parses ISO 8601 timestamps with or without fractional seconds.
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
