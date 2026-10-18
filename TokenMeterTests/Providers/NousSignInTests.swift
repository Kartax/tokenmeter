import XCTest
@testable import TokenMeter

/// Device-code sign-in with Nous Portal (RFC 8628, Hermes client) against recorded responses.
final class NousSignInTests: XCTestCase {
    private let now = date("2026-10-18T12:00:00Z")
    private let flow = NousDeviceCodeFlow(auth: NousAuth())

    private func form(_ data: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func json(_ data: Data) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func challenge(expiresIn: TimeInterval = 900)
        -> DeviceCodeChallenge<NousDeviceCodeFlow.Pending> {
        DeviceCodeChallenge(
            code: DeviceCode(userCode: "WXYZ-5678",
                             verificationURL: URL(string: "https://portal.nousresearch.com/device?user_code=WXYZ-5678")!,
                             expiresAt: now.addingTimeInterval(expiresIn)),
            pending: .init(deviceCode: "device-code-1", interval: 5))
    }

    private var tokens: HTTPStub.Response {
        .json(#"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600,"token_type":"Bearer","scope":"inference:invoke"}"#)
    }

    // MARK: - Requesting a code

    func testRequestCodeSendsClientIDAndScopeAndShowsTheUserCode() async throws {
        let session = HTTPStub.session([
            "POST /api/oauth/device/code":
                .json(#"{"device_code":"dc-1","user_code":"WXYZ-5678","verification_uri":"https://portal.nousresearch.com/device","verification_uri_complete":"https://portal.nousresearch.com/device?user_code=WXYZ-5678","expires_in":900,"interval":5}"#),
        ])

        let started = try await flow.requestCode(session: session, now: now).get()

        XCTAssertEqual(started.code.userCode, "WXYZ-5678")
        XCTAssertEqual(started.code.verificationURL, URL(string: "https://portal.nousresearch.com/device?user_code=WXYZ-5678")!)
        XCTAssertEqual(started.code.expiresAt, now.addingTimeInterval(900))
        XCTAssertEqual(started.pending, .init(deviceCode: "dc-1", interval: 5))
        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://portal.nousresearch.com/api/oauth/device/code")
        XCTAssertEqual(form(HTTPStub.body(of: request)), ["client_id": "hermes-cli", "scope": "inference:invoke"])
    }

    func testRequestWithoutTheCompleteURLOpensThePlainVerificationURI() async throws {
        let session = HTTPStub.session([
            "POST /api/oauth/device/code":
                .json(#"{"device_code":"dc-1","user_code":"WXYZ-5678","verification_uri":"https://portal.nousresearch.com/device","expires_in":900,"interval":5}"#),
        ])

        let started = try await flow.requestCode(session: session, now: now).get()

        XCTAssertEqual(started.code.verificationURL, URL(string: "https://portal.nousresearch.com/device")!)
    }

    func testRefusedCodeRequestShowsTheServerMessage() async {
        let session = HTTPStub.session([
            "POST /api/oauth/device/code":
                .json(#"{"error":"access_denied","error_description":"Client is not allowed."}"#, status: 403),
        ])

        let result = await flow.requestCode(session: session, now: now)

        XCTAssertEqual(result.failure, .refused("Client is not allowed."))
    }

    func testStringIntervalAndExpiresInAreAccepted() async throws {
        let session = HTTPStub.session([
            "POST /api/oauth/device/code":
                .json(#"{"device_code":"dc-1","user_code":"WXYZ-5678","verification_uri":"https://portal.nousresearch.com/device","expires_in":"900","interval":"5"}"#),
        ])

        let started = try await flow.requestCode(session: session, now: now).get()

        XCTAssertEqual(started.code.expiresAt, now.addingTimeInterval(900))
        XCTAssertEqual(started.pending.interval, 5)
    }

    // MARK: - Polling (RFC 8628)

    func testPollsWhilePendingThenReturnsTheTokens() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [
                .json(#"{"error":"authorization_pending"}"#, status: 400),
                .json(#"{"error":"authorization_pending"}"#, status: 400),
                tokens,
            ],
        ])
        let clock = FakeClock(now: now)

        let credentials = try await flow.awaitApproval(challenge(), session: session, clock: clock.clock).get()

        XCTAssertEqual(credentials, NousCredentials(accessToken: "access-1", refreshToken: "refresh-1"))
        XCTAssertEqual(clock.sleeps, [5, 5, 5])
        let requests = HTTPStub.requests
        XCTAssertEqual(requests.map { $0.url?.path }, Array(repeating: "/api/oauth/token", count: 3))
        XCTAssertEqual(form(HTTPStub.body(of: requests.first!)), [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": "hermes-cli",
            "device_code": "device-code-1",
        ])
    }

    func testSlowDownRaisesTheIntervalByOneSecond() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [
                .json(#"{"error":"slow_down"}"#, status: 400),
                .json(#"{"error":"slow_down"}"#, status: 400),
                tokens,
            ],
        ])
        let clock = FakeClock(now: now)

        _ = try await flow.awaitApproval(challenge(), session: session, clock: clock.clock).get()

        XCTAssertEqual(clock.sleeps, [5, 6, 7])
    }

    func testSlowDownIntervalIsCappedAt30Seconds() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [.json(#"{"error":"slow_down"}"#, status: 400)] + Array(repeating: tokens, count: 30),
        ])
        let clock = FakeClock(now: now)
        var slowChallenge = challenge()
        slowChallenge.pending.interval = 30

        _ = try await flow.awaitApproval(slowChallenge, session: session, clock: clock.clock).get()

        XCTAssertEqual(clock.sleeps.first, 30, "The interval never grows beyond 30 s")
    }

    func testNonJSONBackoffEdgeStatusesWaitAndKeepPolling() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [
                .status(408),
                .status(429, headers: ["Retry-After": "7"]),
                .status(500),
                tokens,
            ],
        ])
        let clock = FakeClock(now: now)

        let credentials = try await flow.awaitApproval(challenge(), session: session, clock: clock.clock).get()

        XCTAssertEqual(credentials.accessToken, "access-1")
        XCTAssertEqual(clock.sleeps, [5, 60, 5, 7, 5, 60, 5],
                       "sleep, 408 → 60 s cap, sleep, 429 honours Retry-After, sleep, 500 → 60 s cap, sleep")
    }

