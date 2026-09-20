import XCTest
@testable import LovelyMusic

final class GetAlbumUseCaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeSong(id: String, title: String = "Song") -> Song {
        Song(id: id, title: title, artistName: "Art", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
    }

    // MARK: - execute returns first page only

    func testExecuteReturnsFirstPageWithContinuationToken() async throws {
        let mock = MockInnerTubeRepository()
        let songs = [makeSong(id: "s1"), makeSong(id: "s2")]
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: "2024", thumbnailURL: nil, songs: songs)
        mock.albumResult = AlbumResult(album: album, songsContinuation: "page2-token")

        let useCase = GetAlbumUseCase(repository: mock)
        let result = try await useCase.execute(browseId: "a1")

        // Should return the first page songs only
        XCTAssertEqual(result.album.songs.count, 2)
        XCTAssertEqual(result.album.title, "Album")
        // Should pass through the continuation token
        XCTAssertEqual(result.continuation, "page2-token")
        // Should NOT have called browseContinuation
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 0, "execute should not eagerly load all pages")
    }

    func testExecuteReturnsNilContinuationWhenNoMorePages() async throws {
        let mock = MockInnerTubeRepository()
        let songs = [makeSong(id: "s1")]
        let album = Album(id: "a1", title: "Album", artistName: "Artist", artistId: nil, year: "2024", thumbnailURL: nil, songs: songs)
        mock.albumResult = AlbumResult(album: album, songsContinuation: nil)

        let useCase = GetAlbumUseCase(repository: mock)
        let result = try await useCase.execute(browseId: "a1")

        XCTAssertEqual(result.album.songs.count, 1)
        XCTAssertNil(result.continuation)
        XCTAssertEqual(mock.browseShelfContinuationCallCount, 0)
    }

    func testExecuteThrowsPropagatesError() async {
        let mock = MockInnerTubeRepository()
        mock.shouldThrow = true

        let useCase = GetAlbumUseCase(repository: mock)
        do {
            _ = try await useCase.execute(browseId: "a1")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - loadMoreSongs

    func testLoadMoreSongsCallsBrowseContinuation() async throws {
        let mock = MockInnerTubeRepository()

        let useCase = GetAlbumUseCase(repository: mock)
        // loadMoreSongs will call browseContinuation with the given token
        // The mock returns empty Data() which mapShelfContinuation will parse
        // This tests the structure, not the JSON mapping
        do {
            _ = try await useCase.loadMoreSongs(continuation: "page2-token")
        } catch {
            // mapShelfContinuation may throw on empty data — that's fine for structural test
        }

        XCTAssertEqual(mock.browseShelfContinuationCallCount, 1)
    }

    func testLoadMoreSongsThrowsPropagatesError() async {
        let mock = MockInnerTubeRepository()
        mock.shouldThrow = true

        let useCase = GetAlbumUseCase(repository: mock)
        do {
            _ = try await useCase.loadMoreSongs(continuation: "token")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertNotNil(error)
        }
    }
}
