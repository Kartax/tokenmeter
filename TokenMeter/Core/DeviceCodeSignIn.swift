import Foundation

// Device-code sign-in (ADR 0003): Codex and Nous Portal Accounts sign in through TokenMeter's own
// OAuth device-code flow. Each Provider implements `DeviceCodeFlow`; `DeviceCodeSignInView`
// (Settings) drives any flow: shows the user code, opens the browser, waits, and can be cancelled.

/// The one-time code the user enters on the Provider's verification page.
struct DeviceCode: Equatable, Sendable {
    var userCode: String
    /// Page the browser opens (with the code prefilled when the Provider supports it).
    var verificationURL: URL
    /// After this moment the code can no longer be approved.
    var expiresAt: Date
}

/// A started sign-in: what the user sees plus the flow-specific state needed to poll.
struct DeviceCodeChallenge<Pending: Sendable>: Sendable {
    var code: DeviceCode
    var pending: Pending
}

/// Why a device-code sign-in ended without credentials.
enum DeviceCodeFailure: Error, Equatable, Sendable {
    /// The user cancelled.
    case cancelled
    /// The code expired before it was approved.
    case expired
    /// The server refused; carries the server's message (or "Server returned 4xx").
    case refused(String)
    /// The server could not be reached or answered with something unexpected.
    case unavailable(String)

    /// One short line for the sign-in sheet and Account settings.
    var message: String {
        switch self {
        case .cancelled: "Sign-in cancelled."
        case .expired: "The code expired before it was approved. Sign in again to get a new code."
        case .refused(let message): message
        case .unavailable(let message): "Could not sign in: \(message)"
        }
    }
}

/// Time source for polling loops, injectable so tests don't wait.
struct PollClock: Sendable {
    var now: @Sendable () -> Date
    /// Suspends for the given number of seconds; throws `CancellationError` when cancelled.
    var sleep: @Sendable (TimeInterval) async throws -> Void

    static let live = PollClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}

/// A Provider's device-code sign-in. `requestCode` asks for a user code; `awaitApproval` polls
/// until the user approved it in the browser and returns the Provider's credentials.
///
/// `awaitApproval` must return `.expired` once `clock.now()` passes `code.expiresAt`, and
/// `.cancelled` when its task is cancelled (`clock.sleep` throws). Polling cadence and the
/// server's pending/slow-down signals are flow-specific (Codex: 403/404 = pending; RFC 8628 flows
/// such as Nous: `authorization_pending`, `slow_down`, `expires_in`).
protocol DeviceCodeFlow: Sendable {
    associatedtype Pending: Sendable
    associatedtype Credentials: Sendable

    func requestCode(session: URLSession, now: Date) async
        -> Result<DeviceCodeChallenge<Pending>, DeviceCodeFailure>
    func awaitApproval(_ challenge: DeviceCodeChallenge<Pending>, session: URLSession, clock: PollClock) async
        -> Result<Credentials, DeviceCodeFailure>
}
