import XCTest

@testable import LovelyMusic

/// Edge-case tests beyond the core `InnerTubeVisitorDataTests` suite. Targets
/// risk note R-impl-1 from the data implementer (homepage backoff bound) and
/// the recovery contract requested by the tester runbook.
///
/// Reuses `URLProtocolStub` from `InnerTubeVisitorDataTests.swift`.
final class InnerTubeVisitorDataExtraTests: XCTestCase {

    private var defaultsSuiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "InnerTubeVisitorDataExtraTests.\(UUID().uuidString)"
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
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        return InnerTubeAPI(session: session, userDefaults: userDefaults)
    }

    // MARK: - 1. Bounded completion under slow homepage (R-impl-1)

    /// When YouTube's homepage is slow (but eventually returns), the
    /// visitorData refresh + downstream call must complete within a generous
    /// upper bound. Guards against unbounded actor-serialised backoff.
    func test_visitorDataRefresh_underHomepageTimeout_completesWithinBoundedTime() async throws {
        // Each sw.js_data hit sleeps ~300ms before returning a successful body.
        // Worst case: 1 sw.js_data hit (no retry needed) ≈ 0.3s + search ≈ negligible.
        // Bound at 5.0s — well above the 1.5s backoff window even on a contended runner.
        let swJsData = ")]}'\n[[0,0,[\"CgtCT1VOREVEX1RPS0VO\"]]]"
        let api = makeAPI { request in
            if request.url?.host == "music.youtube.com" && request.httpMethod == "GET" {
                Thread.sleep(forTimeInterval: 0.3)
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

        let start = Date()
        _ = try? await api.search(query: "bounded")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThanOrEqual(
            elapsed, 5.0,
            "visitorData refresh + search should complete within 5s; took \(elapsed)s")
    }

    // MARK: - 2. Recovery after transient failure updates header & clears degraded

    /// A first refresh cycle fails; the second succeeds. The downstream search
    /// after recovery must carry the *fresh* token in `X-Goog-Visitor-Id`, and
    /// `degradedVisitorState` must be false.
    func test_visitorDataRefresh_recoversAfterTransientFailure() async throws {
        let state = TransientStubState()
        let recoverySwJsData = ")]}'\n[[0,0,[\"CgtSRUNPVkVSWV9UT0tFTg==\"]]]"

        let api = makeAPI { request in
            if request.url?.host == "music.youtube.com" && request.httpMethod == "GET" {
                if state.shouldFailHomepage() {
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                        headerFields: nil)!
                    return (response, Data())
                }
                let body = Data(recoverySwJsData.utf8)
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

        // Fail the first cycle entirely (sw.js_data + HTML fallback = 2 GET calls):
        state.failHomepageCalls = 2
        _ = try? await api.search(query: "first")
        // Second call re-enters refresh because timestamp stayed nil; this time succeeds.
        _ = try? await api.search(query: "second")

        let degraded = await api.degradedVisitorState
        XCTAssertFalse(
            degraded,
            "degradedVisitorState should clear once refresh succeeds")

        // Find the LAST search request — its header should carry the recovered token.
        let searchRequests = URLProtocolStub.capturedRequests.filter {
            $0.url?.host == "music.youtube.com" && $0.httpMethod == "POST"
        }
        guard let lastSearch = searchRequests.last else {
            XCTFail("Expected at least one search request")
            return
        }
        XCTAssertEqual(
            lastSearch.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
            "CgtSRUNPVkVSWV9UT0tFTg==",
            "After recovery, downstream calls must use the freshly-fetched token"
        )
    }

    // MARK: - 3. UserDefaults suite isolation between API instances

    /// Two `InnerTubeAPI` instances built with independent UserDefaults suites
    /// must NOT see each other's persisted visitorData. Guards against the
    /// global-key-collision risk if a future change accidentally hardcodes
    /// `UserDefaults.standard`.
    func test_visitorDataPersistence_isIsolatedBetweenSuites() async throws {
        let suiteA = "InnerTubeVisitorData.SuiteA.\(UUID().uuidString)"
        let suiteB = "InnerTubeVisitorData.SuiteB.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suiteA)!
        let defaultsB = UserDefaults(suiteName: suiteB)!
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }

        // Seed only suite A with a fresh token.
        defaultsA.set("TOKEN_FOR_A_ONLY", forKey: "innerTube.visitorData.lastGood")
        defaultsA.set(Date().timeIntervalSince1970, forKey: "innerTube.visitorData.lastGoodAt")

        // Both APIs use a homepage stub that fails so refresh cannot mask hydration.
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        config.urlCache = nil
        let sessionA = URLSession(configuration: config)
        let sessionB = URLSession(configuration: config)

        let apiA = InnerTubeAPI(session: sessionA, userDefaults: defaultsA)
        let apiB = InnerTubeAPI(session: sessionB, userDefaults: defaultsB)

        let hydratedA = await apiA.visitorData
        let hydratedB = await apiB.visitorData

        XCTAssertEqual(hydratedA, "TOKEN_FOR_A_ONLY")
        XCTAssertNotEqual(hydratedB, "TOKEN_FOR_A_ONLY", "Suite B must NOT inherit suite A's visitorData")
        XCTAssertTrue(hydratedB.hasPrefix("Cgt") && hydratedB.count > 20)
    }
}

// MARK: - Local stub state (separate type to avoid clashing with the file-private
// `StubState` declared in InnerTubeVisitorDataTests.swift)

private final class TransientStubState: @unchecked Sendable {
    var failHomepageCalls: Int = 0

    func shouldFailHomepage() -> Bool {
        if failHomepageCalls > 0 {
            failHomepageCalls -= 1
            return true
        }
        return false
    }
}
