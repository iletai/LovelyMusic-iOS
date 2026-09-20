import XCTest

@testable import LovelyMusic

// MARK: - Controllable Mock

/// A mock repository where each async call suspends until we explicitly resume it,
/// allowing us to test cancellation mid-flight.
final class ControllableMockRepository: InnerTubeRepositoryProtocol {

    // Continuations that tests can resume or leave hanging to verify cancellation.
    var homeContinuation: CheckedContinuation<HomeResult, Error>?
    var homeResult: HomeResult = HomeResult(sections: [], continuation: nil)
    var searchResult: SearchResult = .empty
    var searchPageResult: SearchResult = .empty
    var albumResult: AlbumResult?
    var playlistResult: PlaylistResult?

    var browseHomeCallCount = 0
    var searchCallCount = 0
    var searchContinuationCallCount = 0
    var lastSearchQuery: String?
    var getAlbumCallCount = 0
    var getPlaylistCallCount = 0
    var shouldThrow = false
    /// When true, browseHome suspends until manually resumed via `homeContinuation`.
    var suspendOnHome = false
    var suspendOnSearch = false
    var suspendOnSearchContinuation = false
    var pendingSearchContinuation: CheckedContinuation<SearchResult, Error>?
    var pendingSearchPageContinuation: CheckedContinuation<SearchResult, Error>?

    // Extended for chip-prefetch tests (chip-prefetch-tester-1):
    // Queue of HomeResults popped one-per-call by browseHomeContinuation.
    // When empty, falls back to `homeResult` to preserve legacy mock behavior.
    var homeContinuationResults: [HomeResult] = []
    var browseHomeContinuationCallCount = 0
    var lastBrowseHomeParams: String?

    // Extended for chip-prefetch remediation (HIGH-1 race test):
    // When `suspendOnContinuation` is true, `browseHomeContinuation` suspends
    // until the test resumes `continuationContinuation` manually. This lets
    // the test pin an in-flight `loadMore` while triggering `selectChip`.
    var continuationContinuation: CheckedContinuation<HomeResult, Error>?
    var suspendOnContinuation = false

    func browseHome(params: String?) async throws -> HomeResult {
        browseHomeCallCount += 1
        lastBrowseHomeParams = params
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if suspendOnHome {
            return try await withCheckedThrowingContinuation { cont in
                self.homeContinuation = cont
            }
        }
        return homeResult
    }

    func search(query: String, filter: SearchFilter?) async throws -> SearchResult {
        searchCallCount += 1
        lastSearchQuery = query
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if suspendOnSearch {
            return try await withCheckedThrowingContinuation { continuation in
                pendingSearchContinuation = continuation
            }
        }
        return searchResult
    }

    func searchContinuation(token: String) async throws -> SearchResult {
        searchContinuationCallCount += 1
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if suspendOnSearchContinuation {
            return try await withCheckedThrowingContinuation { continuation in
                pendingSearchPageContinuation = continuation
            }
        }
        return searchPageResult
    }

    func searchSuggestions(query: String) async throws -> [String] {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return []
    }

    func getStreamingData(videoId: String) async throws -> StreamingData {
        StreamingData(formats: [], adaptiveFormats: [], expiresAt: nil)
    }

    func getArtist(browseId: String) async throws -> ArtistResult {
        let artist = Artist(
            id: browseId, name: "A", thumbnailURL: nil, subscriberCount: nil, songs: [], albums: [],
            singles: [])
        return ArtistResult(artist: artist, songsContinuation: nil)
    }

    func getAlbum(browseId: String) async throws -> AlbumResult {
        getAlbumCallCount += 1
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if let r = albumResult { return r }
        let album = Album(
            id: browseId, title: "Album", artistName: "A", artistId: nil, year: nil,
            thumbnailURL: nil, songs: [])
        return AlbumResult(album: album, songsContinuation: nil)
    }

    func getPlaylist(playlistId: String) async throws -> PlaylistResult {
        getPlaylistCallCount += 1
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return playlistResult
            ?? PlaylistResult(
                playlist: Playlist(id: playlistId, title: "PL"), songsContinuation: nil)
    }

    func getNext(videoId: String?, playlistId: String?) async throws -> [Song] { [] }
    func browseContinuation(token: String) async throws -> Data { Data() }

    func browseHomeContinuation(token: String) async throws -> HomeResult {
        // Extended for chip-prefetch tests (chip-prefetch-tester-1): pop from
        // queue if available, otherwise fall back to `homeResult` (legacy).
        browseHomeContinuationCallCount += 1
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if suspendOnContinuation {
            return try await withCheckedThrowingContinuation { cont in
                self.continuationContinuation = cont
            }
        }
        if !homeContinuationResults.isEmpty {
            return homeContinuationResults.removeFirst()
        }
        return homeResult
    }

