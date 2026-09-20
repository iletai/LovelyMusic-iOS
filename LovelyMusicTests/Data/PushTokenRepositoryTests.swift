import XCTest
@testable import LovelyMusic

final class PushTokenRepositoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(PushTokenURLProtocolStub.self)
    }

    override func tearDown() {
        PushTokenURLProtocolStub.reset()
        URLProtocol.unregisterClass(PushTokenURLProtocolStub.self)
        super.tearDown()
    }

    func testTokenLocalPersistence() async throws {
        let testSuite = "com.lovelymusic.test.pushtoken.\(UUID().uuidString)"
        let repo = PushTokenRepository(
            userDefaultsSuite: testSuite,
            baseURL: URL(string: "https://unregister-test.example.com")
        )
        let sampleToken = "deadbeef1234567890abcdef"

        try await repo.saveTokenLocally(sampleToken)
        let retrieved = await repo.getPersistedToken()
        XCTAssertEqual(retrieved, sampleToken)

        // Unregister must call the backend before clearing the local token.
        PushTokenURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        try await repo.unregisterToken()
        let cleared = await repo.getPersistedToken()
        XCTAssertNil(cleared)

        let unregister = PushTokenURLProtocolStub.capturedRequests.first
        XCTAssertEqual(unregister?.httpMethod, "POST")
        XCTAssertEqual(unregister?.url?.path, "/api/v1/devices/unregister")
        let body = try unregister?.bodyData()
        XCTAssertTrue(
            try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String]
                == ["deviceToken": sampleToken]
        )
    }
}

/// Minimal URLProtocol stub — intercepts `URLSession.shared` traffic so the
/// repository's backend calls never touch the network in unit tests.
final class PushTokenURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []

    static var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _capturedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _capturedRequests = []
        handler = nil
    }

    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._capturedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// Returns the request body regardless of whether it lives in `httpBody`
    /// or is streamed via `httpBodyStream` (URLSession moves it into the
    /// stream when handed off to a URLProtocol).
    func bodyData() throws -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
