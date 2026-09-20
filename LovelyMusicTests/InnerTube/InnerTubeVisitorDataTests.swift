import XCTest
@testable import LovelyMusic

/// Tests for `polish-B2` (visitorData hardening) and `polish-B3` (cache-policy bypass).
/// Uses a custom `URLProtocol` stub registered on the `URLSessionConfiguration` passed
/// into `InnerTubeAPI` so we can capture every outbound `URLRequest` and serve canned
/// responses without hitting the network.
final class InnerTubeVisitorDataTests: XCTestCase {

    // MARK: - Test infrastructure

    private var defaultsSuiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "InnerTubeVisitorDataTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        URLProtocolStub.reset()
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeAPI(handler: @escaping URLProtocolStub.Handler) -> InnerTubeAPI {
        URLProtocolStub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        // Ensure URLCache is a no-op for tests so cachePolicy assertions are meaningful.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        return InnerTubeAPI(session: session, userDefaults: userDefaults)
    }

    // MARK: - 1. Header is plain ASCII, never percent-encoded

    func test_visitorDataHeader_isPlainAscii_neverPercentEncoded() async throws {
        // Stubbed sw.js_data returns a valid token with '=' padding characters.
        // InnerTubeAPI must NOT URL-encode '=' to '%3D' in the X-Goog-Visitor-Id header.
        let storedToken = "CgtSZXN0VG9rZW5BcmlhbjA9PQ=="
        let swJsData = ")]}'\n[[0,0,[\"\(storedToken)\"]]]"

        let api = makeAPI { request in
            if request.url?.path == "/sw.js_data" {
                let body = Data(swJsData.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, body)
            }
            if request.url?.host == "music.youtube.com" && request.url?.path == "/" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data())
            }
            // music.youtube.com search endpoint — return empty JSON
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        _ = try? await api.search(query: "abc")

        let captured = URLProtocolStub.capturedRequests
        guard let searchRequest = captured.first(where: {
            $0.url?.host == "music.youtube.com" && $0.httpMethod == "POST"
        }) else {
            XCTFail("No search request captured")
            return
        }

