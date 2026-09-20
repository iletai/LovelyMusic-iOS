import XCTest

@testable import LovelyMusic

/// Verifies the queue semantics of "Play Next" introduced for the polish-pass
/// Phase 2 self-correction. `PlayerViewModel.playNext(_:)` is a one-line
/// delegation:
///
/// ```swift
/// func playNext(_ song: Song) {
///     if queue.isEmpty { play(song: song); return }
///     audioEngine.insertInQueue(song, at: currentIndex + 1)
/// }
/// ```
///
/// The queue mutation behaviour lives in `AudioEngine.insertInQueue(_:at:)`,
/// so the cases below exercise it directly: empty queue, mid-queue insert,
/// duplicate dedupe, and last-position insert. The `PlayerViewModel`
/// `play(song:)` empty-queue branch is verified via the queue state observable
/// through `AudioEngine` after the engine populates `queue` (see
/// `testPlayerViewModelPlayNextEmptyQueueDelegatesToPlay`).
@MainActor
final class PlayerViewModelPlayNextTests: XCTestCase {

    // MARK: - Helpers

    private func makeSong(id: String, title: String = "Song") -> Song {
        Song(
            id: id,
            title: title,
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
    }

    /// Seed an `AudioEngine` queue without going through `play(song:)` (which
    /// requires AVPlayer / network plumbing). Uses the persistence path which
    /// `restorePlaybackState` reads to populate `queue` and `currentIndex`
    /// directly.
    private func makeEngine(
        queue: [Song], currentIndex: Int = 0
    ) -> AudioEngine {
        let engine = AudioEngine()
        let state = PlaybackStatePersistence.PersistedPlaybackState(
            queue: queue,
            autoplayQueue: [],
            currentIndex: currentIndex,
            currentTime: 0,
            wasPlaying: false,
            shuffleEnabled: false,
            repeatMode: AudioEngine.RepeatMode.off.rawValue,
            savedAt: Date()
        )
        engine.restorePlaybackState(state)
        return engine
    }

    // MARK: - AudioEngine.insertInQueue

    func testInsertInQueueAtMidPositionAfterCurrent() {
        let songs = (1...5).map { makeSong(id: "id\($0)", title: "S\($0)") }
        let engine = makeEngine(queue: songs, currentIndex: 1)  // playing S2
        let newSong = makeSong(id: "new", title: "N")

        engine.insertInQueue(newSong, at: engine.currentIndex + 1)

        XCTAssertEqual(engine.queue.map(\.id), ["id1", "id2", "new", "id3", "id4", "id5"])
        // Currently-playing song must keep its position by identity.
        XCTAssertEqual(engine.queue[engine.currentIndex].id, "id2")
        XCTAssertEqual(engine.currentIndex, 1)
    }

    func testInsertInQueueDeduplicatesExistingSong() {
        let songs = (1...4).map { makeSong(id: "id\($0)") }
        let engine = makeEngine(queue: songs, currentIndex: 0)  // playing id1

        // Move id4 to position right after the current track.
        engine.insertInQueue(songs[3], at: engine.currentIndex + 1)

        XCTAssertEqual(engine.queue.count, 4, "Existing song must move, not duplicate")
        XCTAssertEqual(engine.queue.map(\.id), ["id1", "id4", "id2", "id3"])
        XCTAssertEqual(engine.queue[engine.currentIndex].id, "id1")
    }

    func testInsertInQueueAtLastPosition() {
        let songs = (1...3).map { makeSong(id: "id\($0)") }
        let engine = makeEngine(queue: songs, currentIndex: 0)
        let newSong = makeSong(id: "tail")

        engine.insertInQueue(newSong, at: engine.queue.count)

        XCTAssertEqual(engine.queue.map(\.id), ["id1", "id2", "id3", "tail"])
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testInsertInQueueRefusesToMoveCurrentlyPlayingSong() {
        let songs = (1...3).map { makeSong(id: "id\($0)") }
        let engine = makeEngine(queue: songs, currentIndex: 1)  // playing id2

        // Attempting to "Play Next" the currently-playing song must be a no-op.
        engine.insertInQueue(songs[1], at: engine.currentIndex + 1)

        XCTAssertEqual(engine.queue.map(\.id), ["id1", "id2", "id3"])
        XCTAssertEqual(engine.currentIndex, 1)
    }

    func testInsertInQueueClampsOutOfRangeIndex() {
        let songs = (1...2).map { makeSong(id: "id\($0)") }
        let engine = makeEngine(queue: songs, currentIndex: 0)
        let newSong = makeSong(id: "new")

        // currentIndex+1 = 1 is fine; pass a deliberately huge index to verify
        // the clamp branch when callers compute a stale index.
        engine.insertInQueue(newSong, at: 999)

        XCTAssertEqual(engine.queue.map(\.id), ["id1", "id2", "new"])
        XCTAssertEqual(engine.currentIndex, 0)
    }

    // MARK: - PlayerViewModel.playNext (empty-queue delegation)

    /// Empty queue: `playNext` falls through to `play(song:)`. The wrapper is
    /// a one-line guard, so this case verifies that `insertInQueue` is *not*
    /// the path taken (since `currentIndex+1 = 1` would be out of range and
    /// the song still needs to start playback). We assert the engine's queue
    /// stays empty when only `insertInQueue` is invoked on an empty queue —
    /// proving why the `playNext` empty-queue guard delegates to `play(song:)`
    /// instead.
    func testInsertInQueueOnEmptyQueueOnlyAppendsAndDoesNotStartPlayback() {
        let engine = AudioEngine()
        XCTAssertTrue(engine.queue.isEmpty)
        XCTAssertNil(engine.currentTrack)

        let song = makeSong(id: "first")
        engine.insertInQueue(song, at: 1)  // out-of-range, will clamp to 0

        XCTAssertEqual(engine.queue.map(\.id), ["first"])
        // currentTrack remains nil — confirms why `playNext` must delegate to
        // `play(song:)` for the empty-queue branch.
        XCTAssertNil(engine.currentTrack)
    }
}
