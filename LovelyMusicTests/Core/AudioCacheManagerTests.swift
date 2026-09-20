import XCTest

@testable import LovelyMusic

final class AudioCacheManagerTests: XCTestCase {

    private var testDirectory: URL!

    override func setUp() {
        super.setUp()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LovelyMusic", isDirectory: true)
        try? FileManager.default.removeItem(at: testDirectory)
        try? FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDirectory)
        super.tearDown()
    }

    // MARK: - Helpers

    private func createFakeFile(videoId: String, size: Int) -> URL {
        let url = testDirectory.appendingPathComponent("\(videoId)_remuxed.m4a")
        let data = Data(repeating: 0xAA, count: size)
        try! data.write(to: url)
        return url
    }

    // MARK: - Tests

    func testEmptyCacheReturnsNil() {
        let manager = AudioCacheManager()

        XCTAssertNil(manager.getFile(for: "nonexistent"))
    }

    func testRegisterAndRetrieveFile() {
        let manager = AudioCacheManager()
        let url = createFakeFile(videoId: "vid1", size: 100)

        manager.registerFile(videoId: "vid1", fileURL: url)

        let result = manager.getFile(for: "vid1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result, url)
    }

    func testFileCountAndTotalSize() {
        let manager = AudioCacheManager()
        let url1 = createFakeFile(videoId: "vid1", size: 100)
        let url2 = createFakeFile(videoId: "vid2", size: 250)

        manager.registerFile(videoId: "vid1", fileURL: url1)
        manager.registerFile(videoId: "vid2", fileURL: url2)

        XCTAssertEqual(manager.fileCount, 2)
        XCTAssertEqual(manager.totalSize, 350)
    }

    func testGetFileUpdatesAccessTime() {
        let manager = AudioCacheManager()
        let url = createFakeFile(videoId: "vid1", size: 100)

        manager.registerFile(videoId: "vid1", fileURL: url)
        Thread.sleep(forTimeInterval: 0.1)

        let result = manager.getFile(for: "vid1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result, url)
    }

    func testGetFileReturnsNilWhenFileDeletedExternally() {
        let manager = AudioCacheManager()
        let url = createFakeFile(videoId: "vid1", size: 100)

        manager.registerFile(videoId: "vid1", fileURL: url)
        XCTAssertNotNil(manager.getFile(for: "vid1"))

        try! FileManager.default.removeItem(at: url)

        XCTAssertNil(manager.getFile(for: "vid1"))
        XCTAssertEqual(manager.fileCount, 0)
    }

    func testClearAllRemovesAllFiles() {
        let manager = AudioCacheManager()
        let url1 = createFakeFile(videoId: "vid1", size: 100)
        let url2 = createFakeFile(videoId: "vid2", size: 200)

        manager.registerFile(videoId: "vid1", fileURL: url1)
        manager.registerFile(videoId: "vid2", fileURL: url2)
        XCTAssertEqual(manager.fileCount, 2)

        manager.clearAll()

        XCTAssertEqual(manager.fileCount, 0)
        XCTAssertEqual(manager.totalSize, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url2.path))
    }

    func testEvictionRemovesLRUFile() {
        let manager = AudioCacheManager(maxCacheSize: 500)

        let urlA = createFakeFile(videoId: "A", size: 200)
        manager.registerFile(videoId: "A", fileURL: urlA)
        Thread.sleep(forTimeInterval: 0.1)

        let urlB = createFakeFile(videoId: "B", size: 200)
        manager.registerFile(videoId: "B", fileURL: urlB)
        Thread.sleep(forTimeInterval: 0.1)

        let urlC = createFakeFile(videoId: "C", size: 200)
        manager.registerFile(videoId: "C", fileURL: urlC)

        // Total would be 600 > 500, so A (oldest) should be evicted
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertNil(manager.getFile(for: "A"))
        XCTAssertNotNil(manager.getFile(for: "B"))
        XCTAssertNotNil(manager.getFile(for: "C"))
    }

    func testEvictionPreservesRecentlyAccessed() {
        let manager = AudioCacheManager(maxCacheSize: 500)

        let urlA = createFakeFile(videoId: "A", size: 200)
        manager.registerFile(videoId: "A", fileURL: urlA)
        Thread.sleep(forTimeInterval: 0.1)

        let urlB = createFakeFile(videoId: "B", size: 200)
        manager.registerFile(videoId: "B", fileURL: urlB)
        Thread.sleep(forTimeInterval: 0.1)

        // Refresh A's access time so it's no longer LRU
        _ = manager.getFile(for: "A")
        Thread.sleep(forTimeInterval: 0.1)

        let urlC = createFakeFile(videoId: "C", size: 200)
        manager.registerFile(videoId: "C", fileURL: urlC)

        // B should be evicted (oldest access), A and C should survive
        XCTAssertNotNil(manager.getFile(for: "A"))
        XCTAssertNil(manager.getFile(for: "B"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertNotNil(manager.getFile(for: "C"))
    }

    func testFormattedTotalSize() {
        let manager = AudioCacheManager()
        let url = createFakeFile(videoId: "vid1", size: 1024)

        manager.registerFile(videoId: "vid1", fileURL: url)

        let formatted = manager.formattedTotalSize()
        XCTAssertFalse(formatted.isEmpty)
    }

    func testRebuildFromDisk() {
        // Create files on disk BEFORE initializing AudioCacheManager
        _ = createFakeFile(videoId: "preexist1", size: 150)
        _ = createFakeFile(videoId: "preexist2", size: 250)

        let manager = AudioCacheManager()

        XCTAssertGreaterThanOrEqual(manager.fileCount, 2)
        XCTAssertNotNil(manager.getFile(for: "preexist1"))
        XCTAssertNotNil(manager.getFile(for: "preexist2"))
    }

    // MARK: - S2: trimToFit / removeOrphans / reserveSlot

    /// Helper for direct on-disk writes that bypass `registerFile`,
    /// used to simulate orphans / raw downloads / pre-init state.
    private func writeRawFile(named name: String, size: Int) -> URL {
        let url = testDirectory.appendingPathComponent(name)
        let data = Data(repeating: 0xBB, count: size)
        try! data.write(to: url)
        return url
    }

    /// `trimToFit` evicts least-recently-used entries until the total
    /// size is within `maxCacheSize`. Three half-cap files →
    /// post-trim total ≤ cap → oldest by `lastAccessDate` is evicted.
    func testTrimToFitEvictsLRUUntilWithinCap() {
        let cap: Int64 = 600
        let manager = AudioCacheManager(maxCacheSize: cap)

        let urlA = createFakeFile(videoId: "TA", size: 300)
        manager.registerFile(videoId: "TA", fileURL: urlA)
        Thread.sleep(forTimeInterval: 0.05)

        let urlB = createFakeFile(videoId: "TB", size: 300)
        manager.registerFile(videoId: "TB", fileURL: urlB)
        Thread.sleep(forTimeInterval: 0.05)

        let urlC = createFakeFile(videoId: "TC", size: 300)
        manager.registerFile(videoId: "TC", fileURL: urlC)

        // registerFile already calls evictIfNeeded, so trimToFit should
        // be idempotent here. Calling it explicitly verifies the public
        // API path independently from registerFile's implicit call.
        manager.trimToFit()

        XCTAssertLessThanOrEqual(
            manager.totalSize, cap,
            "trimToFit() must keep totalSize within maxCacheSize")
        XCTAssertNil(
            manager.getFile(for: "TA"),
            "Oldest entry (TA) must be evicted")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: urlA.path),
            "Evicted entry's on-disk file must be removed")
        XCTAssertNotNil(manager.getFile(for: "TB"))
        XCTAssertNotNil(manager.getFile(for: "TC"))
    }

    /// `removeOrphans` Pass 1: a registered cache entry whose videoId
    /// is also in `knownDownloadIds` is superseded by the downloaded
    /// copy and must be evicted (entry + on-disk file).
    func testRemoveOrphansSupersededPassDropsRegisteredEntry() {
        let manager = AudioCacheManager()
        let url = createFakeFile(videoId: "abc", size: 100)
        manager.registerFile(videoId: "abc", fileURL: url)
        XCTAssertNotNil(manager.getFile(for: "abc"))

        manager.removeOrphans(knownDownloadIds: ["abc"])

        XCTAssertNil(manager.getFile(for: "abc"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Superseded file must be removed from disk")
        XCTAssertEqual(manager.fileCount, 0)
    }

    /// `removeOrphans` Pass 2: untracked `_remuxed.m4a` files in the
    /// cache directory (e.g., from a crashed remux that never called
    /// `registerFile`) are removed.
    func testRemoveOrphansOrphanPassRemovesUntrackedRemuxedFile() {
        let manager = AudioCacheManager()
        let orphanURL = writeRawFile(named: "orphan_remuxed.m4a", size: 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))

        manager.removeOrphans(knownDownloadIds: [])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanURL.path),
            "Orphan _remuxed.m4a file must be removed")
    }

    /// REGRESSION LOCK (codex Finding #1): `_raw.m4a` files in the
    /// cache directory belong to `AudioEngine`'s
    /// streaming-while-downloading path. `AVPlayer` may be actively
    /// reading them. Pass 2 of `removeOrphans` MUST leave them alone
    /// — only `_remuxed.m4a` files are eligible for orphan removal.
    func testRemoveOrphansPreservesRawFiles() {
        let manager = AudioCacheManager()
        let rawURL = writeRawFile(named: "streaming_raw.m4a", size: 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))

        manager.removeOrphans(knownDownloadIds: [])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawURL.path),
            "_raw.m4a must NOT be removed by orphan sweep — owned by AudioEngine"
        )
    }

    /// REGRESSION LOCK (codex Finding #2): a slot reserved via
    /// `reserveSlot` (called immediately before a `moveItem` /
    /// remux-write into `cacheDirectory`) lives in `state.entries`
    /// and therefore counts as "tracked". `removeOrphans` MUST NOT
    /// delete its on-disk file even though `registerFile` has not
    /// yet recorded the real size.
    func testRemoveOrphansPreservesReservedSlots() {
        let manager = AudioCacheManager()
        let url = createFakeFile(videoId: "reserved", size: 100)

        manager.reserveSlot(videoId: "reserved", fileURL: url)
        manager.removeOrphans(knownDownloadIds: [])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Reserved slot's file must persist through removeOrphans")
        XCTAssertNotNil(
            manager.getFile(for: "reserved"),
            "Reserved entry must still be visible after orphan sweep")
    }

    /// `reserveSlot` writes a placeholder entry with `fileSize == 0`.
    /// A subsequent `registerFile` call must overwrite it
    /// unconditionally with the real size and a fresh access date.
    func testReserveSlotIsOverwrittenByRegisterFile() {
        let manager = AudioCacheManager()
        let url = createFakeFile(videoId: "rs", size: 250)

        manager.reserveSlot(videoId: "rs", fileURL: url)
        XCTAssertEqual(
            manager.totalSize, 0,
            "Reservation must contribute zero bytes to total size")

        Thread.sleep(forTimeInterval: 0.05)
        manager.registerFile(videoId: "rs", fileURL: url)

        XCTAssertEqual(
            manager.totalSize, 250,
            "registerFile must overwrite the reservation with real size")
        XCTAssertEqual(manager.fileCount, 1)
        XCTAssertEqual(manager.getFile(for: "rs"), url)
    }
}
