import Foundation
import XCTest

@testable import LovelyMusic

/// Regression locks for **S3 — backup exclusion** in
/// `DownloadManager.createDirectoryIfNeeded`.
///
/// The contract under test: every persisted file under
/// `Documents/Downloads/` (and the directory itself) must carry the
/// `URLResourceValues.isExcludedFromBackup` flag so that audio
/// payloads do not bloat iCloud / device backups. Audio is
/// reproducible by re-downloading; backup exclusion is the App Review
/// expectation for derived caches of remote content.
///
/// Note on the third intended case (newly-downloaded files flagged at
/// write time): exercising that path requires either stubbing
/// `URLSession.bytes(for:)` or invoking `downloadSong` against a real
/// network. Neither is wired in this test target. The flag-setting
/// call sites (`Self.setExcludedFromBackup(destinationURL)`) live
/// directly before `saveMetadata()` in both the remux-success and
/// remux-fallback branches, so the directory-level idempotent
/// re-walk in `createDirectoryIfNeeded` would catch a regression on
/// next launch even without the per-write flag. Phase 5 integration
/// tests are slated to cover the per-write path end-to-end.
@MainActor
final class DownloadManagerTests: XCTestCase {

    private static let metadataKey = "downloaded_songs_metadata"

    private var savedMetadata: Data?
    private var downloadsDir: URL!
    private let testIDs = ["DMTestVid01", "DMTestVid02"]

    override func setUp() {
        super.setUp()
        savedMetadata = UserDefaults.standard.data(forKey: Self.metadataKey)
        UserDefaults.standard.removeObject(forKey: Self.metadataKey)

        downloadsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: downloadsDir, withIntermediateDirectories: true)

        cleanupTestArtifacts()
    }

    override func tearDown() {
        cleanupTestArtifacts()
        if let saved = savedMetadata {
            UserDefaults.standard.set(saved, forKey: Self.metadataKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.metadataKey)
        }
        super.tearDown()
    }

    private func cleanupTestArtifacts() {
        for id in testIDs {
            try? FileManager.default.removeItem(
                at: downloadsDir.appendingPathComponent("\(id).m4a"))
        }
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        // URL caches resource values per-instance; drop the cache so we read
        // the current on-disk flag rather than a stale value set earlier in
        // the test via `setResourceValues(_:)`.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup ?? false
    }

    // MARK: - Cases

    /// Case 1: instantiating `DownloadManager` flags the
    /// `Downloads/` directory as excluded from backup.
    func testInitFlagsDownloadsDirectoryAsExcludedFromBackup() throws {
        // Clear the flag to make sure init re-applies it (idempotent).
        var dirURL = downloadsDir!
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = false
        try? dirURL.setResourceValues(rv)

        _ = DownloadManager()

        let excluded = try isExcludedFromBackup(downloadsDir)
        XCTAssertTrue(
            excluded,
            "Documents/Downloads/ must be flagged isExcludedFromBackup after init"
        )
    }

    /// Case 2: pre-existing files in `Downloads/` (e.g., from a build
    /// that predates S3) are flagged on next init by the migration
    /// walk in `createDirectoryIfNeeded`.
    func testInitFlagsExistingFilesAsExcludedFromBackup() throws {
        let id = testIDs[0]
        var fileURL = downloadsDir.appendingPathComponent("\(id).m4a")
        let payload = Data(repeating: 0xCC, count: 64)
        try payload.write(to: fileURL, options: .atomic)

        // Force the flag off so we can prove the migration walk sets it.
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = false
        try? fileURL.setResourceValues(rv)
        XCTAssertFalse(
            try isExcludedFromBackup(fileURL),
            "Precondition: file must start without backup-exclusion"
        )

        _ = DownloadManager()

        XCTAssertTrue(
            try isExcludedFromBackup(fileURL),
            "Existing file must be flagged isExcludedFromBackup after init"
        )
    }

    /// Case 3 (deferred): newly-downloaded files are flagged at write
    /// time — covered by the call sites in `downloadSong`'s remux
    /// success / fallback branches. Integration coverage is deferred
    /// to Phase 5 because the test target lacks `URLSession` stubbing
    /// for `bytes(for:)`. The directory-level migration walk above
    /// catches any regression on next launch.
    func testNewlyDownloadedFilesFlaggedAtWriteTime_DeferredToPhase5() throws {
        throw XCTSkip(
            "Requires URLSession stubbing — deferred to Phase 5 integration tests"
        )
    }
}
