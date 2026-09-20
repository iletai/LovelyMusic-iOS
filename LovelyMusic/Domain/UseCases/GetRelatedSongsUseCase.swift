import Foundation

final class GetRelatedSongsUseCase {
    private let repository: InnerTubeRepositoryProtocol

    init(repository: InnerTubeRepositoryProtocol) {
        self.repository = repository
    }

    func execute(videoId: String) async throws -> [Song] {
        try await repository.getNext(videoId: videoId, playlistId: nil)
    }
}
