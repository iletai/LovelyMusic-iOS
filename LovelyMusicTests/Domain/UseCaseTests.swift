import XCTest
@testable import LovelyMusic

final class SearchMusicUseCaseTests: XCTestCase {
    func testSearchReturnsResults() async throws {
        let mock = MockInnerTubeRepository()
        let song = Song(id: "v1", title: "Song", artistName: "Art", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        mock.searchResult = SearchResult(songs: [song], albums: [], artists: [], playlists: [], continuation: nil)

        let useCase = SearchMusicUseCase(repository: mock)
        let result = try await useCase.execute(query: "test")
        XCTAssertEqual(result.songs.count, 1)
        XCTAssertEqual(result.songs.first?.title, "Song")
    }

    func testSearchWithFilter() async throws {
        let mock = MockInnerTubeRepository()
        let useCase = SearchMusicUseCase(repository: mock)
        let result = try await useCase.execute(query: "test", filter: .songs)
        XCTAssertTrue(result.songs.isEmpty)
    }

    func testSearchSuggestions() async throws {
        let mock = MockInnerTubeRepository()
        mock.suggestions = ["hello", "hello world"]

        let useCase = SearchMusicUseCase(repository: mock)
        let suggestions = try await useCase.suggestions(query: "hel")
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first, "hello")
    }

    func testSearchThrows() async {
        let mock = MockInnerTubeRepository()
        mock.shouldThrow = true

        let useCase = SearchMusicUseCase(repository: mock)
        do {
            _ = try await useCase.execute(query: "test")
            XCTFail("Expected error")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testSuggestionsThrows() async {
        let mock = MockInnerTubeRepository()
        mock.shouldThrow = true

        let useCase = SearchMusicUseCase(repository: mock)
        do {
            _ = try await useCase.suggestions(query: "test")
            XCTFail("Expected error")
        } catch {
            XCTAssertNotNil(error)
        }
    }
}

final class BrowseHomeUseCaseTests: XCTestCase {
    func testBrowseHomeReturnsResults() async throws {
        let mock = MockInnerTubeRepository()
        mock.homeResult = HomeResult(sections: [MusicSection(title: "Quick picks", items: [])], continuation: nil)

        let useCase = BrowseHomeUseCase(repository: mock)
        let result = try await useCase.execute()
        XCTAssertEqual(result.sections.count, 1)
        XCTAssertEqual(result.sections.first?.title, "Quick picks")
    }

    func testBrowseHomeEmpty() async throws {
        let mock = MockInnerTubeRepository()
        let useCase = BrowseHomeUseCase(repository: mock)
        let result = try await useCase.execute()
        XCTAssertTrue(result.sections.isEmpty)
    }

    func testBrowseHomeThrows() async {
        let mock = MockInnerTubeRepository()
        mock.shouldThrow = true

        let useCase = BrowseHomeUseCase(repository: mock)
        do {
            _ = try await useCase.execute()
            XCTFail("Expected error")
        } catch {
            XCTAssertNotNil(error)
        }
    }
}

final class ManagePlaylistUseCaseTests: XCTestCase {
    func testCreatePlaylist() async throws {
        let mock = MockPlaylistRepository()
        let useCase = ManagePlaylistUseCase(repository: mock)

        let playlist = try await useCase.createPlaylist(title: "Test")
        XCTAssertEqual(playlist.title, "Test")

        let all = try await useCase.getAllPlaylists()
        XCTAssertEqual(all.count, 1)
    }

    func testDeletePlaylist() async throws {
        let mock = MockPlaylistRepository()
        let useCase = ManagePlaylistUseCase(repository: mock)

        let playlist = try await useCase.createPlaylist(title: "ToDelete")
        try await useCase.deletePlaylist(id: playlist.id)

        let all = try await useCase.getAllPlaylists()
        XCTAssertTrue(all.isEmpty)
    }

    func testAddAndRemoveSong() async throws {
        let mock = MockPlaylistRepository()
        let useCase = ManagePlaylistUseCase(repository: mock)

        let playlist = try await useCase.createPlaylist(title: "Songs")
        let song = Song(id: "s1", title: "Song", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)

        try await useCase.addSong(song, to: playlist.id)
        var all = try await useCase.getAllPlaylists()
        XCTAssertEqual(all.first?.songs.count, 1)

        try await useCase.removeSong(songId: "s1", from: playlist.id)
        all = try await useCase.getAllPlaylists()
        XCTAssertTrue(all.first?.songs.isEmpty ?? false)
    }

    func testRecentlyPlayed() async throws {
        let mock = MockPlaylistRepository()
        let useCase = ManagePlaylistUseCase(repository: mock)

        let song = Song(id: "s1", title: "Recent", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        try await useCase.addToHistory(song)

        let recent = try await useCase.getRecentlyPlayed()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, "s1")
    }
}
