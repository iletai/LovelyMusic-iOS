import Foundation
import os

extension Notification.Name {
    static let favoritesChanged = Notification.Name("favoritesChanged")
}

final class LocalFavoritesRepository: FavoritesRepositoryProtocol {
    private let defaults = UserDefaults.standard
    private let favoritesKey = "favorite_songs"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    func isFavorite(songId: String) -> Bool {
        loadFavorites().contains { $0.id == songId }
    }

    func toggleFavorite(song: Song) async throws {
        var favorites = loadFavorites()
        if let index = favorites.firstIndex(where: { $0.id == song.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(song, at: 0)
        }
        saveFavorites(favorites)
    }

    func getAllFavorites() async throws -> [Song] {
        loadFavorites()
    }

    func getFavoritesCount() -> Int {
        loadFavorites().count
    }

    // MARK: - Private

    private func loadFavorites() -> [Song] {
        guard let data = defaults.data(forKey: favoritesKey) else { return [] }
        do {
            return try Self.decoder.decode([Song].self, from: data)
        } catch {
            Log.favorites.error("Failed to decode favorites: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func saveFavorites(_ songs: [Song]) {
        do {
            let data = try Self.encoder.encode(songs)
            defaults.set(data, forKey: favoritesKey)
            Task { @MainActor in
                NotificationCenter.default.post(name: .favoritesChanged, object: nil)
            }
        } catch {
            Log.favorites.error("Failed to encode favorites: \(error.localizedDescription, privacy: .public)")
        }
    }
}
