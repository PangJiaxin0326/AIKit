import Foundation

/// A `URLProtocol` that returns a canned response for every request, so
/// provider tests never hit the network.
public final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    public struct Stub: Sendable {
        public var statusCode: Int
        public var body: Data
        public var headers: [String: String]

        public init(
            statusCode: Int = 200,
            body: Data,
            headers: [String: String] = ["Content-Type": "application/json"]
        ) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    // swiftlint:disable:next - process-wide test fixture guarded by `lock`
    nonisolated(unsafe) private static var stub: Stub?
    // swiftlint:disable:next - process-wide test fixture guarded by `lock`
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    public static func setStub(_ stub: Stub?) {
        lock.lock()
        defer { lock.unlock() }
        Self.stub = stub
        Self.requests.removeAll()
    }

    public static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Builds a `URLSession` whose only protocol is this stub.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    public override class func canInit(with request: URLRequest) -> Bool { true }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        Self.lock.lock()
        let stub = Self.stub
        Self.requests.append(request)
        Self.lock.unlock()

        guard let stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}
}
