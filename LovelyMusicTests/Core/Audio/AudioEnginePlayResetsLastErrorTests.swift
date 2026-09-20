import XCTest

@testable import LovelyMusic

/// Round 2 — Fix 1 (review.md M1 / review-codex MED #5).
///
/// Locks the contract that `AudioEngine.play(song:fromQueue:)` resets
/// `lastError` (and `lastErrorKind`) at entry, BEFORE starting the new
/// playback attempt. Without this reset, two consecutive failed taps with
/// identical error messages produce no observable diff in `lastError` —
/// CarPlay's `handleSongTap` baseline-snapshot detector would never fire,
/// the user would see no alert, and the indicator would silently time out.
@MainActor
final class AudioEnginePlayResetsLastErrorTests: XCTestCase {

    private func makeSong(id: String = "ResetErrTestVid") -> Song {
        Song(
            id: id,
            title: "Reset Test",
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 120,
            thumbnailURL: nil
        )
    }

    /// Pre-seed `lastError` with a sentinel, then verify that calling
    /// `play(...)` clears it synchronously at entry. We do not need the
    /// downstream resolver to succeed — only the synchronous reset matters.
    func testPlayResetsLastErrorAtEntry() {
        let engine = AudioEngine()
        // Resolver intentionally fails so the caller doesn't hit network.
        engine.streamURLResolver = { _ in throw URLError(.notConnectedToInternet) }

        // Seed via the public path: trigger a failure, wait for it to settle.
        // Simpler: inject directly through a setter is not available, so we
        // simulate by reading-back after a known-failing synchronous code
        // path. Since `lastError` is `private(set)`, we cannot write it from
        // the test — instead, we exploit the fact that `play(...)` clears it
        // *before* any work runs, so a non-nil value observed BEFORE the
        // call must be non-nil AFTER only if reset failed.
        //
        // Trick: invoke `play` with a stub resolver that records
        // `lastError` on the very next runloop tick. If the reset works,
        // the value seen at that tick is `nil`.
        let song = makeSong()

        // First, induce a real `lastError` by playing with a failing
        // resolver and yielding so the catch block in `loadAndPlay` runs.
        let priming = expectation(description: "priming failure recorded")
        engine.play(song: song)
        Task { @MainActor in
            // Yield several times to let the resolver Task's catch block
            // assign `lastError` on the main actor.
            for _ in 0..<30 { await Task.yield() }
            priming.fulfill()
        }
        wait(for: [priming], timeout: 2.0)

        XCTAssertNotNil(
            engine.lastError,
            "Precondition: priming play() should have produced a lastError"
        )

        // Now call play() again. Per Fix 1, lastError MUST be nil
        // synchronously at entry — i.e. immediately after the call returns,
        // before any async resolver work has had a chance to run.
        engine.play(song: makeSong(id: "ResetErrTestVid2"))

        XCTAssertNil(
            engine.lastError,
            "play(...) MUST reset lastError synchronously at entry (Round 2 Fix 1)"
        )
        XCTAssertEqual(
            engine.lastErrorKind, .transient,
            "play(...) MUST also reset lastErrorKind to .transient at entry"
        )
    }
}
