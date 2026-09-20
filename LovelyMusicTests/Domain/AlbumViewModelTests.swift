import XCTest
@testable import LovelyMusic

@MainActor
final class AlbumViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeSong(id: String, title: String = "Song") -> Song {
        Song(id: id, title: title, artistName: "Art", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
    }

    /// Starts loadAlbum (which dispatches a Task internally) and waits until isLoading becomes false.
    private func loadAlbumAndWait(_ vm: AlbumViewModel, browseId: String) async {
        vm.loadAlbum(browseId: browseId)
        // Give the internal Task time to start and finish
        while vm.isLoading || vm.album == nil && vm.error == nil {
            await Task.yield()
        }
        // Small extra yield to ensure state settles
        await Task.yield()
    }

    /// Starts loadMoreSongs (which dispatches a Task internally) and waits until isLoadingMore becomes false.
    private func loadMoreSongsAndWait(_ vm: AlbumViewModel) async {
        vm.loadMoreSongs()
        // Give the internal Task time to start
        await Task.yield()
        while vm.isLoadingMore {
            await Task.yield()
        }
        await Task.yield()
    }

    // MARK: - loadAlbum returns first page immediately

    func testLoadAlbumDoesNotExhaustContinuations() async {
        let mock = MockInnerTubeRepository()
        let songs = [makeSong(id: "s1"), makeSong(id: "s2")]
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: "2024", thumbnailURL: nil, songs: songs)
        mock.albumResult = AlbumResult(album: album, songsContinuation: "page2-token")

        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))
        await loadAlbumAndWait(vm, browseId: "a1")

        // Should show first page songs only
        XCTAssertEqual(vm.album?.songs.count, 2)
        // Should have a continuation token stored
        XCTAssertTrue(vm.hasMoreSongs)
        // browseContinuation should NOT have been called
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 0)
    }

    // MARK: - hasMoreSongs

    func testHasMoreSongsWhenContinuationExists() async {
        let mock = MockInnerTubeRepository()
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [makeSong(id: "s1")])
        mock.albumResult = AlbumResult(album: album, songsContinuation: "token")

        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))
        await loadAlbumAndWait(vm, browseId: "a1")

        XCTAssertTrue(vm.hasMoreSongs)
    }

    func testHasNoMoreSongsWhenNoContinuation() async {
        let mock = MockInnerTubeRepository()
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [makeSong(id: "s1")])
        mock.albumResult = AlbumResult(album: album, songsContinuation: nil)

        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))
        await loadAlbumAndWait(vm, browseId: "a1")

        XCTAssertFalse(vm.hasMoreSongs)
    }

    // MARK: - loadMoreSongs

    func testLoadMoreSongsCallsBrowseContinuation() async {
        let mock = MockInnerTubeRepository()
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [makeSong(id: "s1")])
        mock.albumResult = AlbumResult(album: album, songsContinuation: "page2")

        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))
        await loadAlbumAndWait(vm, browseId: "a1")

        await loadMoreSongsAndWait(vm)

        // Should have tried to fetch continuation
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 1)
    }

    func testLoadMoreSongsGuardsWhenNoContinuation() async {
        let mock = MockInnerTubeRepository()
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [makeSong(id: "s1")])
        mock.albumResult = AlbumResult(album: album, songsContinuation: nil)

        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))
        await loadAlbumAndWait(vm, browseId: "a1")

        vm.loadMoreSongs()

        XCTAssertEqual(mock.browseShelfContinuationCallCount, 0)
    }

    func testLoadMoreSongsHandlesError() async {
        let mock = MockInnerTubeRepository()
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [makeSong(id: "s1")])
        mock.albumResult = AlbumResult(album: album, songsContinuation: "page2")

        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))
        await loadAlbumAndWait(vm, browseId: "a1")

        mock.shouldThrow = true
        await loadMoreSongsAndWait(vm)

        XCTAssertFalse(vm.isLoadingMore, "isLoadingMore should reset after error")
    }

    // MARK: - isLoadingMore

    func testIsLoadingMoreResetsAfterCompletion() async {
        let mock = MockInnerTubeRepository()
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [makeSong(id: "s1")])
        mock.albumResult = AlbumResult(album: album, songsContinuation: "page2")

        let vm = AlbumViewModel(getAlbumUseCase: GetAlbumUseCase(repository: mock))
        await loadAlbumAndWait(vm, browseId: "a1")
        await loadMoreSongsAndWait(vm)

        XCTAssertFalse(vm.isLoadingMore)
    }
}
