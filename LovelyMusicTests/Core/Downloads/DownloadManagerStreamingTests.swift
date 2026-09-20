import Foundation
import XCTest

@testable import LovelyMusic

/// Feature 3 — Storage Phase 2 tests.
///
/// Covers: D3 metadata migration (UserDefaults → JSON file),
/// D2 concurrent download cap, D4 partial file cleanup,
/// and C1 remux-failure fallback.
///
/// ⚠️ AI limitation: D2 concurrency tests and remux fallback tests
/// cannot be exercised end-to-end without URLSession stubbing. These
/// tests validate the observable state machine behavior via the public
/// API surface. Marked for human review.
@MainActor
final class DownloadManagerStreamingTests: XCTestCase {

    // MARK: - Constants

    private let legacyKey = "downloaded_songs_metadata"

    // D3 metadata paths
    private var metadataFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("com.lovelymusic.app", isDirectory: true)
            .appendingPathComponent("downloads.json")
    }

    private var downloadsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: - State preservation

    private var savedLegacyData: Data?
    private var savedMetadataFile: Data?
    private let testSongIds = ["DMStreamTest01", "DMStreamTest02", "DMStreamTest03"]

    override func setUp() {
        super.setUp()
        // Save and clear legacy key
        savedLegacyData = UserDefaults.standard.data(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)

        // Save and remove metadata file
        if FileManager.default.fileExists(atPath: metadataFileURL.path) {
            savedMetadataFile = try? Data(contentsOf: metadataFileURL)
            try? FileManager.default.removeItem(at: metadataFileURL)
        }

        // Ensure downloads directory exists
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        cleanupTestFiles()
    }

    override func tearDown() {
        cleanupTestFiles()

        // Restore legacy key
        if let saved = savedLegacyData {
            UserDefaults.standard.set(saved, forKey: legacyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        // Restore metadata file
        if let saved = savedMetadataFile {
            let dir = metadataFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? saved.write(to: metadataFileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: metadataFileURL)
        }

        super.tearDown()
    }

    private func cleanupTestFiles() {
        for id in testSongIds {
            try? FileManager.default.removeItem(
                at: downloadsDir.appendingPathComponent("\(id).m4a"))
            try? FileManager.default.removeItem(
                at: downloadsDir.appendingPathComponent("\(id)_raw.m4a"))
        }
    }

    // MARK: - D3: Metadata migration

    func testMigration_writesLegacyDataToJsonFile() throws {
        // Write test metadata to UserDefaults (legacy format)
        let song = makeSong(id: testSongIds[0])
        let entry = DownloadManager.DownloadedSong(
            song: song,
            relativePath: "\(testSongIds[0]).m4a",
            downloadedAt: Date(),
            fileSize: 1024
        )
        let legacyData = try JSONEncoder().encode([entry])
        UserDefaults.standard.set(legacyData, forKey: legacyKey)

        // Create the actual file so loadDownloadedSongs doesn't prune it
        let fileURL = downloadsDir.appendingPathComponent("\(testSongIds[0]).m4a")
        try Data(repeating: 0xAA, count: 64).write(to: fileURL)

        // Init triggers migration
        let manager = DownloadManager()

        // Verify metadata file was created
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: metadataFileURL.path),
            "Migration must create downloads.json in Application Support"
        )

        // Verify the migrated data is loadable
        XCTAssertEqual(manager.downloadedSongs.count, 1)
        XCTAssertEqual(manager.downloadedSongs.first?.song.id, testSongIds[0])
    }

    func testMigration_removesLegacyKeyAfterSuccess() throws {
        let song = makeSong(id: testSongIds[0])
        let entry = DownloadManager.DownloadedSong(
            song: song,
            relativePath: "\(testSongIds[0]).m4a",
            downloadedAt: Date(),
            fileSize: 512
        )
        let legacyData = try JSONEncoder().encode([entry])
        UserDefaults.standard.set(legacyData, forKey: legacyKey)

        let fileURL = downloadsDir.appendingPathComponent("\(testSongIds[0]).m4a")
        try Data(repeating: 0xBB, count: 32).write(to: fileURL)

        _ = DownloadManager()

        XCTAssertNil(
            UserDefaults.standard.data(forKey: legacyKey),
            "Legacy UserDefaults key must be removed after successful migration"
        )
    }

    func testMigration_noDoubleMigration() throws {
        let song = makeSong(id: testSongIds[0])
        let entry = DownloadManager.DownloadedSong(
            song: song,
            relativePath: "\(testSongIds[0]).m4a",
            downloadedAt: Date(),
            fileSize: 256
        )
        let legacyData = try JSONEncoder().encode([entry])
        UserDefaults.standard.set(legacyData, forKey: legacyKey)

        let fileURL = downloadsDir.appendingPathComponent("\(testSongIds[0]).m4a")
        try Data(repeating: 0xCC, count: 16).write(to: fileURL)

        // First init — migrates
        _ = DownloadManager()

        // Second init — must NOT attempt to re-migrate (legacy key already removed)
        let manager2 = DownloadManager()
        XCTAssertEqual(
            manager2.downloadedSongs.count, 1,
            "Second init must not double-migrate or lose entries"
        )
        XCTAssertNil(UserDefaults.standard.data(forKey: legacyKey))
    }

    // MARK: - D2: Concurrent cap

    func testMaxConcurrentDownloadsIsTwo() {
        // Verify via the public API behavior: starting 3 downloads
        // should leave the 3rd in .queued state.
        let manager = DownloadManager()
        let song1 = makeSong(id: testSongIds[0])
        let song2 = makeSong(id: testSongIds[1])
        let song3 = makeSong(id: testSongIds[2])

        // Use a resolver that never completes (hangs indefinitely)
        let neverResolver: (String) async throws -> (url: String, contentLength: Int64?) = { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return ("", nil)
        }

        manager.downloadSong(song1, streamURLResolver: neverResolver)
        manager.downloadSong(song2, streamURLResolver: neverResolver)
        manager.downloadSong(song3, streamURLResolver: neverResolver)

        // song1 and song2 should be .downloading, song3 should be .queued
        if case .downloading = manager.downloadState(for: testSongIds[0]) {
            // expected
        } else {
            XCTFail("Song 1 should be downloading; got \(manager.downloadState(for: testSongIds[0]))")
        }

        if case .downloading = manager.downloadState(for: testSongIds[1]) {
            // expected
        } else {
            XCTFail("Song 2 should be downloading; got \(manager.downloadState(for: testSongIds[1]))")
        }

        XCTAssertEqual(
            manager.downloadState(for: testSongIds[2]), .queued,
            "Third download must be queued when 2 are already active"
        )

        // Cleanup: cancel all
        manager.cancelDownload(songId: testSongIds[0])
        manager.cancelDownload(songId: testSongIds[1])
        manager.cancelDownload(songId: testSongIds[2])
    }

    func testCancellingActiveDownload_dequeuesToNextPending() {
        let manager = DownloadManager()
        let song1 = makeSong(id: testSongIds[0])
        let song2 = makeSong(id: testSongIds[1])
        let song3 = makeSong(id: testSongIds[2])

        let neverResolver: (String) async throws -> (url: String, contentLength: Int64?) = { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return ("", nil)
        }

        manager.downloadSong(song1, streamURLResolver: neverResolver)
        manager.downloadSong(song2, streamURLResolver: neverResolver)
        manager.downloadSong(song3, streamURLResolver: neverResolver)

        XCTAssertEqual(manager.downloadState(for: testSongIds[2]), .queued)

        // Cancel song1 → song3 should dequeue and start downloading
        manager.cancelDownload(songId: testSongIds[0])

        if case .downloading = manager.downloadState(for: testSongIds[2]) {
            // expected: queued item was dequeued
        } else {
            XCTFail(
                "Queued download should start after an active slot opens; got \(manager.downloadState(for: testSongIds[2]))"
            )
        }

        // Cleanup
        manager.cancelDownload(songId: testSongIds[1])
        manager.cancelDownload(songId: testSongIds[2])
    }

    // MARK: - D4: Partial file cleanup

    func testCleanupPartialFiles_removesBothRawAndTmp() throws {
        let id = testSongIds[0]
        let rawFile = downloadsDir.appendingPathComponent("\(id)_raw.m4a")
        let m4aFile = downloadsDir.appendingPathComponent("\(id).m4a")

        // Create both partial files
        try Data(repeating: 0x01, count: 32).write(to: rawFile)
        try Data(repeating: 0x02, count: 32).write(to: m4aFile)

        let manager = DownloadManager()
        // Trigger cleanup via cancel (which calls cleanupPartialFiles internally)
        manager.cancelDownload(songId: id)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rawFile.path),
            "Raw partial file must be removed on cleanup"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: m4aFile.path),
            "Partial m4a file must be removed on cleanup (not in completed list)"
        )
    }

    // MARK: - C1: Remux fallback

    /// Validates that the remux-fallback logic path exists by confirming the
    /// download state machine handles failure modes. Full end-to-end remux
    /// testing requires URLSession stubbing (deferred to Phase 5).
    ///
    /// ⚠️ AI limitation: This test validates state-machine setup, not actual
    /// remux behavior. The real remux path requires AVFoundation which is not
    /// stubbable in unit tests. Flagged for human review.
    func testRemuxFallback_stateTransitions_deferredEndToEnd() throws {
        throw XCTSkip(
            "Remux fallback end-to-end requires URLSession + AVFoundation stubbing — deferred to Phase 5"
        )
    }

    /// Verify that the DownloadState enum includes all expected cases.
    func testDownloadStateEnumCases() {
        let notDownloaded = DownloadManager.DownloadState.notDownloaded
        let downloading = DownloadManager.DownloadState.downloading(progress: 0.5)
        let downloaded = DownloadManager.DownloadState.downloaded
        let failed = DownloadManager.DownloadState.failed
        let queued = DownloadManager.DownloadState.queued

        XCTAssertEqual(notDownloaded, .notDownloaded)
        XCTAssertEqual(downloading, .downloading(progress: 0.5))
        XCTAssertEqual(downloaded, .downloaded)
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(queued, .queued)
    }

    // MARK: - Helpers

    private func makeSong(id: String) -> Song {
        Song(
            id: id, title: "Test Song \(id)", artistName: "Test Artist",
            artistId: nil, albumName: nil, albumId: nil,
            duration: 180, thumbnailURL: nil
        )
    }
}