    func testNonJSONBackoffHonoursARetryAfterAboveTheCapOnlyUpToTheCap() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [.status(429, headers: ["Retry-After": "300"]), tokens],
        ])
        let clock = FakeClock(now: now)

        _ = try await flow.awaitApproval(challenge(), session: session, clock: clock.clock).get()

        XCTAssertEqual(clock.sleeps, [5, 60, 5])
    }

    func testJSONErrorOn408Or5xxIsRefused() async {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [.json(#"{"error":"server_error","error_description":"Broken."}"#, status: 500)],
        ])
        let clock = FakeClock(now: now)

        let result = await flow.awaitApproval(challenge(), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .refused("Broken."))
    }

    func testOtherJSONErrorRefusesWithTheServerMessage() async {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [.json(#"{"error":"access_denied","error_description":"Not allowed."}"#, status: 400)],
        ])
        let clock = FakeClock(now: now)

        let result = await flow.awaitApproval(challenge(), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .refused("Not allowed."))
    }

    func testExpiresAtTimesOutTheSheet() async {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [.json(#"{"error":"authorization_pending"}"#, status: 400)],
        ])
        let clock = FakeClock(now: now)

        let result = await flow.awaitApproval(challenge(expiresIn: 30), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .expired)
        XCTAssertEqual(clock.sleeps.count, 6,
                       "sleeps of 5 s before polls at 12:00:05…12:00:35; the poll at 12:00:35 is past expiry")
        XCTAssertFalse(HTTPStub.requests.isEmpty)
    }

    func testCancellingStopsPolling() async {
        let session = HTTPStub.session(sequences: [
            "POST /api/oauth/token": [.json(#"{"error":"authorization_pending"}"#, status: 400)],
        ])
        let clock = FakeClock(now: now)
        clock.cancelAtSleep = 2

        let result = await flow.awaitApproval(challenge(), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }
}