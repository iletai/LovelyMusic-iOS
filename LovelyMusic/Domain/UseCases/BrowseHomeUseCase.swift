import Foundation

final class BrowseHomeUseCase {
    private let repository: InnerTubeRepositoryProtocol

    init(repository: InnerTubeRepositoryProtocol) {
        self.repository = repository
    }

    func execute(params: String? = nil) async throws -> HomeResult {
        try await repository.browseHome(params: params)
    }

    func loadMore(token: String) async throws -> HomeResult {
        try await repository.browseHomeContinuation(token: token)
    }
}
