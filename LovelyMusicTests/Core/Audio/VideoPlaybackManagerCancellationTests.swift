import AVFoundation
import XCTest

@testable import LovelyMusic

/// Verifies T2 of `doc/exec-plans/active/2026-05-04-video-load-race.md`:
/// `VideoPlaybackManager.loadVideoStream(for:)` cancels the in-flight task on
/// every new call so superseded loads never assign `videoPlayerItem`.
@MainActor
final class VideoPlaybackManagerCancellationTests: XCTestCase {

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: id,
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
    }

    /// A controllable resolver fixture: each `videoId` suspends until its
    /// continuation is resumed via `release(songId:)`.
    final class ControllableResolver: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
        private(set) var assignedItemIds: [String] = []
        private(set) var resolvedIds: [String] = []

        func resolver(for songId: String) async throws -> (url: String, contentLength: Int64?)? {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                continuations[songId] = c
                lock.unlock()
            }
            lock.lock()
            resolvedIds.append(songId)
            lock.unlock()
            return ("https://cdn.example/\(songId).mp4", 12345)
        }

        func release(songId: String) {
            lock.lock()
            let c = continuations.removeValue(forKey: songId)
            lock.unlock()
            c?.resume()
        }
    }

    func testSupersededLoadIsCancelledBeforeAssignment() async throws {
        let manager = VideoPlaybackManager()
        manager.setVideoMode(true)
        let resolver = ControllableResolver()
        manager.videoStreamURLResolver = { id in
            try await resolver.resolver(for: id)
        }

        // Kick off song A's load — its continuation is held until release.
        manager.loadVideoStream(for: makeSong(id: "A"))

        // Allow the Task to enter the `await resolver(...)` suspension.
        try await Task.sleep(nanoseconds: 30_000_000)

        // Start song B's load — this must cancel A's task BEFORE A's
        // continuation resumes.
        manager.loadVideoStream(for: makeSong(id: "B"))

        // Resume A — it should observe cancellation and bail out without
        // assigning videoPlayerItem.
        resolver.release(songId: "A")
        try await Task.sleep(nanoseconds: 100_000_000)

        // Causal assertion: A's load body must NOT have passed the
        // cancellation/token guard inside `MainActor.run`. This is robust
        // against `makeSilentAudioMix` stalling on B's `cdn.example` URL,
        // which would otherwise let `videoPlayerItem == nil` pass for the
        // wrong reason (F4).
        XCTAssertFalse(
            manager.assignedStreamURLsForTesting.contains("https://cdn.example/A.mp4"),
            "Cancelled load must not reach the videoPlayerItem assignment block"
        )

        // Resume B — it should be allowed to complete. We don't assert on
        // `videoPlayerItem` here because `AVURLAsset` performs a real DNS
        // lookup on the stub URL which is timing-sensitive in CI; the T2
        // invariant we care about is that the SUPERSEDED load (A) was
        // suppressed, asserted above.
        resolver.release(songId: "B")
        try await Task.sleep(nanoseconds: 100_000_000)

        // Sanity: the resolver actually returned for both ids — proving that
        // we're not falsely-passing because A simply never woke up.
        XCTAssertEqual(
            Set(resolver.resolvedIds), Set(["A", "B"]),
            "Both resolver continuations should have completed"
        )
    }
}
