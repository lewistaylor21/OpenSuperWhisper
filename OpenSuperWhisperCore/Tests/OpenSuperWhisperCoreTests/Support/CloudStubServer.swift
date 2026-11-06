import Foundation

/// URLProtocol stub shared by xAI / Gemini engine tests. Records requests and returns a
/// queued status/body. Never talks to the network.
final class CloudStubServer: URLProtocol {
    struct Received {
        let url: String
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var responses: [(status: Int, body: String)] = []
    private static var received: [Received] = []

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudStubServer.self]
        return config
    }

    static func reset(responses: [(Int, String)] = []) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses.map { (status: $0.0, body: $0.1) }
        received = []
    }

    static var requests: [Received] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = Received(url: request.url?.absoluteString ?? "",
                              method: request.httpMethod ?? "",
                              headers: request.allHTTPHeaderFields ?? [:],
                              body: Self.readBody(of: request))
        let answer: (status: Int, body: String) = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self.received.append(record)
            return Self.responses.isEmpty ? (500, "no stubbed response") : Self.responses.removeFirst()
        }()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
