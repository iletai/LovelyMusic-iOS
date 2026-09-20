import Foundation

protocol PlaylistRepositoryProtocol {
    func getAllPlaylists() async throws -> [Playlist]
    func createPlaylist(title: String) async throws -> Playlist
    func deletePlaylist(id: String) async throws
    func renamePlaylist(id: String, name: String) async throws
    func addSongToPlaylist(song: Song, playlistId: String) async throws
    func removeSongFromPlaylist(songId: String, playlistId: String) async throws
    func getRecentlyPlayed() async throws -> [Song]
    func addToHistory(song: Song) async throws
}
