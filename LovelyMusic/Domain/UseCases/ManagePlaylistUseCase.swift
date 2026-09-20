import Foundation

final class ManagePlaylistUseCase {
    private let repository: PlaylistRepositoryProtocol

    init(repository: PlaylistRepositoryProtocol) {
        self.repository = repository
    }

    func getAllPlaylists() async throws -> [Playlist] {
        try await repository.getAllPlaylists()
    }

    func createPlaylist(title: String) async throws -> Playlist {
        try await repository.createPlaylist(title: title)
    }

    func deletePlaylist(id: String) async throws {
        try await repository.deletePlaylist(id: id)
    }

    func renamePlaylist(id: String, name: String) async throws {
        try await repository.renamePlaylist(id: id, name: name)
    }

    func addSong(_ song: Song, to playlistId: String) async throws {
        try await repository.addSongToPlaylist(song: song, playlistId: playlistId)
    }

    func removeSong(songId: String, from playlistId: String) async throws {
        try await repository.removeSongFromPlaylist(songId: songId, playlistId: playlistId)
    }

    func getRecentlyPlayed() async throws -> [Song] {
        try await repository.getRecentlyPlayed()
    }

    func addToHistory(_ song: Song) async throws {
        try await repository.addToHistory(song: song)
    }
}
