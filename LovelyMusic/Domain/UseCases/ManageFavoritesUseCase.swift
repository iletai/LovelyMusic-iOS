import Foundation

final class ManageFavoritesUseCase {
    private let repository: FavoritesRepositoryProtocol

    init(repository: FavoritesRepositoryProtocol) {
        self.repository = repository
    }

    func isFavorite(songId: String) -> Bool {
        repository.isFavorite(songId: songId)
    }

    func toggleFavorite(song: Song) async throws {
        try await repository.toggleFavorite(song: song)
    }

    func getAllFavorites() async throws -> [Song] {
        try await repository.getAllFavorites()
    }

    func getFavoritesCount() -> Int {
        repository.getFavoritesCount()
    }
}