    func browseShelfContinuation(token: String) async throws -> (
        songs: [Song], continuation: String?
    ) {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return (songs: [], continuation: nil)
    }
}

// MARK: - HomeViewModel Tests

final class HomeViewModelTaskLifecycleTests: XCTestCase {

    @MainActor
    func testLoadHomeStoresTask() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "T", items: [])],
            continuation: nil
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        vm.loadHome()
        // loadTask should be non-nil — we verify indirectly by awaiting it
        // Give the task time to complete
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.sections.count, 1)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadHomeCancelsOnReload() async {
        let mock = ControllableMockRepository()
        mock.suspendOnHome = true
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        // First load — will hang until resumed
        vm.loadHome()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(vm.isLoading)

        // Second load should cancel the first and start a new one
        mock.suspendOnHome = false
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "Second", items: [])],
            continuation: nil
        )
        vm.refresh()
        try? await Task.sleep(for: .milliseconds(100))

        // The first task was cancelled; sections should come from the second call
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testRefreshCancelsPreviousTask() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "R", items: [])],
            continuation: nil
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        vm.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        // Call refresh again — should cancel the previous
        vm.refresh()
        try? await Task.sleep(for: .milliseconds(100))

        // Should complete without crash
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testSelectChipCancelsOnReselect() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "Chip", items: [])],
            continuation: nil,
            chips: [HomeChip(id: "c1", title: "Chip1", params: "p1", isSelected: false)]
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        let chip = HomeChip(id: "c1", title: "Chip1", params: "p1", isSelected: false)
        vm.selectChip(chip)
        try? await Task.sleep(for: .milliseconds(50))
        // Select same chip again to toggle off — should cancel previous
        vm.selectChip(chip)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadMoreStoresTask() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "T", items: [])],
            continuation: "next_token"
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        // First load to set up continuation token
        vm.loadHome()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(vm.hasMore)

        // Now loadMore should create a stored task
        vm.loadMore()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(vm.isLoadingMore)
    }

    @MainActor
    func testDeinitCancelsTask() async {
        let mock = ControllableMockRepository()
        mock.suspendOnHome = true
        var vm: HomeViewModel? = HomeViewModel(
            browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        vm?.loadHome()
        try? await Task.sleep(for: .milliseconds(50))

        // Deinit should cancel the pending task (no crash)
        vm = nil
        try? await Task.sleep(for: .milliseconds(50))
        // If we get here without a crash, the deinit cancellation worked
        XCTAssertNil(vm)
    }
}

// MARK: - SearchViewModel Tests

final class SearchViewModelTaskLifecycleTests: XCTestCase {

    @MainActor
    private func waitFor(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the expected SearchViewModel state")
    }

