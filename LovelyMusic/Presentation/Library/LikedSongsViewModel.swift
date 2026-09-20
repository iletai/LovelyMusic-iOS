import Foundation

@MainActor @Observable
final class LikedSongsViewModel {
    private let manageFavoritesUseCase: ManageFavoritesUseCase

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    private(set) var favorites: [Song] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(manageFavoritesUseCase: ManageFavoritesUseCase) {
        self.manageFavoritesUseCase = manageFavoritesUseCase
    }

    deinit {
        loadTask?.cancel()
    }

    func loadFavorites() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoading = true
            error = nil
            do {
                let result = try await manageFavoritesUseCase.getAllFavorites()
                guard !Task.isCancelled else { return }
                self.favorites = ContentPreferences.filteredSongs(result)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    // M-12: Optimistic toggle — update local state immediately, persist in background
    func toggleFavorite(song: Song) {
        // Optimistic: remove from local state immediately
        if let index = favorites.firstIndex(where: { $0.id == song.id }) {
            favorites.remove(at: index)
        }
        // Persist in background
        Task {
            try? await manageFavoritesUseCase.toggleFavorite(song: song)
        }
    }
}
