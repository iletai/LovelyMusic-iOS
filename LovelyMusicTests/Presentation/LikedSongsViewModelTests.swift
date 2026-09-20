import XCTest
@testable import LovelyMusic

@MainActor
final class LikedSongsViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeSong(id: String) -> Song {
        Song(id: id, title: "Song \(id)", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
    }

    private func makeSUT() -> (LikedSongsViewModel, MockFavoritesRepository) {
        let mock = MockFavoritesRepository()
        let useCase = ManageFavoritesUseCase(repository: mock)
        let vm = LikedSongsViewModel(manageFavoritesUseCase: useCase)
        return (vm, mock)
    }

    // MARK: - M-12: Optimistic toggle

    func testToggleFavoriteRemovesSongOptimistically() async {
        let (vm, mock) = makeSUT()

        let songs = [makeSong(id: "s1"), makeSong(id: "s2"), makeSong(id: "s3")]
        mock.favorites = songs
        vm.loadFavorites()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.favorites.count, 3)

        // Toggle s2 - should be removed from local state immediately
        vm.toggleFavorite(song: songs[1])

        // Local state should be updated immediately (optimistic)
        XCTAssertEqual(vm.favorites.count, 2, "Song should be removed optimistically")
        XCTAssertFalse(vm.favorites.contains(where: { $0.id == "s2" }),
            "Toggled song should not be in favorites")
    }

    func testToggleFavoriteKeepsOtherSongsIntact() async {
        let (vm, mock) = makeSUT()

        let songs = [makeSong(id: "s1"), makeSong(id: "s2"), makeSong(id: "s3")]
        mock.favorites = songs
        vm.loadFavorites()
        try? await Task.sleep(for: .milliseconds(100))

        vm.toggleFavorite(song: songs[0])

        XCTAssertTrue(vm.favorites.contains(where: { $0.id == "s2" }))
        XCTAssertTrue(vm.favorites.contains(where: { $0.id == "s3" }))
    }

    func testToggleFavoriteNonExistentSongDoesNotCrash() async {
        let (vm, mock) = makeSUT()

        let songs = [makeSong(id: "s1")]
        mock.favorites = songs
        vm.loadFavorites()
        try? await Task.sleep(for: .milliseconds(100))

        // Toggle a song not in the list - should not crash
        let unknownSong = makeSong(id: "unknown")
        vm.toggleFavorite(song: unknownSong)

        XCTAssertEqual(vm.favorites.count, 1, "Favorites should remain unchanged for unknown song")
    }

    func testToggleFavoritePersistsInBackground() async {
        let (vm, mock) = makeSUT()

        let songs = [makeSong(id: "s1"), makeSong(id: "s2")]
        mock.favorites = songs
        vm.loadFavorites()
        try? await Task.sleep(for: .milliseconds(100))

        vm.toggleFavorite(song: songs[0])

        // Give background task time to complete
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(mock.favorites.contains(where: { $0.id == "s1" }),
            "Repository should have persisted the toggle")
    }
}