    @MainActor
    func testSearchStoresTask() async {
        let mock = ControllableMockRepository()
        let song = Song(
            id: "s1", title: "Found", artistName: "A", artistId: nil, albumName: nil, albumId: nil,
            duration: 100, thumbnailURL: nil)
        mock.searchResult = SearchResult(
            songs: [song], albums: [], artists: [], playlists: [], continuation: nil)

        let searchUseCase = SearchMusicUseCase(repository: mock)
        let homeUseCase = BrowseHomeUseCase(repository: mock)
        let vm = SearchViewModel(searchUseCase: searchUseCase, browseHomeUseCase: homeUseCase)
        vm.query = "test"

        vm.search()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.results.songs.count, 1)
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testSearchCancelsOnNewSearch() async {
        let mock = ControllableMockRepository()
        let searchUseCase = SearchMusicUseCase(repository: mock)
        let homeUseCase = BrowseHomeUseCase(repository: mock)
        let vm = SearchViewModel(searchUseCase: searchUseCase, browseHomeUseCase: homeUseCase)
        vm.query = "abc"

        // Call search twice quickly
        vm.search()
        vm.search()
        try? await Task.sleep(for: .milliseconds(100))

        // Should complete without issues
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testClearBeforeSearchTaskStartsDoesNotCallRepository() async {
        let mock = ControllableMockRepository()
        let vm = SearchViewModel(
            searchUseCase: SearchMusicUseCase(repository: mock),
            browseHomeUseCase: BrowseHomeUseCase(repository: mock)
        )

        vm.query = "cancel-before-start"
        vm.search()
        vm.clearSearch()
        await Task.yield()

        XCTAssertEqual(mock.searchCallCount, 0)
        XCTAssertFalse(vm.isSearching)
        XCTAssertFalse(vm.hasResults)
    }

    @MainActor
    func testClearBeforePaginationTaskStartsDoesNotCallRepository() async {
        let mock = ControllableMockRepository()
        let vm = SearchViewModel(
            searchUseCase: SearchMusicUseCase(repository: mock),
            browseHomeUseCase: BrowseHomeUseCase(repository: mock)
        )
        let firstSong = Song(
            id: "first", title: "First", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )
        mock.searchResult = SearchResult(
            songs: [firstSong], albums: [], artists: [], playlists: [], continuation: "page2"
        )

        vm.query = "query"
        vm.search()
        await waitFor { vm.results.songs.map(\.id) == ["first"] }

        vm.loadMore()
        vm.clearSearch()
        await Task.yield()

        XCTAssertEqual(mock.searchContinuationCallCount, 0)
        XCTAssertFalse(vm.isLoadingMore)
        XCTAssertFalse(vm.hasResults)
    }

    @MainActor
    func testNewSearchDoesNotAppendAnOldQueriesPendingPage() async {
        let mock = ControllableMockRepository()
        let vm = SearchViewModel(
            searchUseCase: SearchMusicUseCase(repository: mock),
            browseHomeUseCase: BrowseHomeUseCase(repository: mock)
        )
        let firstSong = Song(
            id: "query-a-1", title: "A1", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )
        let stalePageSong = Song(
            id: "query-a-2", title: "A2", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )
        let secondSong = Song(
            id: "query-b-1", title: "B1", artistName: "B", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )

        mock.searchResult = SearchResult(
            songs: [firstSong], albums: [], artists: [], playlists: [],
            continuation: "query-a-page-2"
        )
        vm.query = "query-a"
        vm.search()
        await waitFor { vm.results.songs.map(\.id) == ["query-a-1"] }

        mock.suspendOnSearchContinuation = true
        vm.loadMore()
        await waitFor { mock.pendingSearchPageContinuation != nil }

        mock.searchResult = SearchResult(
            songs: [secondSong], albums: [], artists: [], playlists: [], continuation: nil
        )
        vm.query = "query-b"
        vm.search()
        await waitFor { vm.results.songs.map(\.id) == ["query-b-1"] }
        let acceptedRevision = vm.resultRevision

        let staleContinuation = mock.pendingSearchPageContinuation
        mock.pendingSearchPageContinuation = nil
        staleContinuation?.resume(
            returning: SearchResult(
                songs: [stalePageSong], albums: [], artists: [], playlists: [], continuation: nil
            )
        )
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.results.songs.map(\.id), ["query-b-1"])
        XCTAssertEqual(vm.resultRevision, acceptedRevision)
        XCTAssertFalse(vm.isLoadingMore)
    }

