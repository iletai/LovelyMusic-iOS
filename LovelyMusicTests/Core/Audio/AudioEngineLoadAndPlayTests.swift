import Foundation
import XCTest

@testable import LovelyMusic

/// Regression locks for **S1 — offline-first ordering** in
/// `AudioEngine.loadAndPlay`.
///
/// The contract under test:
///
/// 1. If `downloadManager?.localFileURL(songId:)` returns a URL,
///    `loadAndPlay` MUST NOT start the network `streamURLResolver`.
///    A downloaded copy always wins for the initial source selection,
///    even when the network is reachable.
/// 2. Otherwise, if `audioCacheManager?.getFile(for:)` returns a URL,
///    the resolver still MUST NOT be invoked — the cached remuxed file
///    is played instead.
/// 3. If neither local source exists, the resolver IS invoked
///    (preserves existing behavior, including offline error surfacing).
/// 4. When `downloadManager == nil`, the original code path runs
///    (resolver invoked when `streamURL == nil`).
///
/// The tests inject:
/// - a real `DownloadManager` seeded via `downloads.json` metadata + a
///   fake on-disk file (the only public way to populate
///   `downloadedSongs` because the class is `final` and the property
///   is `private(set)`);
/// - a real `AudioCacheManager` whose hard-coded `tmp/LovelyMusic/`
///   directory is pre-populated with `{id}_remuxed.m4a` files (init
///   rebuilds entries from disk).
///
/// We verify the initial resolver-skip decision with an inverted
/// expectation that observes the resolver for a bounded interval. This
/// gives its unstructured task an opportunity to run before we inspect
/// the invocation count. The downstream `AVPlayer` setup with fake
/// bytes may fail asynchronously, but it is outside this decision
/// boundary.
@MainActor
final class AudioEngineLoadAndPlayTests: XCTestCase {

    private var savedMetadataFile: Data?
    private var didIsolateMetadataFile = false

    private let testIDs = [
        "AETestVid01", "AETestVid02", "AETestVid03",
        "AETestVid04", "AETestVid05",
    ]