        let headerValue = searchRequest.value(forHTTPHeaderField: "X-Goog-Visitor-Id")
        XCTAssertEqual(headerValue, storedToken,
            "Header must be the raw stored value with '=' intact, not URL-encoded")
        // Sanity: ensure '=' was not encoded to '%3D'
        XCTAssertFalse(headerValue?.contains("%3D") ?? false,
            "Header must not URL-encode '=' to '%3D'")
    }

    // MARK: - 2. Empty header when no cache and refresh fails

    func test_visitorDataFallback_usesDefault_whenNoCacheAndRefreshFails() async throws {
        // Both sw.js_data and music.youtube.com HTML fallback return 500.
        // No UserDefaults cache. Header must carry the hardcoded default token.
        let api = makeAPI { request in
            if request.url?.host == "music.youtube.com" && request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        _ = try? await api.search(query: "anything")

        guard let searchRequest = URLProtocolStub.capturedRequests.first(where: {
            $0.url?.host == "music.youtube.com" && $0.httpMethod == "POST"
        }) else {
            XCTFail("No search request captured")
            return
        }

        let headerValue = searchRequest.value(forHTTPHeaderField: "X-Goog-Visitor-Id")
        // In degraded state, the default generated token is used — never empty
        XCTAssertTrue(
            headerValue?.hasPrefix("Cgt") == true && (headerValue?.count ?? 0) > 20,
            "Expected valid visitor token in degraded state, got: \(headerValue ?? "nil")"
        )
    }

    // MARK: - 3. Persistence write/read within TTL

    func test_visitorDataPersistence_writeReadRoundtrip_withinTTL() async throws {
        // Pre-seed UserDefaults with a value written 12 hours ago (within 24h TTL).
        let token = "CgtPRVJTSVNURURfVE9LRU5fWFla"
        let twelveHoursAgo = Date().timeIntervalSince1970 - (12 * 3600)
        userDefaults.set(token, forKey: "innerTube.visitorData.lastGood")
        userDefaults.set(twelveHoursAgo, forKey: "innerTube.visitorData.lastGoodAt")

        // Build API — hydration happens in init.
        let api = makeAPI { request in
            // All refresh sources fail so they cannot overwrite the persisted value.
            if request.url?.host == "music.youtube.com" && request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        let hydrated = await api.visitorData
        XCTAssertEqual(hydrated, token, "Persisted visitorData within TTL must hydrate on init")
    }

    // MARK: - 4. Persistence expires after 24 hours

    func test_visitorDataPersistence_expires_after24Hours() async throws {
        // Pre-seed with a value written 2 days ago (beyond 24h TTL).
        let token = "CgtFWFBJUkVEX1RPS0VO"
        let twoDaysAgo = Date().timeIntervalSince1970 - (2 * 86_400)
        userDefaults.set(token, forKey: "innerTube.visitorData.lastGood")
        userDefaults.set(twoDaysAgo, forKey: "innerTube.visitorData.lastGoodAt")

        let api = makeAPI { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data())
        }

        let hydrated = await api.visitorData
        // Expired token is not hydrated — visitorData falls back to generated default token
        XCTAssertNotEqual(hydrated, token, "Expired persisted visitorData must NOT hydrate (2 days > 24h TTL)")
        XCTAssertTrue(hydrated.hasPrefix("Cgt") && hydrated.count > 20)
    }

    // MARK: - 5. Cache policy is reloadIgnoringLocalCacheData on every InnerTube POST

    func test_cachePolicy_isReloadIgnoringLocal_onAllInnerTubePOSTs() async throws {
        // Stub sw.js_data so refresh can succeed quickly.
        let swJsData = ")]}'\n[[0,0,[\"CgtGUkVTSF9UT0tFTg==\"]]]"
        let api = makeAPI { request in
            if request.url?.path == "/sw.js_data" {
                let body = Data(swJsData.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, body)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        _ = try? await api.search(query: "q1")
        _ = try? await api.browse(browseId: "FEmusic_home")

        let postRequests = URLProtocolStub.capturedRequests.filter {
            $0.httpMethod == "POST" && $0.url?.host == "music.youtube.com"
        }
        XCTAssertGreaterThanOrEqual(postRequests.count, 2,
            "Expected at least one search and one browse POST")
        for request in postRequests {
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData,
                "POST to \(request.url?.path ?? "") must bypass URLCache")
        }
    }

    // MARK: - 6. Degraded state set after two failures, cleared on success

    func test_degradedState_setsAfterTwoFailures_andClearsOnSuccess() async throws {
        // Use a counter so we can flip from failure → success on the same stub.
        let state = StubState()

        let api = makeAPI { request in
            // Both sw.js_data and music.youtube.com HTML requests go through the same host
            if request.url?.host == "music.youtube.com" && request.httpMethod == "GET" {
                let shouldFail = state.shouldFailHomepage()
                let code = shouldFail ? 500 : 200
                var body = Data()
                if !shouldFail {
                    if request.url?.path == "/sw.js_data" {
                        body = Data(")]}'\n[[0,0,[\"CgtSRUNPVkVSRURfVE9LRU4=\"]]]".utf8)
                    } else {
                        body = Data("""
                        <script>{"visitorData":"CgtSRUNPVkVSRURfVE9LRU4="}</script>
                        """.utf8)
                    }
                }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, body)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        // Drive ensureFreshVisitorData via two search calls. Each call performs
        // the in-call retry; the timestamp stays nil on failure so the next call
        // re-enters the refresh path.
        // Each ensure-cycle hits sw.js_data (initial + retry) + HTML fallback (initial + retry) = 4 GET hits per cycle
        // Two ensure-cycles = 8 failures needed
        state.failHomepageCalls = 8
        _ = try? await api.search(query: "first")
        _ = try? await api.search(query: "second")

        let degradedAfterFailures = await api.degradedVisitorState
        XCTAssertTrue(degradedAfterFailures, "Expected degraded=true after 2 ensure-cycle failures")

        // Now allow success on the next refresh — visitorDataTimestamp is nil
        // so the next call re-enters refresh; success should clear degraded.
        state.failHomepageCalls = 0
        _ = try? await api.search(query: "third")

        let degradedAfterSuccess = await api.degradedVisitorState
        XCTAssertFalse(degradedAfterSuccess, "Expected degraded=false after recovery")
    }
}

// MARK: - URLProtocolStub

/// Captures every outgoing `URLRequest` and serves a canned response generated by
/// `handler`. Thread-safe; intentionally minimal — no streaming, no chunking.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _capturedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _capturedRequests = []
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._capturedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Mutable state holder for handler closures

/// Small reference container used to share mutable counters with `URLProtocolStub.handler`
/// closures (which are otherwise capture-by-value).
private final class StubState: @unchecked Sendable {
    var failHomepageCalls: Int = 0

    func shouldFailHomepage() -> Bool {
        if failHomepageCalls > 0 {
            failHomepageCalls -= 1
            return true
        }
        return false
    }
}
