import Foundation
@testable import LovelyMusic

final class MockFavoritesRepository: FavoritesRepositoryProtocol {
    var favorites: [Song] = []
    var shouldThrow = false

    func isFavorite(songId: String) -> Bool {
        favorites.contains { $0.id == songId }
    }

    func toggleFavorite(song: Song) async throws {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if let idx = favorites.firstIndex(where: { $0.id == song.id }) {
            favorites.remove(at: idx)
        } else {
            favorites.append(song)
        }
    }

    func getAllFavorites() async throws -> [Song] {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return favorites
    }

    func getFavoritesCount() -> Int {
        favorites.count
    }
}
