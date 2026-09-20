import Foundation

final class GetArtistUseCase {
    private let repository: InnerTubeRepositoryProtocol

    init(repository: InnerTubeRepositoryProtocol) {
        self.repository = repository
    }

    func execute(browseId: String) async throws -> ArtistResult {
        try await repository.getArtist(browseId: browseId)
    }

    func loadMoreSongs(continuation: String) async throws -> (songs: [Song], continuation: String?) {
        try await repository.browseShelfContinuation(token: continuation)
    }
}
