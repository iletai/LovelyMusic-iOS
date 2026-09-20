import XCTest
@testable import LovelyMusic

@MainActor
final class ArtistViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeSong(id: String, title: String = "Song") -> Song {
        Song(id: id, title: title, artistName: "Art", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
    }

    /// Starts loadArtist (which dispatches a Task internally) and waits until isLoading becomes false.
    private func loadArtistAndWait(_ vm: ArtistViewModel, browseId: String) async {
        vm.loadArtist(browseId: browseId)
        // Give the internal Task time to start and finish
        while vm.isLoading || vm.artist == nil && vm.error == nil {
            await Task.yield()
        }
        // Small extra yield to ensure state settles
        await Task.yield()
    }

    /// Starts loadMoreSongs (which dispatches a Task internally) and waits until isLoadingMore becomes false.
    private func loadMoreSongsAndWait(_ vm: ArtistViewModel) async {
        vm.loadMoreSongs()
        // Give the internal Task time to start
        await Task.yield()
        while vm.isLoadingMore {
            await Task.yield()
        }
        await Task.yield()
    }

    // MARK: - loadArtist does NOT exhaust continuations

    func testLoadArtistDoesNotFetchAllContinuations() async {
        // Given: an artist with a continuation token
        let mock = MockInnerTubeRepository()
        let songs = [makeSong(id: "s1"), makeSong(id: "s2")]
        let artist = Artist(id: "a1", name: "Artist", thumbnailURL: nil, subscriberCount: nil, songs: songs, albums: [], singles: [])
        mock.artistResult = ArtistResult(artist: artist, songsContinuation: "page2-token")

        let vm = ArtistViewModel(getArtistUseCase: GetArtistUseCase(repository: mock))

        // When
        await loadArtistAndWait(vm, browseId: "a1")

        // Then: only the first page songs are loaded, continuation is NOT exhausted
        XCTAssertEqual(vm.artist?.songs.count, 2)
        XCTAssertTrue(vm.hasMoreSongs, "Should still have more songs to load")
        // browseContinuation should NOT have been called during loadArtist
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 0, "loadArtist should not call browseContinuation at all")
    }

    // MARK: - hasMoreSongs

    func testHasMoreSongsIsTrueWhenContinuationExists() async {
        let mock = MockInnerTubeRepository()
        let artist = Artist(id: "a1", name: "Artist", thumbnailURL: nil, subscriberCount: nil, songs: [makeSong(id: "s1")], albums: [], singles: [])
        mock.artistResult = ArtistResult(artist: artist, songsContinuation: "token")

        let vm = ArtistViewModel(getArtistUseCase: GetArtistUseCase(repository: mock))
        await loadArtistAndWait(vm, browseId: "a1")

        XCTAssertTrue(vm.hasMoreSongs)
    }

    func testHasMoreSongsIsFalseWhenNoContinuation() async {
        let mock = MockInnerTubeRepository()
        let artist = Artist(id: "a1", name: "Artist", thumbnailURL: nil, subscriberCount: nil, songs: [makeSong(id: "s1")], albums: [], singles: [])
        mock.artistResult = ArtistResult(artist: artist, songsContinuation: nil)

        let vm = ArtistViewModel(getArtistUseCase: GetArtistUseCase(repository: mock))
        await loadArtistAndWait(vm, browseId: "a1")

        XCTAssertFalse(vm.hasMoreSongs)
    }

    // MARK: - loadMoreSongs

    func testLoadMoreSongsAppendsResults() async {
        let mock = MockInnerTubeRepository()
        let initialSongs = [makeSong(id: "s1")]
        let artist = Artist(id: "a1", name: "Artist", thumbnailURL: nil, subscriberCount: nil, songs: initialSongs, albums: [], singles: [])
        mock.artistResult = ArtistResult(artist: artist, songsContinuation: "page2")

        let useCase = GetArtistUseCase(repository: mock)
        let vm = ArtistViewModel(getArtistUseCase: useCase)
        await loadArtistAndWait(vm, browseId: "a1")

        XCTAssertEqual(vm.artist?.songs.count, 1)

        await loadMoreSongsAndWait(vm)

        // browseContinuation was called exactly once
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 1)
    }

    func testLoadMoreSongsGuardsWhenNoContinuation() async {
        let mock = MockInnerTubeRepository()
        let artist = Artist(id: "a1", name: "Artist", thumbnailURL: nil, subscriberCount: nil, songs: [makeSong(id: "s1")], albums: [], singles: [])
        mock.artistResult = ArtistResult(artist: artist, songsContinuation: nil)

        let vm = ArtistViewModel(getArtistUseCase: GetArtistUseCase(repository: mock))
        await loadArtistAndWait(vm, browseId: "a1")

        // When: no continuation token
        vm.loadMoreSongs()

        // Then: browseContinuation was never called
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 0)
    }

    func testLoadMoreSongsHandlesError() async {
        let mock = MockInnerTubeRepository()
        let artist = Artist(id: "a1", name: "Artist", thumbnailURL: nil, subscriberCount: nil, songs: [makeSong(id: "s1")], albums: [], singles: [])
        mock.artistResult = ArtistResult(artist: artist, songsContinuation: "page2")

        let vm = ArtistViewModel(getArtistUseCase: GetArtistUseCase(repository: mock))
        await loadArtistAndWait(vm, browseId: "a1")

        // Make continuation calls throw
        mock.shouldThrow = true
        await loadMoreSongsAndWait(vm)

        // Should have attempted and failed gracefully
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 1)
        XCTAssertFalse(vm.isLoadingMore, "isLoadingMore should be reset after error")
    }

    // MARK: - isLoadingMore flag

    func testIsLoadingMoreResetsAfterLoad() async {
        let mock = MockInnerTubeRepository()
        let artist = Artist(id: "a1", name: "Artist", thumbnailURL: nil, subscriberCount: nil, songs: [makeSong(id: "s1")], albums: [], singles: [])
        mock.artistResult = ArtistResult(artist: artist, songsContinuation: "page2")

        let vm = ArtistViewModel(getArtistUseCase: GetArtistUseCase(repository: mock))
        await loadArtistAndWait(vm, browseId: "a1")
        await loadMoreSongsAndWait(vm)

        XCTAssertFalse(vm.isLoadingMore)
    }
}