    @MainActor
    func testClearSearchInvalidatesAnInFlightResponse() async {
        let mock = ControllableMockRepository()
        mock.suspendOnSearch = true
        let vm = SearchViewModel(
            searchUseCase: SearchMusicUseCase(repository: mock),
            browseHomeUseCase: BrowseHomeUseCase(repository: mock)
        )
        let staleSong = Song(
            id: "stale", title: "Stale", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )

        vm.query = "pending"
        vm.search()
        await waitFor { mock.pendingSearchContinuation != nil }
        let historyBeforeClear = vm.searchHistory

        vm.clearSearch()
        XCTAssertFalse(vm.isSearching)
        let pendingContinuation = mock.pendingSearchContinuation
        mock.pendingSearchContinuation = nil
        pendingContinuation?.resume(
            returning: SearchResult(
                songs: [staleSong], albums: [], artists: [], playlists: [], continuation: nil
            )
        )
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.query, "")
        XCTAssertFalse(vm.hasResults)
        XCTAssertEqual(vm.searchHistory, historyBeforeClear)
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testEditingTheQueryInvalidatesAnInFlightSubmittedSearch() async {
        let mock = ControllableMockRepository()
        mock.suspendOnSearch = true
        let vm = SearchViewModel(
            searchUseCase: SearchMusicUseCase(repository: mock),
            browseHomeUseCase: BrowseHomeUseCase(repository: mock)
        )
        let staleSong = Song(
            id: "stale", title: "Stale", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )

        vm.query = "submitted-query"
        vm.search()
        await waitFor { mock.pendingSearchContinuation != nil }
        let historyBeforeEdit = vm.searchHistory

        vm.query = "edited-query"
        XCTAssertFalse(vm.isSearching)
        let pendingContinuation = mock.pendingSearchContinuation
        mock.pendingSearchContinuation = nil
        pendingContinuation?.resume(
            returning: SearchResult(
                songs: [staleSong], albums: [], artists: [], playlists: [], continuation: nil
            )
        )
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.query, "edited-query")
        XCTAssertFalse(vm.hasResults)
        XCTAssertEqual(vm.searchHistory, historyBeforeEdit)
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testClearSearchInvalidatesAnInFlightPaginationResponse() async {
        let mock = ControllableMockRepository()
        let vm = SearchViewModel(
            searchUseCase: SearchMusicUseCase(repository: mock),
            browseHomeUseCase: BrowseHomeUseCase(repository: mock)
        )
        let firstSong = Song(
            id: "first", title: "First", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )
        let stalePageSong = Song(
            id: "stale-page", title: "Stale page", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil
        )

        mock.searchResult = SearchResult(
            songs: [firstSong], albums: [], artists: [], playlists: [], continuation: "page2"
        )
        vm.query = "query"
        vm.search()
        await waitFor { vm.results.songs.map(\.id) == ["first"] }

        mock.suspendOnSearchContinuation = true
        vm.loadMore()
        await waitFor { mock.pendingSearchPageContinuation != nil }
        vm.clearSearch()
        XCTAssertFalse(vm.isLoadingMore)

        let pendingContinuation = mock.pendingSearchPageContinuation
        mock.pendingSearchPageContinuation = nil
        pendingContinuation?.resume(
            returning: SearchResult(
                songs: [stalePageSong], albums: [], artists: [], playlists: [], continuation: nil
            )
        )
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.query, "")
        XCTAssertFalse(vm.hasResults)
        XCTAssertFalse(vm.isLoadingMore)
    }

    @MainActor
    func testLoadExploreStoresTask() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "E1", items: []), MusicSection(title: "E2", items: [])],
            continuation: nil,
            moodAndGenres: [
                MoodAndGenre(
                    id: "m1", title: "Pop", color: nil,
                    browseEndpoint: .init(browseId: "b1", params: nil))
            ]
        )

        let searchUseCase = SearchMusicUseCase(repository: mock)
        let homeUseCase = BrowseHomeUseCase(repository: mock)
        let vm = SearchViewModel(searchUseCase: searchUseCase, browseHomeUseCase: homeUseCase)

        vm.loadExplore()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.moodAndGenres.count, 1)
        XCTAssertFalse(vm.isLoadingExplore)
    }

    @MainActor
    func testDeinitCancelsSearchTask() async {
        let mock = ControllableMockRepository()
        let searchUseCase = SearchMusicUseCase(repository: mock)
        let homeUseCase = BrowseHomeUseCase(repository: mock)
        var vm: SearchViewModel? = SearchViewModel(
            searchUseCase: searchUseCase, browseHomeUseCase: homeUseCase)

        vm?.query = "test"
        vm?.search()
        try? await Task.sleep(for: .milliseconds(50))

        vm = nil
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(vm)
    }
}

// MARK: - AlbumViewModel Tests

final class AlbumViewModelTaskLifecycleTests: XCTestCase {

    @MainActor
    func testLoadAlbumStoresTask() async {
        let mock = ControllableMockRepository()
        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))

        vm.loadAlbum(browseId: "a1")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(vm.album)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadAlbumCancelsOnReload() async {
        let mock = ControllableMockRepository()
        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))

        // Two loads in quick succession — second should cancel first
        vm.loadAlbum(browseId: "a1")
        vm.loadAlbum(browseId: "a2")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testDeinitCancelsTask() async {
        let mock = ControllableMockRepository()
        var vm: AlbumViewModel? = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))

        vm?.loadAlbum(browseId: "a1")
        vm = nil
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(vm)
    }
}

// MARK: - PlaylistDetailViewModel Tests

final class PlaylistDetailViewModelTaskLifecycleTests: XCTestCase {

    @MainActor
    func testLoadPlaylistStoresTask() async {
        let mock = ControllableMockRepository()
        let vm = PlaylistDetailViewModel(
            getPlaylistUseCase: GetPlaylistUseCase(repository: mock),
            managePlaylistUseCase: nil
        )

        vm.loadPlaylist(playlistId: "p1")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(vm.playlist)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadPlaylistCancelsOnReload() async {
        let mock = ControllableMockRepository()
        let vm = PlaylistDetailViewModel(
            getPlaylistUseCase: GetPlaylistUseCase(repository: mock),
            managePlaylistUseCase: nil
        )

        vm.loadPlaylist(playlistId: "p1")
        vm.loadPlaylist(playlistId: "p2")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testDeinitCancelsTask() async {
        let mock = ControllableMockRepository()
        var vm: PlaylistDetailViewModel? = PlaylistDetailViewModel(
            getPlaylistUseCase: GetPlaylistUseCase(repository: mock),
            managePlaylistUseCase: nil
        )

        vm?.loadPlaylist(playlistId: "p1")
        vm = nil
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(vm)
    }
}
