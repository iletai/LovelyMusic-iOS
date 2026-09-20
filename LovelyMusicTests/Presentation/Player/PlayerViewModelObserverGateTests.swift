import XCTest

@testable import LovelyMusic

/// Verifies T3 of `doc/exec-plans/active/2026-05-04-video-load-race.md`:
/// repeated `currentTrack` reassignments for the SAME video `song.id` must
/// fire `loadVideoStream` exactly once; a genuine song-change boundary must
/// allow it to fire again.
@MainActor
final class PlayerViewModelObserverGateTests: XCTestCase {

    // MARK: - Fixtures

    private func videoSong(id: String) -> Song {
        var s = Song(
            id: id,
            title: id,
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
        s.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        return s
    }

    /// Drive `currentTrack` by reassigning via `restorePlaybackState`. This
    /// avoids triggering AVPlayer setup while still firing the `@Observable`
    /// change event the gate is meant to guard.
    private func setCurrentTrack(_ engine: AudioEngine, song: Song) {
        let state = PlaybackStatePersistence.PersistedPlaybackState(
            queue: [song],
            autoplayQueue: [],
            currentIndex: 0,
            currentTime: 0,
            wasPlaying: false,
            shuffleEnabled: false,
            repeatMode: AudioEngine.RepeatMode.off.rawValue,
            savedAt: Date()
        )
        engine.restorePlaybackState(state)
    }

    /// Yield repeatedly to let `Task { @MainActor }` observer callbacks drain
    /// and re-register their observation tracking.
    private func drainObservers() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<10 { await Task.yield() }
    }

    private func makeViewModel(engine: AudioEngine) -> (PlayerViewModel, ResolverCounter) {
        let counter = ResolverCounter()
        engine.videoStreamURLResolver = { _ in
            counter.increment()
            // Returning nil makes VideoPlaybackManager log "no stream" and
            // exit cleanly, which is fine for this test — we only care about
            // how many times the resolver was invoked.
            return nil
        }
        let playlistRepo = MockPlaylistRepository()
        let favRepo = MockFavoritesRepository()
        let lyricsRepo = StubLyricsRepository()
        let innerTubeRepo = MockInnerTubeRepository()

        let vm = PlayerViewModel(
            audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: StubPlayerRepo()),
            getLyricsUseCase: GetLyricsUseCase(repository: lyricsRepo),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: playlistRepo),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: favRepo),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: innerTubeRepo)
        )
        return (vm, counter)
    }

    // MARK: - Test

    func testRepeatedSameSongReassignmentsFireLoadVideoStreamOnce() async throws {
        let engine = AudioEngine()
        let (_, counter) = makeViewModel(engine: engine)
        let videoA = videoSong(id: "AAAAAAAAAAA")

        // Three reassignments of the SAME video song.
        setCurrentTrack(engine, song: videoA)
        await drainObservers()
        setCurrentTrack(engine, song: videoA)
        await drainObservers()
        setCurrentTrack(engine, song: videoA)
        await drainObservers()

        XCTAssertEqual(
            counter.value, 1,
            "Three currentTrack reassignments to the same video id must fire loadVideoStream once"
        )

        // Switching to a different video id must release the gate.
        let videoB = videoSong(id: "BBBBBBBBBBB")
        setCurrentTrack(engine, song: videoB)
        await drainObservers()

        XCTAssertEqual(
            counter.value, 2,
            "A genuine song-change boundary must allow loadVideoStream to fire again"
        )
    }

    /// CX5 lifecycle regression: toggling video mode off then back on for
    /// the same `song.id` must trigger a fresh `loadVideoStream` call.
    /// Without an explicit code path resetting the gate, `lastHandledVideoTrackId`
    /// could keep the stale value and suppress the reload.
    func testToggleVideoModeOffThenOnReloadsSameSong() async throws {
        let engine = AudioEngine()
        let (vm, counter) = makeViewModel(engine: engine)
        let videoA = videoSong(id: "AAAAAAAAAAA")

        // Initial assignment should load once.
        setCurrentTrack(engine, song: videoA)
        await drainObservers()
        XCTAssertEqual(counter.value, 1, "Initial currentTrack assignment should load video once")

        // Toggle video mode off, then back on.
        vm.toggleVideoMode()  // off (was true)
        await drainObservers()
        vm.toggleVideoMode()  // on
        await drainObservers()

        XCTAssertGreaterThanOrEqual(
            counter.value, 2,
            "Toggling video mode off then on must trigger a fresh loadVideoStream call"
        )
    }
}

// MARK: - Helpers

private final class ResolverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}

private final class StubLyricsRepository: LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        return nil
    }
}

private final class StubPlayerRepo: PlayerRepositoryProtocol, @unchecked Sendable {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw URLError(.notConnectedToInternet)
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (
        url: String, contentLength: Int64?
    )? {
        nil
    }
}
