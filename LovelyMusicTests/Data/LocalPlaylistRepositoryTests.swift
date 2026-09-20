import XCTest
@testable import LovelyMusic

final class LocalPlaylistRepositoryTests: XCTestCase {
    private var repo: LocalPlaylistRepository!
    private let playlistsKey = "local_playlists"
    private let historyKey = "recently_played"

    override func setUp() {
        super.setUp()
        repo = LocalPlaylistRepository()
        UserDefaults.standard.removeObject(forKey: playlistsKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: playlistsKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
        super.tearDown()
    }

    func testCreatePlaylist() async throws {
        let playlist = try await repo.createPlaylist(title: "My Playlist")
        XCTAssertEqual(playlist.title, "My Playlist")
        XCTAssertFalse(playlist.id.isEmpty)

        let all = try await repo.getAllPlaylists()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "My Playlist")
    }

    func testCreateMultiplePlaylists() async throws {
        _ = try await repo.createPlaylist(title: "Playlist 1")
        _ = try await repo.createPlaylist(title: "Playlist 2")

        let all = try await repo.getAllPlaylists()
        XCTAssertEqual(all.count, 2)
    }

    func testDeletePlaylist() async throws {
        let playlist = try await repo.createPlaylist(title: "To Delete")
        try await repo.deletePlaylist(id: playlist.id)

        let all = try await repo.getAllPlaylists()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteNonexistentPlaylist() async throws {
        _ = try await repo.createPlaylist(title: "Keep")
        try await repo.deletePlaylist(id: "nonexistent-id")

        let all = try await repo.getAllPlaylists()
        XCTAssertEqual(all.count, 1)
    }

    func testAddSongToPlaylist() async throws {
        let playlist = try await repo.createPlaylist(title: "With Songs")
        let song = Song(id: "s1", title: "Test Song", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil)

        try await repo.addSongToPlaylist(song: song, playlistId: playlist.id)

        let all = try await repo.getAllPlaylists()
        XCTAssertEqual(all.first?.songs.count, 1)
        XCTAssertEqual(all.first?.songs.first?.title, "Test Song")
    }

    func testAddDuplicateSong() async throws {
        let playlist = try await repo.createPlaylist(title: "Dupes")
        let song = Song(id: "s1", title: "Test", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)

        try await repo.addSongToPlaylist(song: song, playlistId: playlist.id)
        try await repo.addSongToPlaylist(song: song, playlistId: playlist.id)

        let all = try await repo.getAllPlaylists()
        XCTAssertEqual(all.first?.songs.count, 1)
    }

    func testRemoveSongFromPlaylist() async throws {
        let playlist = try await repo.createPlaylist(title: "Remove Test")
        let song = Song(id: "s1", title: "Test", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)

        try await repo.addSongToPlaylist(song: song, playlistId: playlist.id)
        try await repo.removeSongFromPlaylist(songId: "s1", playlistId: playlist.id)

        let all = try await repo.getAllPlaylists()
        XCTAssertTrue(all.first?.songs.isEmpty ?? false)
    }

    func testRecentlyPlayed() async throws {
        let song = Song(id: "s1", title: "Recent", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)

        try await repo.addToHistory(song: song)
        let recent = try await repo.getRecentlyPlayed()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, "s1")
    }

    func testRecentlyPlayedOrdering() async throws {
        let s1 = Song(id: "s1", title: "First", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        let s2 = Song(id: "s2", title: "Second", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)

        try await repo.addToHistory(song: s1)
        try await repo.addToHistory(song: s2)

        let recent = try await repo.getRecentlyPlayed()
        XCTAssertEqual(recent.first?.id, "s2")
        XCTAssertEqual(recent.last?.id, "s1")
    }

    func testRecentlyPlayedDeduplication() async throws {
        let song = Song(id: "s1", title: "Song", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)

        try await repo.addToHistory(song: song)
        try await repo.addToHistory(song: song)

        let recent = try await repo.getRecentlyPlayed()
        XCTAssertEqual(recent.count, 1)
    }

    func testEmptyRecentlyPlayed() async throws {
        let recent = try await repo.getRecentlyPlayed()
        XCTAssertTrue(recent.isEmpty)
    }

    func testEmptyPlaylists() async throws {
        let all = try await repo.getAllPlaylists()
        XCTAssertTrue(all.isEmpty)
    }
}
