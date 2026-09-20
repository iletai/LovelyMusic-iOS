import AVFoundation
import Foundation
import XCTest

@testable import LovelyMusic

/// Tests verifying that playback works seamlessly for bundled demo tracks
/// and local file URLs when App Store Review Mode is active.
@MainActor
final class AudioEngineReviewModePlaybackTests: XCTestCase {

    private var tempTestAudioURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Create a temporary dummy audio file for testing local playback
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModeTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("demo_test_track.m4a")
        try Data(repeating: 0xAA, count: 128).write(to: fileURL)
        tempTestAudioURL = fileURL
    }

    override func tearDownWithError() throws {
        if let tempTestAudioURL {
            try? FileManager.default.removeItem(at: tempTestAudioURL)
        }
        tempTestAudioURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func testPerformLoadAndPlayWithLocalFileURLPlaysDirectlyWithoutDownloadFailure() {
        guard let localURL = tempTestAudioURL else {
            XCTFail("Missing test audio file")
            return
        }

        let engine = AudioEngine()
        var song = Song(
            id: "demo_test_song",
            title: "Demo Test Song",
            artistName: "Test Artist",
            artistId: nil,
            albumName: "Demo Album",
            albumId: nil,
            duration: 120,
            thumbnailURL: nil
        )
        song.streamURL = localURL.absoluteString

        engine.performLoadAndPlay(song: song)

        XCTAssertFalse(
            engine.isStreamingMode,
            "Local file URLs must play in local file mode (isStreamingMode == false)"
        )
        XCTAssertNotEqual(
            engine.lastError,
            "Download failed",
            "Local file playback must NOT trigger startDownloadThenPlay or fail with 'Download failed'"
        )
        XCTAssertEqual(engine.localFileURL, localURL)
    }

    func testDemoPlayerRepositoryResolvesBundledSongOrThrowsDemoError() async {
        let demoRepo = DemoPlayerRepository()
        // Non-existent song ID should throw DemoError.streamingNotAvailable
        do {
            _ = try await demoRepo.resolveStreamURL(videoId: "non_existent_demo_song_id_12345")
            XCTFail("Should throw DemoError for missing file")
        } catch let error as DemoError {
            XCTAssertEqual(error, DemoError.streamingNotAvailable)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testResolveStreamUseCaseHandlesLocalResourceGracefully() async throws {
        let demoRepo = DemoPlayerRepository()
        let useCase = ResolveStreamUseCase(repository: demoRepo)

        // For non-existent song, execute should surface streamingNotAvailable
        do {
            _ = try await useCase.execute(
                videoId: "non_existent_demo_song_id_12345",
                quality: .high
            )
            XCTFail("Should throw DemoError")
        } catch let error as DemoError {
            XCTAssertEqual(error, DemoError.streamingNotAvailable)
        }
    }

    func testGaplessPrefetchHandlesBundledAudioWithoutRemoteTransfer() {
        let manager = GaplessPreFetchManager()
        let song1 = Song(
            id: "song_1",
            title: "Song 1",
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 100,
            thumbnailURL: nil
        )
        let song2 = Song(
            id: "demo_song_morning_light",
            title: "Song 2",
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 100,
            thumbnailURL: nil
        )
        manager.queue = [song1, song2]
        manager.currentIndex = 0

        manager.prefetchNextTrack()

        // If bundled demo audio exists in bundle, it should prepare the item
        if Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a") != nil {
            XCTAssertNotNil(manager.prefetchedPlayerItem)
            XCTAssertEqual(manager.prefetchedSongId, "demo_song_morning_light")
        }
    }
}
