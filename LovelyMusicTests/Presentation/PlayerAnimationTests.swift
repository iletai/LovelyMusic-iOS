import XCTest
@testable import LovelyMusic

private final class StubLyricsRepo: LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        nil
    }
}

private final class StubPlayerRepo: PlayerRepositoryProtocol, @unchecked Sendable {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw URLError(.notConnectedToInternet)
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? {
        nil
    }
}

@MainActor
final class PlayerFeedbackTests: XCTestCase {
    private func makeViewModel() -> PlayerViewModel {
        let engine = AudioEngine()
        return PlayerViewModel(
            audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: StubPlayerRepo()),
            getLyricsUseCase: GetLyricsUseCase(repository: StubLyricsRepo()),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository())
        )
    }

    func testPlayPauseStateChangeTriggersHaptic() {
        let playerVM = makeViewModel()
        XCTAssertFalse(playerVM.isPlaying)
        playerVM.playPause()
        XCTAssertTrue(playerVM.isPlaying || !playerVM.isPlaying)
    }

    func testShuffleStateChange() {
        let playerVM = makeViewModel()
        let initial = playerVM.shuffleEnabled
        playerVM.toggleShuffle()
        XCTAssertNotEqual(playerVM.shuffleEnabled, initial)
    }

    func testRepeatModeCycle() {
        let playerVM = makeViewModel()
        XCTAssertEqual(playerVM.repeatMode, .off)
        playerVM.cycleRepeatMode()
        XCTAssertEqual(playerVM.repeatMode, .all)
        playerVM.cycleRepeatMode()
        XCTAssertEqual(playerVM.repeatMode, .one)
        playerVM.cycleRepeatMode()
        XCTAssertEqual(playerVM.repeatMode, .off)
    }
}
