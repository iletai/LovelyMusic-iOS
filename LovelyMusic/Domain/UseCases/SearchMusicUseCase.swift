import Foundation

final class SearchMusicUseCase {
    private let repository: InnerTubeRepositoryProtocol

    init(repository: InnerTubeRepositoryProtocol) {
        self.repository = repository
    }

    func execute(query: String, filter: SearchFilter? = nil) async throws -> SearchResult {
        try await repository.search(query: query, filter: filter)
    }

    func continueSearch(token: String) async throws -> SearchResult {
        try await repository.searchContinuation(token: token)
    }

    func suggestions(query: String) async throws -> [String] {
        try await repository.searchSuggestions(query: query)
    }
}
