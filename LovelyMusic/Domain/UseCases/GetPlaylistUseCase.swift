import Foundation

final class GetPlaylistUseCase {
    private let repository: InnerTubeRepositoryProtocol

    init(repository: InnerTubeRepositoryProtocol) {
        self.repository = repository
    }

    func execute(playlistId: String) async throws -> (playlist: Playlist, continuation: String?) {
        let result = try await repository.getPlaylist(playlistId: playlistId)
        return (playlist: result.playlist, continuation: result.songsContinuation)
    }

    func loadMoreSongs(continuation: String) async throws -> (songs: [Song], nextContinuation: String?) {
        let more = try await repository.browseShelfContinuation(token: continuation)
        return (songs: more.songs, nextContinuation: more.continuation)
    }
}
