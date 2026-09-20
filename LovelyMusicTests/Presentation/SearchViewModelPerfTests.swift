import XCTest

@testable import LovelyMusic

@MainActor
final class SearchViewModelPerfTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Drain any in-flight detached UserDefaults writes from prior tests
        Thread.sleep(forTimeInterval: 0.1)
        UserDefaults.standard.removeObject(forKey: "searchHistory")
        UserDefaults.standard.removeObject(forKey: "search_history")
        UserDefaults.standard.removeObject(forKey: "pauseSearchHistory")
    }

    // MARK: - Helpers

    private func makeSong(id: String) -> Song {
        Song(
            id: id, title: "Song \(id)", artistName: "Artist", artistId: nil, albumName: nil,
            albumId: nil, duration: 200, thumbnailURL: nil)
    }

    private func makeAlbum(id: String) -> Album {
        Album(
            id: id, title: "Album \(id)", artistName: "Artist", artistId: nil, year: nil,
            thumbnailURL: nil, songs: [])
    }

    private func makeArtist(id: String) -> Artist {
        Artist(
            id: id, name: "Artist \(id)", thumbnailURL: nil, subscriberCount: nil, songs: [],
            albums: [], singles: [])
    }

    private func makePlaylist(id: String) -> Playlist {
        Playlist(id: id, title: "Playlist \(id)")
    }

    private func makeSUT() -> (SearchViewModel, MockInnerTubeRepository) {
        let mock = MockInnerTubeRepository()
        let searchUseCase = SearchMusicUseCase(repository: mock)
        let browseUseCase = BrowseHomeUseCase(repository: mock)
        let vm = SearchViewModel(searchUseCase: searchUseCase, browseHomeUseCase: browseUseCase)
        return (vm, mock)
    }

    /// Wait for an async condition to become true
    private func waitFor(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the expected SearchViewModel state")
    }

    // MARK: - ND-9: Cap accumulated result arrays at 200

    func testLoadMoreCapsResultsAt200Songs() async {
        let (vm, mock) = makeSUT()

        // Set up initial results with 195 songs + continuation token
        let initialSongs = (0..<195).map { makeSong(id: "s\($0)") }
        mock.searchResult = SearchResult(
            songs: initialSongs, albums: [], artists: [], playlists: [],
            continuation: "page2"
        )

        vm.query = "test"
        vm.search()
        await waitFor { vm.results.songs.count == 195 }
        XCTAssertEqual(vm.results.songs.count, 195)

        // Now loadMore appends 50 more -> total 245, should be capped to 200
        let moreSongs = (195..<245).map { makeSong(id: "s\($0)") }
        mock.continuationResult = SearchResult(
            songs: moreSongs, albums: [], artists: [], playlists: [],
            continuation: "page3"
        )

        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 1 && !vm.isLoadingMore }
        XCTAssertLessThanOrEqual(
            vm.results.songs.count, 200,
            "Songs should be capped at 200")
        // Should keep the most recent (suffix)
        XCTAssertEqual(vm.results.songs.last?.id, "s244")
    }

    func testLoadMoreCapsAlbumsArtistsPlaylistsAt50() async {
        let (vm, mock) = makeSUT()

        let initialAlbums = (0..<45).map { makeAlbum(id: "a\($0)") }
        let initialArtists = (0..<45).map { makeArtist(id: "ar\($0)") }
        let initialPlaylists = (0..<45).map { makePlaylist(id: "p\($0)") }

        mock.searchResult = SearchResult(
            songs: [], albums: initialAlbums, artists: initialArtists, playlists: initialPlaylists,
            continuation: "page2"
        )

        vm.query = "test"
        vm.search()
        await waitFor { vm.results.albums.count == 45 }

        let moreAlbums = (45..<65).map { makeAlbum(id: "a\($0)") }
        let moreArtists = (45..<65).map { makeArtist(id: "ar\($0)") }
        let morePlaylists = (45..<65).map { makePlaylist(id: "p\($0)") }
        mock.continuationResult = SearchResult(
            songs: [], albums: moreAlbums, artists: moreArtists, playlists: morePlaylists,
            continuation: "page3"
        )

        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 1 && !vm.isLoadingMore }
        XCTAssertLessThanOrEqual(vm.results.albums.count, 50, "Albums should be capped at 50")
        XCTAssertLessThanOrEqual(vm.results.artists.count, 50, "Artists should be capped at 50")
        XCTAssertLessThanOrEqual(vm.results.playlists.count, 50, "Playlists should be capped at 50")
    }

    func testLoadMoreDoesNotCapWhenUnderLimit() async {
        let (vm, mock) = makeSUT()

        let initialSongs = (0..<10).map { makeSong(id: "s\($0)") }
        mock.searchResult = SearchResult(
            songs: initialSongs, albums: [], artists: [], playlists: [],
            continuation: "page2"
        )

        vm.query = "test"
        vm.search()
        await waitFor { vm.results.songs.count == 10 }

        let moreSongs = (10..<15).map { makeSong(id: "s\($0)") }
        mock.continuationResult = SearchResult(
            songs: moreSongs, albums: [], artists: [], playlists: [],
            continuation: nil
        )

        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 1 && !vm.isLoadingMore }
        XCTAssertEqual(vm.results.songs.count, 15, "Should keep all songs when under cap")
    }

    func testLoadMorePreservesContinuationToken() async {
        let (vm, mock) = makeSUT()

        let initialSongs = (0..<195).map { makeSong(id: "s\($0)") }
        mock.searchResult = SearchResult(
            songs: initialSongs, albums: [], artists: [], playlists: [],
            continuation: "page2"
        )

        vm.query = "test"
        vm.search()
        await waitFor { vm.results.songs.count == 195 }

        let moreSongs = (195..<250).map { makeSong(id: "s\($0)") }
        mock.continuationResult = SearchResult(
            songs: moreSongs, albums: [], artists: [], playlists: [],
            continuation: "page3"
        )

        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 1 && !vm.isLoadingMore }
        XCTAssertEqual(
            vm.results.continuation, "page3", "Continuation token should be preserved after capping"
        )
    }

    func testLoadMoreDeduplicatesEveryResultTypeByID() async {
        let (vm, mock) = makeSUT()
        let initialSong = makeSong(id: "song-1")
        let initialAlbum = makeAlbum(id: "album-1")
        let initialArtist = makeArtist(id: "artist-1")
        let initialPlaylist = makePlaylist(id: "playlist-1")

        mock.searchResult = SearchResult(
            songs: [initialSong],
            albums: [initialAlbum],
            artists: [initialArtist],
            playlists: [initialPlaylist],
            continuation: "page2"
        )

        vm.query = "test"
        vm.search()
        await waitFor { vm.results.songs.count == 1 }

        mock.continuationResult = SearchResult(
            songs: [initialSong, makeSong(id: "song-2")],
            albums: [initialAlbum, makeAlbum(id: "album-2")],
            artists: [initialArtist, makeArtist(id: "artist-2")],
            playlists: [initialPlaylist, makePlaylist(id: "playlist-2")],
            continuation: nil
        )

        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 1 && !vm.isLoadingMore }

        XCTAssertEqual(vm.results.songs.map(\.id), ["song-1", "song-2"])
        XCTAssertEqual(vm.results.albums.map(\.id), ["album-1", "album-2"])
        XCTAssertEqual(vm.results.artists.map(\.id), ["artist-1", "artist-2"])
        XCTAssertEqual(vm.results.playlists.map(\.id), ["playlist-1", "playlist-2"])
    }

    func testCompletedEmptySearchDoesNotFallBackToSuggestions() async {
        let (vm, mock) = makeSUT()
        mock.searchResult = .empty

        vm.query = "no-match-query"
        vm.search()
        await waitFor { vm.searchHistory.first == "no-match-query" }

        XCTAssertFalse(
            vm.showSuggestions,
            "A submitted search that completed empty must render the empty state, not an empty suggestions list"
        )
    }

    func testClearSearchResetsHiddenFilterAndInitialSearchError() async {
        let (vm, mock) = makeSUT()
        mock.shouldThrow = true
        vm.selectFilter(.albums)
        vm.query = "test"

        vm.search()
        await waitFor { vm.error != nil }
        vm.clearSearch()

        XCTAssertEqual(vm.query, "")
        XCTAssertNil(vm.selectedFilter)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.hasResults)
        XCTAssertFalse(vm.showSuggestions)
    }

    func testFirstSearchDefaultsToSongsFilter() async {
        let (vm, mock) = makeSUT()
        vm.query = "test"

        vm.search()
        await waitFor { mock.searchCallCount == 1 }

        XCTAssertEqual(vm.selectedFilter, .songs)
        XCTAssertEqual(mock.lastSearchFilter, .songs)
    }

    func testExplicitAllFilterPersistsAcrossRetryOrRefresh() async {
        let (vm, mock) = makeSUT()
        vm.query = "test"
        vm.selectFilter(nil)

        vm.search()
        await waitFor { mock.searchCallCount == 1 }
        XCTAssertNil(mock.lastSearchFilter)

        vm.search()
        await waitFor { mock.searchCallCount == 2 }
        XCTAssertNil(mock.lastSearchFilter)
        XCTAssertNil(vm.selectedFilter)
    }

    func testResultRevisionChangesForAcceptedSearchButNotPagination() async {
        let (vm, mock) = makeSUT()
        mock.searchResult = SearchResult(
            songs: [makeSong(id: "song-1")],
            albums: [],
            artists: [],
            playlists: [],
            continuation: "page2"
        )
        vm.query = "first"
        vm.search()
        await waitFor { mock.searchCallCount == 1 && vm.results.songs.count == 1 }
        let firstRevision = vm.resultRevision

        mock.continuationResult = SearchResult(
            songs: [makeSong(id: "song-2")],
            albums: [],
            artists: [],
            playlists: [],
            continuation: nil
        )
        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 1 && !vm.isLoadingMore }
        XCTAssertEqual(vm.resultRevision, firstRevision)

        mock.searchResult = SearchResult(
            songs: [makeSong(id: "song-3")],
            albums: [],
            artists: [],
            playlists: [],
            continuation: nil
        )
        vm.query = "second"
        vm.search()
        await waitFor { mock.searchCallCount == 2 && vm.results.songs.first?.id == "song-3" }
        XCTAssertEqual(vm.resultRevision, firstRevision + 1)
    }

    func testLoadMoreFailureKeepsLoadedResultsAndDoesNotSetInitialSearchError() async {
        let (vm, mock) = makeSUT()
        mock.searchResult = SearchResult(
            songs: [makeSong(id: "song-1")],
            albums: [],
            artists: [],
            playlists: [],
            continuation: "page2"
        )

        vm.query = "test"
        vm.search()
        await waitFor { vm.results.songs.count == 1 }

        mock.shouldThrow = true
        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 1 && !vm.isLoadingMore }

        XCTAssertEqual(vm.results.songs.map(\.id), ["song-1"])
        XCTAssertNil(
            vm.error,
            "A pagination failure must not replace already-loaded results with the initial-search error screen"
        )
        XCTAssertNotNil(vm.paginationError)
        XCTAssertEqual(vm.results.continuation, "page2")

        mock.shouldThrow = false
        mock.continuationResult = SearchResult(
            songs: [makeSong(id: "song-2")],
            albums: [],
            artists: [],
            playlists: [],
            continuation: nil
        )
        vm.loadMore()
        await waitFor { mock.searchContinuationCallCount == 2 && !vm.isLoadingMore }

        XCTAssertNil(vm.paginationError)
        XCTAssertEqual(vm.results.songs.map(\.id), ["song-1", "song-2"])
    }

    // MARK: - M-01: Search history

    func testAddToHistoryUpdatesLocalState() {
        let (vm, _) = makeSUT()

        vm.addToHistory("test query")
        XCTAssertEqual(vm.searchHistory.first, "test query")
    }

    func testAddToHistoryDeduplicates() {
        let (vm, _) = makeSUT()

        vm.addToHistory("query1")
        vm.addToHistory("query2")
        vm.addToHistory("query1")  // should move to front
        XCTAssertEqual(vm.searchHistory.first, "query1")
        XCTAssertEqual(vm.searchHistory.count, 2)
    }

    func testAddToHistoryCapsAtTwenty() {
        let (vm, _) = makeSUT()

        for i in 0..<25 {
            vm.addToHistory("query\(i)")
        }
        XCTAssertLessThanOrEqual(vm.searchHistory.count, 20)
    }

    func testClearHistoryRemovesAll() {
        let (vm, _) = makeSUT()

        vm.addToHistory("test")
        vm.clearHistory()
        XCTAssertTrue(vm.searchHistory.isEmpty)
    }
}
