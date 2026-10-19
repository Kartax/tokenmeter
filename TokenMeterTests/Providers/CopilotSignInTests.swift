import XCTest
@testable import TokenMeter

/// GitHub device-code sign-in against recorded responses.
final class CopilotSignInTests: XCTestCase {
    private let now = date("2026-10-18T12:00:00Z")
    private let flow = CopilotDeviceCodeFlow(auth: CopilotAuth())

    private func form(_ data: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func challenge(expiresIn: TimeInterval = 900)
        -> DeviceCodeChallenge<CopilotDeviceCodeFlow.Pending> {
        DeviceCodeChallenge(
            code: DeviceCode(userCode: "ABCD-1234",
                             verificationURL: URL(string: "https://github.com/login/device")!,
                             expiresAt: now.addingTimeInterval(expiresIn)),
            pending: .init(deviceCode: "device-code-1", interval: 5))
    }

    private var tokens: HTTPStub.Response {
        .json(#"{"access_token":"gho_access","token_type":"bearer","scope":"read:user"}"#)
    }

    // MARK: - Requesting a code

    func testRequestCodeSendsTheCopilotClientAndShowsTheUserCode() async throws {
        let session = HTTPStub.session([
            "POST /login/device/code":
                .json(#"{"device_code":"dc-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","verification_uri_complete":"https://github.com/login/device?user_code=ABCD-1234","expires_in":900,"interval":5}"#),
        ])

        let started = try await flow.requestCode(session: session, now: now).get()

        XCTAssertEqual(started.code.userCode, "ABCD-1234")
        XCTAssertEqual(started.code.verificationURL,
                       URL(string: "https://github.com/login/device?user_code=ABCD-1234")!)
        XCTAssertEqual(started.code.expiresAt, now.addingTimeInterval(900))
        XCTAssertEqual(started.pending, .init(deviceCode: "dc-1", interval: 5))
        let request = try XCTUnwrap(HTTPStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(form(HTTPStub.body(of: request)), [
            "client_id": "Iv1.b507a08c87ecfe98",
            "scope": "read:user",
        ])
    }

    func testRequestWithoutTheCompleteURLOpensThePlainVerificationURI() async throws {
        let session = HTTPStub.session([
            "POST /login/device/code":
                .json(#"{"device_code":"dc-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
        ])

        let started = try await flow.requestCode(session: session, now: now).get()

        XCTAssertEqual(started.code.verificationURL, URL(string: "https://github.com/login/device")!)
    }

    func testRefusedCodeRequestShowsTheServerMessage() async {
        let session = HTTPStub.session([
            "POST /login/device/code":
                .json(#"{"error":"unauthorized_client","error_description":"Device flow is not enabled."}"#, status: 400),
        ])

        let result = await flow.requestCode(session: session, now: now)

        XCTAssertEqual(result.failure, .refused("Device flow is not enabled."))
    }

    // MARK: - Polling

    func testPollsWhilePendingThenReturnsTheGithubToken() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /login/oauth/access_token": [
                .json(#"{"error":"authorization_pending"}"#),
                tokens,
            ],
        ])
        let clock = FakeClock(now: now)

        let credentials = try await flow.awaitApproval(challenge(), session: session, clock: clock.clock).get()

        XCTAssertEqual(credentials, CopilotCredentials(token: "gho_access"))
        XCTAssertEqual(clock.sleeps, [5, 5])
        let requests = HTTPStub.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/login/oauth/access_token", "/login/oauth/access_token"])
        XCTAssertEqual(form(HTTPStub.body(of: requests[0])), [
            "client_id": "Iv1.b507a08c87ecfe98",
            "device_code": "device-code-1",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
    }

    func testSlowDownRaisesTheIntervalByFiveSeconds() async throws {
        let session = HTTPStub.session(sequences: [
            "POST /login/oauth/access_token": [
                .json(#"{"error":"slow_down"}"#),
                tokens,
            ],
        ])
        let clock = FakeClock(now: now)

        _ = try await flow.awaitApproval(challenge(), session: session, clock: clock.clock).get()

        XCTAssertEqual(clock.sleeps, [5, 10])
    }

    func testExpiredTokenEndsTheSignIn() async {
        let session = HTTPStub.session([
            "POST /login/oauth/access_token": .json(#"{"error":"expired_token"}"#),
        ])

        let result = await flow.awaitApproval(challenge(), session: session, clock: FakeClock(now: now).clock)

        XCTAssertEqual(result.failure, .expired)
    }

    func testAccessDeniedShowsTheServerDescription() async {
        let session = HTTPStub.session([
            "POST /login/oauth/access_token":
                .json(#"{"error":"access_denied","error_description":"The user denied the request."}"#),
        ])

        let result = await flow.awaitApproval(challenge(), session: session, clock: FakeClock(now: now).clock)

        XCTAssertEqual(result.failure, .refused("The user denied the request."))
    }

    func testExpiryStopsPolling() async {
        let session = HTTPStub.session([
            "POST /login/oauth/access_token": .json(#"{"error":"authorization_pending"}"#),
        ])
        let clock = FakeClock(now: now)

        let result = await flow.awaitApproval(challenge(expiresIn: 12), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .expired)
        XCTAssertEqual(clock.sleeps, [5, 5, 5])
        XCTAssertEqual(HTTPStub.requests.count, 2)
    }

    func testCancellingStopsPolling() async {
        let session = HTTPStub.session([
            "POST /login/oauth/access_token": .json(#"{"error":"authorization_pending"}"#),
        ])
        let clock = FakeClock(now: now)
        clock.cancelAtSleep = 2

        let result = await flow.awaitApproval(challenge(), session: session, clock: clock.clock)

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(HTTPStub.requests.count, 1)
    }
}
