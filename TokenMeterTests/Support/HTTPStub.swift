import Foundation

/// URLProtocol stub for seam A tests: replays canned responses and records requests.
///
///     let session = HTTPStub.session([
///         "GET /api/balance": .fixture("ollama-balance-allowance"),
///         "POST /api/me": .status(500),
///     ])
///     … provider.read(…, session: session, …)
///     HTTPStub.requests   // what was sent
///
/// Routes are keyed by "METHOD path" (no query). An unrouted request fails with
/// `URLError(.unsupportedURL)`. Tests in this bundle run serially, so the routes are global;
/// each `session(_:)` call replaces them and clears the recorded requests.
///
/// `session(sequences:)` answers successive requests to one route with successive responses
/// (the last one repeats), e.g. `["GET /usage": [.status(401), .json("{…}")]]`.
final class HTTPStub: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func status(_ status: Int, headers: [String: String] = [:], body: Data = Data()) -> Response {
            Response(status: status, headers: headers, body: body)
        }

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
                     body: Data(text.utf8))
        }

        /// A JSON file from `TokenMeterTests/Fixtures` (by file name without extension).
        static func fixture(_ name: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
                     body: Fixture.data(name))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [Response]] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    /// A session whose requests are answered from `routes`.
    static func session(_ routes: [String: Response]) -> URLSession {
        session(sequences: routes.mapValues { [$0] })
    }

    /// A session answering each route's requests with its responses in order; the last repeats.
    static func session(sequences routes: [String: [Response]]) -> URLSession {
        lock.withLock {
            self.routes = routes
            recorded = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        return URLSession(configuration: configuration)
    }

    /// Requests received since the last `session(_:)` call, in order.
    static var requests: [URLRequest] { lock.withLock { recorded } }

    /// The body of a recorded request (URLProtocol only sees `httpBodyStream`).
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let response: Response? = Self.lock.withLock {
            Self.recorded.append(request)
            guard var queue = Self.routes[key], let first = queue.first else { return nil }
            if queue.count > 1 {
                queue.removeFirst()
                Self.routes[key] = queue
            }
            return first
        }
        guard let response, let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                         headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Recorded, anonymised responses in `TokenMeterTests/Fixtures` (bundled flat, so names are unique).
enum Fixture {
    static func data(_ name: String) -> Data {
        guard let url = Bundle(for: HTTPStub.self).url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(name).json")
        }
        return data
    }
}
