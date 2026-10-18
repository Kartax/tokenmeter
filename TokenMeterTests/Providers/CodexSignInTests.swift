import XCTest
@testable import TokenMeter

/// A `PollClock` whose sleeps return immediately and advance `now`; can simulate cancellation.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recorded: [TimeInterval] = []
    /// The sleep with this (1-based) number throws `CancellationError`, as if the task was cancelled.
    var cancelAtSleep: Int?

    init(now: Date) { current = now }

    var sleeps: [TimeInterval] { lock.withLock { recorded } }

    var clock: PollClock {
        PollClock(now: { self.lock.withLock { self.current } }, sleep: { seconds in
            try self.lock.withLock {
                self.recorded.append(seconds)
                if self.recorded.count == self.cancelAtSleep { throw CancellationError() }
                self.current += seconds
            }
        })
    }
}

/// Device-code sign-in with ChatGPT (Codex CLI flow) against recorded responses.
final class CodexSignInTests: XCTestCase {
    private let now = date("2026-10-18T12:00:00Z")
    private let flow = CodexDeviceCodeFlow(auth: CodexAuth())

    private let idToken = jwt(["email": "user@example.com",
                               "https://api.openai.com/auth": ["chatgpt_account_id": "00000000-0000-0000-0000-000000000001"]])

    private func form(_ data: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func json(_ data: Data) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func challenge(interval: TimeInterval = 5, expiresIn: TimeInterval = 900)
        -> DeviceCodeChallenge<CodexDeviceCodeFlow.Pending> {
        DeviceCodeChallenge(
            code: DeviceCode(userCode: "ABCD-1234", verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
                             expiresAt: now.addingTimeInterval(expiresIn)),
            pending: .init(deviceAuthID: "deviceauth-1", userCode: "ABCD-1234", interval: interval))
    }

    private var approved: HTTPStub.Response {
        .json(#"{"authorization_code":"auth-code","code_challenge":"challenge","code_verifier":"verifier"}"#)
    }

    private var tokens: HTTPStub.Response {
        .json(#"{"access_token":"access-1","refresh_token":"refresh-1","id_token":"\#(idToken)"}"#)
    }

    // MARK: - Requesting a code

    func testRequestCodeShowsTheUserCodeAndVerificationPage() async throws {
        let session = HTTPStub.session([
            "POST /api/accounts/deviceauth/usercode":
                .json(#"{"device_auth_id":"deviceauth-1","user_code":"ABCD-1234","interval":"5"}"#),
        ])

        let started = try await flow.requestCode(session: session, now: now).get()

        XCTAssertEqual(started.code, DeviceCode(userCode: "ABCD-1234",
                                                verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
                                                expiresAt: now.addingTimeInterval(15 * 60)))
        XCTAssertEqual(started.pending, .init(deviceAuthID: "deviceauth-1", userCode: "ABCD-1234", interval: 5))
        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/api/accounts/deviceauth/usercode")
        XCTAssertEqual(json(HTTPStub.body(of: request)), ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann"])
    }

    func testRequestCodeAcceptsUsercodeSpellingNumericIntervalAndExpiry() async throws {
        let session = HTTPStub.session([
            "POST /api/accounts/deviceauth/usercode":
                .json(#"{"device_auth_id":"deviceauth-1","usercode":"WXYZ-0000","interval":3,"expires_at":"2026-10-18T12:10:00Z"}"#),
        ])

        let started = try await flow.requestCode(session: session, now: now).get()

        XCTAssertEqual(started.code.userCode, "WXYZ-0000")
        XCTAssertEqual(started.code.expiresAt, date("2026-10-18T12:10:00Z"))
        XCTAssertEqual(started.pending.interval, 3)
    }

    func testRefusedCodeRequestShowsTheServerMessage() async {
        let session = HTTPStub.session([
            "POST /api/accounts/deviceauth/usercode":
                .json(#"{"error":{"message":"Device code login is not enabled for this workspace."}}"#, status: 403),
        ])

        let result = await flow.requestCode(session: session, now: now)

        XCTAssertEqual(result.failure, .refused("Device code login is not enabled for this workspace."))
    }

    func testRefusedCodeRequestWithoutMessageShowsTheStatus() async {
        let session = HTTPStub.session(["POST /api/accounts/deviceauth/usercode": .status(404)])

        let result = await flow.requestCode(session: session, now: now)

        XCTAssertEqual(result.failure, .refused("Server returned 404"))
    }

    // MARK: - Waiting for approval

    func testPollsWhilePendingThenExchangesTheAuthorizationCode() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /api/accounts/deviceauth/token": [.status(403), .status(404), approved],
            "POST /oauth/token": [tokens],
        ])
        let clock = FakeClock(now: now)

        let credentials = try await flow.awaitApproval(challenge(), session: session, clock: clock.clock).get()

        XCTAssertEqual(credentials, CodexCredentials(accessToken: "access-1", refreshToken: "refresh-1", idToken: idToken))
        XCTAssertEqual(clock.sleeps, [5, 5, 5])
        let requests = HTTPStub.requests
        XCTAssertEqual(requests.map { $0.url?.path }, Array(repeating: "/api/accounts/deviceauth/token", count: 3) + ["/oauth/token"])
        XCTAssertEqual(json(HTTPStub.body(of: requests[0])), ["device_auth_id": "deviceauth-1", "user_code": "ABCD-1234"])
        let exchange = try XCTUnwrap(requests.last)
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(form(HTTPStub.body(of: exchange)), [
            "grant_type": "authorization_code",
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "code": "auth-code",
            "code_verifier": "verifier",
            "redirect_uri": "https://auth.openai.com/deviceauth/callback",
        ])
    }

    func testCodeExpiresWhileStillPending() async {
        let session = HTTPStub.session(["POST /api/accounts/deviceauth/token": .status(403)])
        let clock = FakeClock(now: now)

        let result = await flow.awaitApproval(challenge(interval: 5, expiresIn: 12), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .expired)
        XCTAssertEqual(HTTPStub.requests.count, 2)
    }

    func testRefusalWhilePollingShowsTheServerMessage() async {
        let session = HTTPStub.session([
            "POST /api/accounts/deviceauth/token": .json(#"{"error":{"message":"Access denied by the user."}}"#, status: 400),
        ])

        let result = await flow.awaitApproval(challenge(), session: session, clock: FakeClock(now: now).clock)

        XCTAssertEqual(result.failure, .refused("Access denied by the user."))
    }

    func testCancellingStopsPolling() async {
        let session = HTTPStub.session(["POST /api/accounts/deviceauth/token": .status(403)])
        let clock = FakeClock(now: now)
        clock.cancelAtSleep = 2

        let result = await flow.awaitApproval(challenge(), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }

    func testRefusedCodeExchangeShowsTheServerMessage() async {
        let session = HTTPStub.session([
            "POST /api/accounts/deviceauth/token": approved,
            "POST /oauth/token": .json(#"{"error":"invalid_grant","error_description":"Code already used."}"#, status: 400),
        ])

        let result = await flow.awaitApproval(challenge(), session: session, clock: FakeClock(now: now).clock)

        XCTAssertEqual(result.failure, .refused("Code already used."))
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
