import Foundation

final class GetAlbumUseCase {
    private let repository: InnerTubeRepositoryProtocol

    init(repository: InnerTubeRepositoryProtocol) {
        self.repository = repository
    }

    /// Fetches the album and returns the first page immediately with an optional continuation token.
    func execute(browseId: String) async throws -> (album: Album, continuation: String?) {
        let result = try await repository.getAlbum(browseId: browseId)
        return (album: result.album, continuation: result.songsContinuation)
    }

    /// Loads the next page of songs using a continuation token.
    func loadMoreSongs(continuation: String) async throws -> (songs: [Song], nextContinuation: String?) {
        let more = try await repository.browseShelfContinuation(token: continuation)
        return (songs: more.songs, nextContinuation: more.continuation)
    }
}
