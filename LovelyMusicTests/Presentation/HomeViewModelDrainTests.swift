import XCTest

@testable import LovelyMusic

/// Feature 2 — Continuation drain tests for `HomeViewModel`.
///
/// Covers: drain disabled (default mini-drain), drain enabled (budget
/// enforcement), partial failure resilience, cancellation, and the
/// `HomeContinuationDrainPolicy.default` compile-time contract.
///
/// Uses a dedicated `DrainTestRepository` that tracks continuation calls
/// and supports configurable page counts, failure injection, and delays.
@MainActor
final class HomeViewModelDrainTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM(
        initialSections: Int = 2,
        continuationPages: Int = 6,
        throwAtPage: Int? = nil,
        delayPerPage: TimeInterval = 0,
        policy: HomeContinuationDrainPolicy = .default
    ) -> (HomeViewModel, DrainTestRepository) {
        let repo = DrainTestRepository(
            initialSectionCount: initialSections,
            totalContinuationPages: continuationPages,
            throwAtPage: throwAtPage,
            delayPerPage: delayPerPage
        )
        let useCase = BrowseHomeUseCase(repository: repo)
        let vm = HomeViewModel(browseHomeUseCase: useCase, drainPolicy: policy)
        return (vm, repo)
    }

    // MARK: - HomeContinuationDrainPolicy.default contract

    func testDefaultPolicyIsDisabled() {
        let policy = HomeContinuationDrainPolicy.default
        XCTAssertFalse(policy.isEnabled, "Default policy must have isEnabled == false")
    }

    func testDefaultPolicyMaxPages() {
        let policy = HomeContinuationDrainPolicy.default
        XCTAssertEqual(policy.maxPages, 10)
    }

    func testDefaultPolicyMaxDuration() {
        let policy = HomeContinuationDrainPolicy.default
        XCTAssertEqual(policy.maxDuration, 4.0, accuracy: 0.01)
    }

    // MARK: - Drain disabled (mini-drain path)

    func testDrainDisabled_usesLegacyMiniDrain_stopsAtMaxInitialPages() async throws {
        let (vm, repo) = makeVM(
            initialSections: 2,
            continuationPages: 10,
            policy: .default  // isEnabled = false
        )

        vm.loadHome()

        // Wait for async load — mini-drain loads at most maxInitialPages (3)
        try await Task.sleep(nanoseconds: 500_000_000)

        // mini-drain: 1 initial + up to 2 more = ≤ 3 pages total
        XCTAssertLessThanOrEqual(
            repo.continuationCallCount, 2,
            "Mini-drain must not fetch more than maxInitialPages-1 continuations"
        )
    }

    // MARK: - Drain enabled

    func testDrainEnabled_loadsUntilContinuationNil() async throws {
        let policy = HomeContinuationDrainPolicy(maxPages: 10, maxDuration: 10.0, isEnabled: true)
        let (vm, repo) = makeVM(
            initialSections: 2,
            continuationPages: 4,
            policy: policy
        )

        vm.loadHome()
        try await Task.sleep(nanoseconds: 500_000_000)

        // 4 continuation pages, then continuation=nil stops
        XCTAssertEqual(
            repo.continuationCallCount, 4,
            "Drain should load all 4 pages before stopping at nil continuation"
        )
        // 2 initial + 4 continuation = 6 sections
        XCTAssertEqual(vm.sections.count, 6)
    }

    func testDrainEnabled_stopsAtMaxPages() async throws {
        let policy = HomeContinuationDrainPolicy(maxPages: 5, maxDuration: 30.0, isEnabled: true)
        let (vm, repo) = makeVM(
            initialSections: 2,
            continuationPages: 15,
            policy: policy
        )

        vm.loadHome()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertLessThanOrEqual(
            repo.continuationCallCount, 5,
            "Drain must stop at maxPages even if continuation is still available"
        )
    }

    func testDrainEnabled_partialResultsOnMidDrainFailure() async throws {
        let policy = HomeContinuationDrainPolicy(maxPages: 10, maxDuration: 10.0, isEnabled: true)
        // Fail at page 3 — pages 1,2 should still surface
        let (vm, _) = makeVM(
            initialSections: 2,
            continuationPages: 6,
            throwAtPage: 3,
            policy: policy
        )

        vm.loadHome()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Pages 1,2 succeeded → 2 continuation sections + 2 initial = 4
        XCTAssertEqual(vm.sections.count, 4, "Partial results must surface on mid-drain failure")
        XCTAssertNil(vm.error, "Partial drain failure should not set error (resilience)")
    }

    // MARK: - Cancellation

    func testDrainCancellation_stopsCleanly() async throws {
        let policy = HomeContinuationDrainPolicy(maxPages: 10, maxDuration: 30.0, isEnabled: true)
        let (vm, repo) = makeVM(
            initialSections: 2,
            continuationPages: 10,
            delayPerPage: 0.2,
            policy: policy
        )

        vm.loadHome()
        // Let initial load + first continuation start
        try await Task.sleep(nanoseconds: 400_000_000)
        // Cancel by refreshing (which cancels loadTask)
        vm.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)

        // The original drain should have been cancelled
        XCTAssertLessThan(
            repo.continuationCallCount, 10,
            "Cancelled drain must stop fetching"
        )
    }
}