    private var metadataFileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("com.lovelymusic.app", isDirectory: true)
        .appendingPathComponent("downloads.json")
    }

    /// These locations are deliberately computed rather than initialized in
    /// `setUpWithError()`: XCTest can invoke teardown after a throwing setup.
    private var testCacheDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LovelyMusic", isDirectory: true)
    }

    private var testDownloadsDir: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Downloads", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        let fileManager = FileManager.default
        savedMetadataFile = nil
        didIsolateMetadataFile = false
        if fileManager.fileExists(atPath: metadataFileURL.path) {
            let existingMetadata = try Data(contentsOf: metadataFileURL)
            try fileManager.removeItem(at: metadataFileURL)
            savedMetadataFile = existingMetadata
        }
        didIsolateMetadataFile = true

        try fileManager.createDirectory(
            at: testCacheDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: testDownloadsDir, withIntermediateDirectories: true)

        try cleanupTestArtifacts()
    }

    override func tearDownWithError() throws {
        defer {
            savedMetadataFile = nil
            didIsolateMetadataFile = false
        }

        var cleanupError: Error?
        do {
            try cleanupTestArtifacts()
        } catch {
            cleanupError = error
        }

        var metadataRestoreError: Error?
        do {
            try restoreMetadataFile()
        } catch {
            metadataRestoreError = error
        }

        try super.tearDownWithError()

        if let metadataRestoreError {
            throw metadataRestoreError
        }
        if let cleanupError {
            throw cleanupError
        }
    }

    private func restoreMetadataFile() throws {
        guard didIsolateMetadataFile else { return }

        let fileManager = FileManager.default
        if let savedMetadataFile {
            try fileManager.createDirectory(
                at: metadataFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try savedMetadataFile.write(to: metadataFileURL, options: .atomic)
        } else if fileManager.fileExists(atPath: metadataFileURL.path) {
            try fileManager.removeItem(at: metadataFileURL)
        }
    }

    // MARK: - Helpers

    private func cleanupTestArtifacts() throws {
        for id in testIDs {
            try removeItemIfPresent(
                at: testCacheDir.appendingPathComponent("\(id)_remuxed.m4a")
            )
            try removeItemIfPresent(
                at: testDownloadsDir.appendingPathComponent("\(id).m4a")
            )
        }
    }

    private func removeItemIfPresent(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: "Test \(id)",
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
    }

    private func writeFakeFile(at url: URL, size: Int = 64) throws {
        let data = Data(repeating: 0xAA, count: size)
        try data.write(to: url)
    }

    /// Seed `DownloadManager` so `localFileURL(songId:)` returns a URL.
    /// Writes both the on-disk file and the `downloads.json` metadata that
    /// `DownloadManager.init` reads via `loadDownloadedSongs()`.
    private func seedDownloadedSong(_ song: Song) throws {
        let mediaURL = testDownloadsDir.appendingPathComponent("\(song.id).m4a")
        try Data(repeating: 0xAA, count: 64).write(to: mediaURL)
        let entry = DownloadManager.DownloadedSong(
            song: song,
            relativePath: mediaURL.lastPathComponent,
            downloadedAt: Date(),
            fileSize: 64
        )
        try FileManager.default.createDirectory(
            at: metadataFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(
            to: metadataFileURL,
            options: .atomic
        )
    }

    /// Build an engine with a tracking resolver. The returned closure
    /// reports the running invocation count.
    private func makeEngineAndResolverCounter(
        downloadManager: DownloadManager?,
        cacheManager: AudioCacheManager?,
        onResolve: (() -> Void)? = nil
    ) -> (engine: AudioEngine, count: () -> Int) {
        let engine = AudioEngine()
        engine.downloadManager = downloadManager
        engine.audioCacheManager = cacheManager
        let counter = ResolverCounter()
        engine.streamURLResolver = { _ in
            counter.increment()
            onResolve?()
            throw URLError(.notConnectedToInternet)
        }
        return (engine, { counter.value })
    }

    /// Observe the initial `loadAndPlay` resolver decision without letting the
    /// intentionally invalid 64-byte media fixture trigger playback recovery.
    /// The resolution branch snapshots `streamURLResolver` before it creates
    /// its task, so a mistakenly scheduled initial resolver still fulfills the
    /// inverted expectation after this assignment. A later AVPlayer retry sees
    /// `nil` instead and cannot contaminate this ordering assertion.
    private func awaitInitialResolverDecision(
        for engine: AudioEngine,
        resolverNotCalled: XCTestExpectation
    ) async {
        engine.streamURLResolver = nil
        await fulfillment(of: [resolverNotCalled], timeout: 0.2)
    }

    /// Yield the MainActor several times so any task continuations
    /// (e.g., the resolver Task's catch block) can flush.
    private func drainMainActor(times: Int = 20) async {
        for _ in 0..<times { await Task.yield() }
    }

    // MARK: - Cases

    /// Case 1: Offline + downloaded file present →
    /// initial resolver MUST NOT be called; local playback is selected.
    func testOfflineWithDownloadedFileSkipsResolver() async throws {
        let song = makeSong(id: testIDs[0])
        try seedDownloadedSong(song)
        let dm = DownloadManager()
        _ = try XCTUnwrap(
            dm.localFileURL(songId: song.id),
            "Precondition: seeded download must be visible to DownloadManager"
        )

        let resolverNotCalled = expectation(
            description: "resolver must not be called for downloaded file"
        )
        resolverNotCalled.isInverted = true
        let (engine, count) = makeEngineAndResolverCounter(
            downloadManager: dm,
            cacheManager: nil,
            onResolve: { resolverNotCalled.fulfill() }
        )
        engine.play(song: song)

        XCTAssertEqual(engine.currentTrack?.id, song.id)
        XCTAssertNil(engine.lastError)
        await awaitInitialResolverDecision(
            for: engine,
            resolverNotCalled: resolverNotCalled
        )
        XCTAssertEqual(
            count(), 0,
            "Initial resolver MUST NOT be called when a downloaded file exists"
        )
    }

    /// Case 2: "Online" + downloaded file present →
    /// resolver still NOT called. Offline-first means downloaded
    /// always wins regardless of connectivity.
    ///
    /// Note: there is no real network gate to flip in unit tests; the
    /// contract is unconditional, so this case mirrors case 1 with a
    /// distinct ID to confirm the decision is data-driven (not
    /// environment-driven).
    func testDownloadedFileWinsRegardlessOfConnectivity() async throws {
        let song = makeSong(id: testIDs[1])
        try seedDownloadedSong(song)
        let dm = DownloadManager()
        _ = try XCTUnwrap(
            dm.localFileURL(songId: song.id),
            "Precondition: seeded download must be visible to DownloadManager"
        )

        let resolverNotCalled = expectation(
            description: "resolver must not be called for downloaded file"
        )
        resolverNotCalled.isInverted = true
        let (engine, count) = makeEngineAndResolverCounter(
            downloadManager: dm,
            cacheManager: nil,
            onResolve: { resolverNotCalled.fulfill() }
        )
        engine.play(song: song)

        XCTAssertEqual(engine.currentTrack?.id, song.id)
        await awaitInitialResolverDecision(
            for: engine,
            resolverNotCalled: resolverNotCalled
        )
        XCTAssertEqual(count(), 0)
    }

    /// Case 3: No downloaded file + cached remuxed file present →
    /// resolver NOT called; cache hit short-circuit fires.
    func testCachedRemuxedFileSkipsResolverWhenNoDownload() throws {
        let song = makeSong(id: testIDs[2])
        let cachedURL = testCacheDir.appendingPathComponent(
            "\(song.id)_remuxed.m4a")
        try writeFakeFile(at: cachedURL)
        let cache = AudioCacheManager()  // rebuilds from disk on init
        XCTAssertNotNil(
            cache.getFile(for: song.id),
            "Precondition: cache rebuild must pick up the seeded file"
        )

        let (engine, count) = makeEngineAndResolverCounter(
            downloadManager: nil, cacheManager: cache)
        engine.play(song: song)

        XCTAssertEqual(
            count(), 0,
            "Resolver MUST NOT be called when a cached remux exists"
        )
        XCTAssertEqual(engine.currentTrack?.id, song.id)
    }

    /// Case 4: No downloaded file + no cached file + offline →
    /// resolver IS called, error surfaces. Preserves existing
    /// behavior so callers (e.g., UI retry) still see failures.
    func testNoLocalFilesOfflineInvokesResolverAndSurfacesError() async {
        let song = makeSong(id: testIDs[3])
        let dm = DownloadManager()
        let cache = AudioCacheManager()
        XCTAssertNil(dm.localFileURL(songId: song.id))
        XCTAssertNil(cache.getFile(for: song.id))

        let resolverCalled = expectation(description: "resolver invoked")
        let engine = AudioEngine()
        engine.downloadManager = dm
        engine.audioCacheManager = cache
        let counter = ResolverCounter()
        engine.streamURLResolver = { _ in
            counter.increment()
            resolverCalled.fulfill()
            throw URLError(.notConnectedToInternet)
        }

        engine.play(song: song)

        await fulfillment(of: [resolverCalled], timeout: 2.0)
        await drainMainActor()

        XCTAssertEqual(counter.value, 1, "Resolver should be invoked exactly once")
        XCTAssertNotNil(
            engine.lastError,
            "URLError(.notConnectedToInternet) must surface as lastError"
        )
    }

    /// Case 5: `downloadManager == nil` →
    /// original code path runs (resolver called when `streamURL == nil`).
    func testNilDownloadManagerFallsBackToOriginalResolverPath() async {
        let song = makeSong(id: testIDs[4])
        let resolverCalled = expectation(description: "resolver invoked")
        let engine = AudioEngine()
        engine.downloadManager = nil
        engine.audioCacheManager = nil
        let counter = ResolverCounter()
        engine.streamURLResolver = { _ in
            counter.increment()
            resolverCalled.fulfill()
            throw URLError(.notConnectedToInternet)
        }

        engine.play(song: song)

        await fulfillment(of: [resolverCalled], timeout: 2.0)
        XCTAssertEqual(counter.value, 1)
    }
}

/// Thread-safe counter usable from non-isolated async closures.
private final class ResolverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}
