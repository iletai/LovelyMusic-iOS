import Foundation

protocol FavoritesRepositoryProtocol {
    func isFavorite(songId: String) -> Bool
    func toggleFavorite(song: Song) async throws
    func getAllFavorites() async throws -> [Song]
    func getFavoritesCount() -> Int
}
