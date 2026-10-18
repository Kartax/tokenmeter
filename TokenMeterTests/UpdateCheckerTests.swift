import XCTest
@testable import TokenMeter

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var configDirectory: URL!
    private var session: URLSession!

    override func setUp() async throws {
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCheckerTests-\(UUID())", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubStub.self]
        session = URLSession(configuration: config)
        GitHubStub.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configDirectory)
        GitHubStub.reset()
    }

    private func makeChecker(currentVersion: String) -> UpdateChecker {
        UpdateChecker(session: session, currentVersion: currentVersion,
                      config: ConfigStore(url: configDirectory.appendingPathComponent("config.json")))
    }

    func testNewerLatestReleaseIsOffered() async {
        GitHubStub.respond(status: 200, body: #"{"tag_name": "v0.2.0", "name": "TokenMeter 0.2.0"}"#)
        let checker = makeChecker(currentVersion: "0.1.0")

        await checker.check()

        XCTAssertEqual(checker.availableUpdate, "0.2.0")
        XCTAssertEqual(GitHubStub.requests.map(\.url?.absoluteString),
                       ["https://api.github.com/repos/Kartax/tokenmeter/releases/latest"])
    }

    func testRunningTheLatestReleaseOffersNothing() async {
        GitHubStub.respond(status: 200, body: #"{"tag_name": "v0.1.0"}"#)
        let checker = makeChecker(currentVersion: "0.1.0")

        await checker.check()

        XCTAssertNil(checker.availableUpdate)
    }

    func testDevelopmentBuildAheadOfLatestReleaseOffersNothing() async {
        GitHubStub.respond(status: 200, body: #"{"tag_name": "v0.1.0"}"#)
        let checker = makeChecker(currentVersion: "0.2.0")

        await checker.check()

        XCTAssertNil(checker.availableUpdate)
    }

    func testNoPublishedReleaseYetIsSilent() async {
        GitHubStub.respond(status: 404, body: #"{"message": "Not Found", "status": "404"}"#)
        let checker = makeChecker(currentVersion: "0.1.0")

        await checker.check()

        XCTAssertNil(checker.availableUpdate)
    }

    func testCheckIsOnByDefault() {
        XCTAssertTrue(makeChecker(currentVersion: "0.1.0").isEnabled)
    }

    func testWithCheckOffNoRequestIsMade() async {
        GitHubStub.respond(status: 200, body: #"{"tag_name": "v0.2.0"}"#)
        let checker = makeChecker(currentVersion: "0.1.0")
        checker.isEnabled = false

        await checker.check()

        XCTAssertTrue(GitHubStub.requests.isEmpty)
        XCTAssertNil(checker.availableUpdate)
    }

    func testTurningCheckOffHidesOfferedUpdate() async {
        GitHubStub.respond(status: 200, body: #"{"tag_name": "v0.2.0"}"#)
        let checker = makeChecker(currentVersion: "0.1.0")
        await checker.check()

        checker.isEnabled = false

        XCTAssertNil(checker.availableUpdate)
    }

    func testCheckOffSurvivesRestart() async {
        makeChecker(currentVersion: "0.1.0").isEnabled = false
        GitHubStub.respond(status: 200, body: #"{"tag_name": "v0.2.0"}"#)

        let afterRestart = makeChecker(currentVersion: "0.1.0")
        await afterRestart.check()

        XCTAssertFalse(afterRestart.isEnabled)
        XCTAssertTrue(GitHubStub.requests.isEmpty)
    }
}

/// Answers every request with one canned GitHub API response and records the requests.
private final class GitHubStub: URLProtocol {
    private static let lock = NSLock()
    private static var response: (status: Int, body: Data)?
    private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func respond(status: Int, body: String) {
        lock.withLock { response = (status, Data(body.utf8)) }
    }

    static func reset() {
        lock.withLock {
            response = nil
            recorded = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let canned = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.response
        }
        guard let canned else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: canned.status,
                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
