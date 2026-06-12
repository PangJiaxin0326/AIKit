import Foundation
import Synchronization

/// A `URLProtocol` that returns a canned response for every request, so
/// provider tests never hit the network.
///
/// `@unchecked Sendable` is forced by subclassing `URLProtocol` (a
/// non-Sendable ObjC class); the stub's own shared state is `Mutex`-guarded.
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

    private struct Shared {
        var stub: Stub?
        var requests: [URLRequest] = []
    }

    private static let shared = Mutex(Shared())

    public static func setStub(_ stub: Stub?) {
        shared.withLock {
            $0.stub = stub
            $0.requests.removeAll()
        }
    }

    public static var recordedRequests: [URLRequest] {
        shared.withLock { $0.requests }
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
        let stub = Self.shared.withLock {
            $0.requests.append(request)
            return $0.stub
        }

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
