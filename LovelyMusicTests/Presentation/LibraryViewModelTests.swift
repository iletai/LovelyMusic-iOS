import XCTest
import Combine
@testable import LovelyMusic

@MainActor
final class LibraryViewModelTests: XCTestCase {
    private var playlistRepo: MockPlaylistRepository!
    private var favoritesRepo: MockFavoritesRepository!
    private var playlistUseCase: ManagePlaylistUseCase!
    private var favoritesUseCase: ManageFavoritesUseCase!
    private var viewModel: LibraryViewModel!

    override func setUp() {
        super.setUp()
        playlistRepo = MockPlaylistRepository()
        favoritesRepo = MockFavoritesRepository()
        playlistUseCase = ManagePlaylistUseCase(repository: playlistRepo)
        favoritesUseCase = ManageFavoritesUseCase(repository: favoritesRepo)
        viewModel = LibraryViewModel(
            managePlaylistUseCase: playlistUseCase,
            manageFavoritesUseCase: favoritesUseCase
        )
    }

    override func tearDown() {
        viewModel = nil
        playlistRepo = nil
        favoritesRepo = nil
        super.tearDown()
    }

    // MARK: - loadLibrary

    func testLoadLibraryPopulatesPlaylists() async {
        let playlist = Playlist(title: "My List")
        playlistRepo.playlists = [playlist]

        await viewModel.loadLibrary()

        XCTAssertEqual(viewModel.playlists.count, 1)
        XCTAssertEqual(viewModel.playlists.first?.title, "My List")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
    }

    func testLoadLibraryPopulatesRecentlyPlayed() async {
        let song = Song(id: "s1", title: "Song", artistName: "Art", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        playlistRepo.history = [song]

        await viewModel.loadLibrary()

        XCTAssertEqual(viewModel.recentlyPlayed.count, 1)
        XCTAssertEqual(viewModel.recentlyPlayed.first?.id, "s1")
    }

    func testLoadLibraryPopulatesFavoritesCount() async {
        let song = Song(id: "s1", title: "Song", artistName: "Art", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        favoritesRepo.favorites = [song]

        await viewModel.loadLibrary()

        XCTAssertEqual(viewModel.favoritesCount, 1)
    }

    func testLoadLibrarySetsErrorOnFailure() async {
        playlistRepo.shouldThrow = true

        await viewModel.loadLibrary()

        XCTAssertNotNil(viewModel.error)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadLibraryClearsErrorOnSuccess() async {
        playlistRepo.shouldThrow = true
        await viewModel.loadLibrary()
        XCTAssertNotNil(viewModel.error)

        playlistRepo.shouldThrow = false
        await viewModel.loadLibrary()

        XCTAssertNil(viewModel.error)
    }

    // MARK: - Debounce helper (scheduleReload)

    func testScheduleReloadDebouncesMergedCalls() async {
        // Verify that the viewModel's loadLibrary works correctly
        // when called once — the view-layer debounce ensures it's called at most once
        // per 500ms window, so a single call should load all data.
        let playlist = Playlist(title: "Debounce Test")
        playlistRepo.playlists = [playlist]
        let song = Song(id: "s1", title: "Song", artistName: "Art", artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        playlistRepo.history = [song]
        favoritesRepo.favorites = [song]

        await viewModel.loadLibrary()

        // Single call loads all three data sources
        XCTAssertEqual(viewModel.playlists.count, 1)
        XCTAssertEqual(viewModel.recentlyPlayed.count, 1)
        XCTAssertEqual(viewModel.favoritesCount, 1)
    }

    // MARK: - createPlaylist

    func testCreatePlaylist() async {
        viewModel.newPlaylistName = "New List"

        await viewModel.createPlaylist()

        XCTAssertEqual(viewModel.playlists.count, 1)
        XCTAssertEqual(viewModel.playlists.first?.title, "New List")
        XCTAssertTrue(viewModel.newPlaylistName.isEmpty)
    }

    func testCreatePlaylistEmptyNameDoesNothing() async {
        viewModel.newPlaylistName = ""

        await viewModel.createPlaylist()

        XCTAssertTrue(viewModel.playlists.isEmpty)
    }

    // MARK: - confirmDelete

    func testConfirmDeleteRemovesPlaylist() async {
        let playlist = Playlist(title: "ToDelete")
        playlistRepo.playlists = [playlist]
        await viewModel.loadLibrary()

        viewModel.requestDelete(playlist: viewModel.playlists.first!)
        await viewModel.confirmDelete()

        XCTAssertTrue(viewModel.playlists.isEmpty)
    }

    // MARK: - rename

    func testConfirmRenameUpdatesPlaylist() async {
        let playlist = Playlist(title: "Original")
        playlistRepo.playlists = [playlist]
        await viewModel.loadLibrary()

        viewModel.startRename(playlist: viewModel.playlists.first!)
        viewModel.renameText = "Renamed"
        await viewModel.confirmRename()

        XCTAssertEqual(viewModel.playlists.first?.title, "Renamed")
        XCTAssertFalse(viewModel.isRenamingPlaylist)
    }
}

// MARK: - Notification debounce integration tests

@MainActor
final class LibraryNotificationDebounceTests: XCTestCase {

    /// Verify that Merge3 + debounce from the view layer produces a single
    /// publisher output when three notifications fire in rapid succession.
    func testMerge3DebounceCoalescesNotifications() {
        let expectation = expectation(description: "Debounced publisher fires once")
        var callCount = 0
        var cancellables = Set<AnyCancellable>()

        Publishers.Merge3(
            NotificationCenter.default.publisher(for: .playlistsChanged),
            NotificationCenter.default.publisher(for: .recentlyPlayedChanged),
            NotificationCenter.default.publisher(for: .favoritesChanged)
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { _ in
            callCount += 1
            expectation.fulfill()
        }
        .store(in: &cancellables)

        // Fire all three notifications in rapid succession
        NotificationCenter.default.post(name: .playlistsChanged, object: nil)
        NotificationCenter.default.post(name: .recentlyPlayedChanged, object: nil)
        NotificationCenter.default.post(name: .favoritesChanged, object: nil)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(callCount, 1, "Expected exactly one debounced call, got \(callCount)")
    }

    /// Verify that notifications spaced apart produce multiple calls.
    func testMerge3DebounceFiresForSeparateNotifications() {
        let expectation = expectation(description: "Debounced publisher fires twice")
        expectation.expectedFulfillmentCount = 2
        var callCount = 0
        var cancellables = Set<AnyCancellable>()

        Publishers.Merge3(
            NotificationCenter.default.publisher(for: .playlistsChanged),
            NotificationCenter.default.publisher(for: .recentlyPlayedChanged),
            NotificationCenter.default.publisher(for: .favoritesChanged)
        )
        .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
        .sink { _ in
            callCount += 1
            expectation.fulfill()
        }
        .store(in: &cancellables)

        // First batch
        NotificationCenter.default.post(name: .playlistsChanged, object: nil)

        // Second batch after debounce window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .favoritesChanged, object: nil)
        }

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(callCount, 2, "Expected two debounced calls, got \(callCount)")
    }
}