// MARK: - DrainTestRepository

/// A purpose-built mock conforming to `InnerTubeRepositoryProtocol` that
/// serves a configurable number of continuation pages, supports failure
/// injection, and tracks call counts. Isolated from the shared
/// `MockInnerTubeRepository` to avoid polluting other test suites.
private final class DrainTestRepository: InnerTubeRepositoryProtocol {
    let initialSectionCount: Int
    let totalContinuationPages: Int
    let throwAtPage: Int?
    let delayPerPage: TimeInterval

    /// Tracks how many times `browseHomeContinuation` was called.
    private(set) var continuationCallCount = 0

    init(
        initialSectionCount: Int,
        totalContinuationPages: Int,
        throwAtPage: Int?,
        delayPerPage: TimeInterval
    ) {
        self.initialSectionCount = initialSectionCount
        self.totalContinuationPages = totalContinuationPages
        self.throwAtPage = throwAtPage
        self.delayPerPage = delayPerPage
    }

    private func stubSong(_ index: Int) -> Song {
        Song(
            id: "s\(index)", title: "Song \(index)", artistName: "A",
            artistId: nil, albumName: nil, albumId: nil,
            duration: nil, thumbnailURL: nil
        )
    }

    func browseHome(params: String?) async throws -> HomeResult {
        let sections = (0..<initialSectionCount).map { i in
            MusicSection(title: "Init-\(i)", items: [.song(stubSong(i))])
        }
        return HomeResult(
            sections: sections,
            continuation: totalContinuationPages > 0 ? "cont_1" : nil
        )
    }

    func browseHomeContinuation(token: String) async throws -> HomeResult {
        continuationCallCount += 1
        let page = continuationCallCount

        if delayPerPage > 0 {
            try await Task.sleep(nanoseconds: UInt64(delayPerPage * 1_000_000_000))
        }

        if let failPage = throwAtPage, page >= failPage {
            throw NSError(domain: "DrainTest", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Injected failure at page \(page)"
            ])
        }

        let section = MusicSection(
            title: "Cont-\(page)",
            items: [.song(stubSong(100 + page))]
        )
        let hasMore = page < totalContinuationPages
        return HomeResult(
            sections: [section],
            continuation: hasMore ? "cont_\(page + 1)" : nil
        )
    }

    // MARK: - Unused protocol stubs

    func search(query: String, filter: SearchFilter?) async throws -> SearchResult { .empty }
    func searchContinuation(token: String) async throws -> SearchResult { .empty }
    func searchSuggestions(query: String) async throws -> [String] { [] }
    func getStreamingData(videoId: String) async throws -> StreamingData {
        StreamingData(formats: [], adaptiveFormats: [], expiresAt: nil)
    }
    func getArtist(browseId: String) async throws -> ArtistResult {
        ArtistResult(artist: Artist(id: browseId, name: "", thumbnailURL: nil, subscriberCount: nil, songs: [], albums: [], singles: []), songsContinuation: nil)
    }
    func getAlbum(browseId: String) async throws -> AlbumResult {
        AlbumResult(album: Album(id: browseId, title: "", artistName: "", artistId: nil, year: nil, thumbnailURL: nil, songs: []), songsContinuation: nil)
    }
    func browseContinuation(token: String) async throws -> Data { Data() }
    func browseShelfContinuation(token: String) async throws -> (songs: [Song], continuation: String?) { ([], nil) }
    func getPlaylist(playlistId: String) async throws -> PlaylistResult {
        PlaylistResult(playlist: Playlist(id: playlistId, title: ""), songsContinuation: nil)
    }
    func getNext(videoId: String?, playlistId: String?) async throws -> [Song] { [] }
}
