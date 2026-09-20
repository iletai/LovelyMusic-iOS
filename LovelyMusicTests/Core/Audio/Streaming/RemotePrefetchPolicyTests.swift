import AVFoundation
import Foundation
import XCTest

@testable import LovelyMusic

private final class RemotePrefetchBodyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requestCountStorage = 0
    private static var bodyByteCountStorage = 0
    private static var onBodyStorage: (() -> Void)?

    static var requestCount: Int {
        lock.withLock { requestCountStorage }
    }

    static var bodyByteCount: Int {
        lock.withLock { bodyByteCountStorage }
    }

    static func reset(onBody: (() -> Void)? = nil) {
        lock.withLock {
            requestCountStorage = 0
            bodyByteCountStorage = 0
            onBodyStorage = onBody
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "remote-prefetch.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Data(repeating: 0xAA, count: 64)
        let onBody = Self.lock.withLock { () -> (() -> Void)? in
            Self.requestCountStorage += 1
            Self.bodyByteCountStorage += body.count
            return Self.onBodyStorage
        }
        onBody?()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class HeldCrossfadeLocalValidationBarrier {
    private(set) var validatedURLs: [URL] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend(afterValidating localFile: AudioEngine.CrossfadeLocalFile) async {
        validatedURLs.append(localFile.url)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where continuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(
            continuation,
            "Preparation never reached the post-local-validation barrier",
            file: file,
            line: line
        )
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class RemotePrefetchPolicyTests: XCTestCase {
    private let testIDs = [
        "RemotePolicyActive",
        "RemotePolicyDownloaded",
        "RemotePolicyCached",
        "RemotePolicyCrossLocal",
        "RemotePolicyCrossLateCurrent",
        "RemotePolicyCrossLateNext",
        "RemotePolicyLateLocal",
        "RemotePolicyQueueLocal",
        "RemotePolicyQueueReplacement",
        "RemotePolicyShuffleA",
        "RemotePolicyShuffleB",
        "RemotePolicyShuffleCurrent",
        "RemotePolicyStaleCurrent",
        "RemotePolicyStaleNext",
        "RemotePolicyStaleThird",
        "RemotePolicyAutoplayReplacement",
        "RemotePolicyAutoplaySuccessCurrent",
        "RemotePolicyAutoplaySuccessNext",
        "RemotePolicyAutoplayDuplicateCurrent",
        "RemotePolicyAutoplayDuplicateNext",
        "RemotePolicyAutoplayDuplicateLater",
        "RemotePolicySingletonCurrent",
        "RemotePolicySingletonAutoplay",
        "RemotePolicyBarrierRemote",
        "RemotePolicyPolicyCurrent",
        "RemotePolicyPolicyNext",
        "RemotePolicyPolicyThird",
        "RemotePolicyUnchangedCurrent",
        "RemotePolicyUnchangedNext",
        "RemotePolicyRepeatFirst",
        "RemotePolicyRepeatCurrent",
        "RemotePolicySeekCurrent",
        "RemotePolicySeekNext",
        "RemotePolicySystemCurrent",
        "RemotePolicySystemNext",
    ]

    private var savedMetadataFile: Data?
    private var didIsolateMetadataFile = false

    private var metadataFileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("com.lovelymusic.app", isDirectory: true)
        .appendingPathComponent("downloads.json")
    }

    private var cacheDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LovelyMusic", isDirectory: true)
    }

    private var downloadsDirectory: URL {
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
            savedMetadataFile = try Data(contentsOf: metadataFileURL)
            try fileManager.removeItem(at: metadataFileURL)
        }
        didIsolateMetadataFile = true

        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        try cleanupTestFiles()

        RemotePrefetchBodyURLProtocol.reset()
        XCTAssertTrue(URLProtocol.registerClass(RemotePrefetchBodyURLProtocol.self))
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(RemotePrefetchBodyURLProtocol.self)
        RemotePrefetchBodyURLProtocol.reset()

        var firstError: Error?
        do {
            try cleanupTestFiles()
        } catch {
            firstError = error
        }

        do {
            try restoreMetadataFile()
        } catch {
            if firstError == nil { firstError = error }
        }

        savedMetadataFile = nil
        didIsolateMetadataFile = false
        try super.tearDownWithError()

        if let firstError { throw firstError }
    }

    private func makeSong(id: String, streamURL: String? = nil) -> Song {
        var song = Song(
            id: id,
            title: "Test \(id)",
            artistName: "Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
        song.streamURL = streamURL
        return song
    }

    private func bundledAudioData() throws -> Data {
        try Data(contentsOf: bundledAudioURL())
    }

    private func bundledAudioURL() throws -> URL {
        try XCTUnwrap(
            Bundle.main.url(
                forResource: "demo_song_evening_calm",
                withExtension: "m4a"
            )
        )
    }

    @discardableResult
    private func seedDownloadedSong(_ song: Song) throws -> URL {
        try XCTUnwrap(seedDownloadedSongs([song]).first)
    }

    @discardableResult
    private func seedDownloadedSongs(_ songs: [Song]) throws -> [URL] {
        let data = try bundledAudioData()
        let mediaURLs = try songs.map { song in
            let mediaURL = downloadsDirectory.appendingPathComponent("\(song.id).m4a")
            try data.write(to: mediaURL, options: .atomic)
            return mediaURL
        }
        let entries = zip(songs, mediaURLs).map { song, mediaURL in
            DownloadManager.DownloadedSong(
                song: song,
                relativePath: mediaURL.lastPathComponent,
                downloadedAt: Date(),
                fileSize: Int64(data.count)
            )
        }
        try FileManager.default.createDirectory(
            at: metadataFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: metadataFileURL, options: .atomic)
        return mediaURLs
    }

    private func seedCachedSong(_ song: Song) throws -> URL {
        let fileURL = cacheDirectory.appendingPathComponent("\(song.id)_remuxed.m4a")
        try bundledAudioData().write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func cleanupTestFiles() throws {
        for id in testIDs {
            try removeIfPresent(at: downloadsDirectory.appendingPathComponent("\(id).m4a"))
            try removeIfPresent(at: cacheDirectory.appendingPathComponent("\(id)_remuxed.m4a"))
        }
    }

    private func removeIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func restoreMetadataFile() throws {
        guard didIsolateMetadataFile else { return }

        if let savedMetadataFile {
            try FileManager.default.createDirectory(
                at: metadataFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try savedMetadataFile.write(to: metadataFileURL, options: .atomic)
        } else {
            try removeIfPresent(at: metadataFileURL)
        }
    }

    private func assertNotLocallyAvailable(
        from engine: AudioEngine,
        for song: Song,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await engine.prepareCrossfadePlayerItem(for: song)
            XCTFail("Remote speculative preparation must not create an item", file: file, line: line)
        } catch let error as AudioEngine.CrossfadePreparationError {
            XCTAssertEqual(error, .notLocallyAvailable, file: file, line: line)
        } catch {
            XCTFail("Unexpected crossfade preparation error: \(error)", file: file, line: line)
        }
    }

    func testGaplessResolvedRemoteTrackTransfersZeroBodyBytes() async {
        let bodyReceived = expectation(description: "remote response body received")
        bodyReceived.isInverted = true
        RemotePrefetchBodyURLProtocol.reset(onBody: { bodyReceived.fulfill() })

        let manager = GaplessPreFetchManager()
        manager.queue = [
            makeSong(id: "RemotePolicyCurrent"),
            makeSong(
                id: "RemotePolicyResolved",
                streamURL: "https://remote-prefetch.invalid/audio.m4a?sig=preserve"
            ),
        ]
        manager.currentIndex = 0

        manager.prefetchNextTrack()

        await fulfillment(of: [bodyReceived], timeout: 0.25)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
        XCTAssertNil(manager.prefetchedPlayerItem)
        XCTAssertNil(manager.prefetchedSongId)
        XCTAssertNil(manager.prefetchedLocalFileURL)
        manager.cancelPrefetch()
    }

    func testGaplessRemoteMissRetriesWhenDownloadBecomesAvailable() throws {
        let lateLocalSong = makeSong(id: "RemotePolicyLateLocal")
        let manager = GaplessPreFetchManager()
        manager.queue = [
            makeSong(id: "RemotePolicyCurrent"),
            lateLocalSong,
        ]
        manager.currentIndex = 0
        manager.downloadManager = DownloadManager()

        manager.prefetchNextTrack()

        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
        XCTAssertNil(manager.prefetchedPlayerItem)
        XCTAssertNil(manager.prefetchedSongId)
        XCTAssertTrue(manager.isIdle, "A local miss must remain retryable")

        let expectedURL = try seedDownloadedSong(lateLocalSong)
        manager.downloadManager = DownloadManager()
        manager.prefetchNextTrack()

        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
        XCTAssertNotNil(manager.prefetchedPlayerItem)
        XCTAssertEqual(manager.prefetchedSongId, lateLocalSong.id)
        XCTAssertEqual(manager.prefetchedLocalFileURL, expectedURL)
        XCTAssertFalse(manager.isIdle, "Only a successful local preparation should latch")
    }

    func testGaplessQueueChangeImmediatelyDiscardsStalePreparedItem() throws {
        let originalNext = makeSong(id: "RemotePolicyQueueLocal")
        let replacementNext = makeSong(id: "RemotePolicyQueueReplacement")
        try seedDownloadedSongs([originalNext, replacementNext])

        let manager = GaplessPreFetchManager()
        manager.downloadManager = DownloadManager()
        manager.queue = [makeSong(id: "RemotePolicyCurrent"), originalNext]
        manager.currentIndex = 0
        manager.prefetchNextTrack()
        XCTAssertEqual(manager.prefetchedSongId, originalNext.id)

        manager.queue = [makeSong(id: "RemotePolicyCurrent"), replacementNext]

        XCTAssertTrue(manager.isIdle)
        XCTAssertNil(manager.prefetchedPlayerItem)
        XCTAssertNil(manager.prefetchedSongId)
        XCTAssertNil(manager.prefetchedLocalFileURL)
    }

    func testGaplessExplicitDownloadPreparesLocalItemWithoutNetwork() throws {
        let downloadedSong = makeSong(id: "RemotePolicyDownloaded")
        let expectedURL = try seedDownloadedSong(downloadedSong)
        let manager = GaplessPreFetchManager()
        manager.downloadManager = DownloadManager()
        manager.queue = [makeSong(id: "RemotePolicyCurrent"), downloadedSong]
        manager.currentIndex = 0

        manager.prefetchNextTrack()

        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
        XCTAssertNotNil(manager.prefetchedPlayerItem)
        XCTAssertEqual(manager.prefetchedSongId, downloadedSong.id)
        XCTAssertEqual(manager.prefetchedLocalFileURL, expectedURL)
    }

    func testGaplessExistingRemuxPreparesLocalItemWithoutNetwork() throws {
        let cachedSong = makeSong(id: "RemotePolicyCached")
        let expectedURL = try seedCachedSong(cachedSong)
        let manager = GaplessPreFetchManager()
        manager.audioCacheManager = AudioCacheManager()
        manager.queue = [makeSong(id: "RemotePolicyCurrent"), cachedSong]
        manager.currentIndex = 0

        manager.prefetchNextTrack()

        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
        XCTAssertNotNil(manager.prefetchedPlayerItem)
        XCTAssertEqual(manager.prefetchedSongId, cachedSong.id)
        XCTAssertEqual(manager.prefetchedLocalFileURL, expectedURL)
    }

    func testCrossfadeUnresolvedRemoteReturnsTypedLocalMissWithoutResolver() async throws {
        let activeSong = makeSong(id: "RemotePolicyActive")
        try seedDownloadedSong(activeSong)
        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        var resolverCalls = 0
        engine.streamURLResolver = { _ in
            resolverCalls += 1
            return (
                url: "https://remote-prefetch.invalid/resolved.m4a",
                contentLength: 64
            )
        }
        engine.play(song: activeSong, fromQueue: [activeSong])
        let activeIDBefore = engine.currentTrack?.id
        let autoplayBefore = engine.autoplayQueue

        await assertNotLocallyAvailable(
            from: engine,
            for: makeSong(id: "RemotePolicyCrossUnresolved")
        )

        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
        XCTAssertEqual(engine.currentTrack?.id, activeIDBefore)
        XCTAssertEqual(engine.autoplayQueue, autoplayBefore)
    }

    func testCrossfadeResolvedRemoteReturnsTypedLocalMissWithoutTransfer() async {
        let engine = AudioEngine()
        var resolverCalls = 0
        engine.streamURLResolver = { _ in
            resolverCalls += 1
            throw URLError(.notConnectedToInternet)
        }

        await assertNotLocallyAvailable(
            from: engine,
            for: makeSong(
                id: "RemotePolicyCrossResolved",
                streamURL: "https://remote-prefetch.invalid/already-resolved.m4a"
            )
        )

        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
        XCTAssertNil(engine.currentTrack)
    }

    func testCrossfadeExplicitDownloadReturnsLocalItemWithoutResolver() async throws {
        let downloadedSong = makeSong(id: "RemotePolicyCrossLocal")
        let expectedURL = try seedDownloadedSong(downloadedSong)
        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        var resolverCalls = 0
        engine.streamURLResolver = { _ in
            resolverCalls += 1
            throw URLError(.notConnectedToInternet)
        }

        let item = try await engine.prepareCrossfadePlayerItem(for: downloadedSong)

        let asset = try XCTUnwrap(item.asset as? AVURLAsset)
        XCTAssertEqual(asset.url, expectedURL)
        XCTAssertTrue(asset.url.isFileURL)
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
    }

    func testAutoplayCrossfadeLocalMissKeepsCurrentTrackAndQueue() async throws {
        let activeSong = makeSong(id: "RemotePolicyActive")
        try seedDownloadedSong(activeSong)
        let remoteNext = makeSong(
            id: "RemotePolicyAutoplayRemote",
            streamURL: "https://remote-prefetch.invalid/autoplay.m4a"
        )
        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        var resolverCalls = 0
        engine.streamURLResolver = { _ in
            resolverCalls += 1
            throw URLError(.notConnectedToInternet)
        }
        engine.play(song: activeSong, fromQueue: [activeSong])
        engine.setAutoplayQueue([remoteNext])

        let preparation = engine.prepareCrossfadeForAutoplay(nextSong: remoteNext)
        await preparation.value

        XCTAssertEqual(engine.currentTrack?.id, activeSong.id)
        XCTAssertEqual(engine.autoplayQueue.map(\.id), [remoteNext.id])
        XCTAssertFalse(engine.isPlayingFromAutoplay)
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
    }

    func testShuffleRemoteMissReservesOneCandidateAcrossTicksAndNaturalEnd() async throws {
        let candidateA = makeSong(id: "RemotePolicyShuffleA")
        let candidateB = makeSong(id: "RemotePolicyShuffleB")
        let current = makeSong(id: "RemotePolicyShuffleCurrent")
        try seedDownloadedSong(current)

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        var resolverCalls = 0
        engine.streamURLResolver = { _ in
            resolverCalls += 1
            throw URLError(.notConnectedToInternet)
        }
        engine.play(song: current, fromQueue: [candidateA, candidateB, current])
        engine.shuffleEnabled = true

        let firstPreparation = try XCTUnwrap(engine.beginCrossfade())
        await firstPreparation.value

        for _ in 0..<3 {
            let repeatedPreparation = engine.beginCrossfade()
            await repeatedPreparation?.value
            XCTAssertNil(
                repeatedPreparation,
                "Repeated 250 ms trigger opportunities must not re-prepare an unchanged miss"
            )
        }

        try seedDownloadedSongs([current, candidateA, candidateB])
        engine.downloadManager = DownloadManager()

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let lateLocalPreparation = try XCTUnwrap(engine.beginCrossfade())
        await held.waitUntilSuspended()
        let reservedURL = try XCTUnwrap(held.validatedURLs.first)

        engine.handleTrackEnd()
        held.resume()
        await lateLocalPreparation.value

        XCTAssertEqual(reservedURL.lastPathComponent, "\(engine.currentTrack?.id ?? "").m4a")
        XCTAssertEqual(
            engine.currentIndex,
            engine.queue.firstIndex(where: { $0.id == engine.currentTrack?.id })
        )
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
    }

    func testNextInvalidatesHeldCrossfadePreparation() async throws {
        let current = makeSong(id: "RemotePolicyStaleCurrent")
        let next = makeSong(id: "RemotePolicyStaleNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = engine.beginCrossfade()
        await held.waitUntilSuspended()

        engine.next()
        let expectedIndex = engine.currentIndex
        let expectedQueue = engine.queue.map(\.id)
        held.resume()
        await preparation?.value

        XCTAssertEqual(held.validatedURLs.map(\.lastPathComponent), ["\(next.id).m4a"])
        XCTAssertEqual(engine.currentTrack?.id, next.id)
        XCTAssertEqual(engine.currentIndex, expectedIndex)
        XCTAssertEqual(engine.queue.map(\.id), expectedQueue)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
    }

    func testQueueRevisionInvalidatesHeldCrossfadePreparation() async throws {
        let current = makeSong(id: "RemotePolicyStaleCurrent")
        let next = makeSong(id: "RemotePolicyStaleNext")
        let third = makeSong(id: "RemotePolicyStaleThird")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next, third])

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = engine.beginCrossfade()
        await held.waitUntilSuspended()

        engine.moveInQueue(from: IndexSet(integer: 1), to: 3)
        let expectedQueue = engine.queue.map(\.id)
        held.resume()
        await preparation?.value

        XCTAssertEqual(held.validatedURLs.map(\.lastPathComponent), ["\(next.id).m4a"])
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.queue.map(\.id), expectedQueue)
        XCTAssertEqual(expectedQueue, [current.id, third.id, next.id])
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
    }

    func testCrossfadeMissRetriesOnlyAfterLocalAvailabilityChanges() async throws {
        let current = makeSong(id: "RemotePolicyCrossLateCurrent")
        let next = makeSong(id: "RemotePolicyCrossLateNext")
        try seedDownloadedSong(current)

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeLocalPreparationBarrier = nil
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])

        var validatedURLs: [URL] = []
        engine.crossfadeLocalPreparationBarrier = { localFile in
            validatedURLs.append(localFile.url)
        }

        let firstAttempt = try XCTUnwrap(engine.beginCrossfade())
        await firstAttempt.value
        let unchangedAvailabilityAttempt = engine.beginCrossfade()
        await unchangedAvailabilityAttempt?.value

        XCTAssertTrue(validatedURLs.isEmpty)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)

        try seedDownloadedSongs([current, next])
        engine.downloadManager = DownloadManager()
        let lateLocalAttempt = try XCTUnwrap(engine.beginCrossfade())
        await lateLocalAttempt.value

        XCTAssertEqual(validatedURLs.map(\.lastPathComponent), ["\(next.id).m4a"])
        XCTAssertTrue(engine.crossfadeManager.isCrossfading)
        let incomingAsset = try XCTUnwrap(
            engine.crossfadeManager.incomingPlayer?.currentItem?.asset as? AVURLAsset
        )
        XCTAssertTrue(incomingAsset.url.isFileURL)
        XCTAssertEqual(incomingAsset.url.lastPathComponent, "\(next.id).m4a")
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
    }

    func testAutoplayRevisionInvalidatesHeldCrossfadePreparation() async throws {
        let current = makeSong(id: "RemotePolicyStaleCurrent")
        let autoplayNext = makeSong(id: "RemotePolicyStaleNext")
        let replacement = makeSong(id: "RemotePolicyAutoplayReplacement")
        try seedDownloadedSongs([current, autoplayNext])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        engine.play(song: current, fromQueue: [current])
        engine.setAutoplayQueue([autoplayNext])

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = engine.prepareCrossfadeForAutoplay(nextSong: autoplayNext)
        await held.waitUntilSuspended()

        engine.setAutoplayQueue([replacement])
        held.resume()
        await preparation.value

        XCTAssertEqual(held.validatedURLs.map(\.lastPathComponent), ["\(autoplayNext.id).m4a"])
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.autoplayQueue.map(\.id), [replacement.id])
        XCTAssertFalse(engine.isPlayingFromAutoplay)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
    }

    func testSuccessfulLocalAutoplayCrossfadeAdoptsIncomingItemAndConsumesOnce() async throws {
        let current = makeSong(id: "RemotePolicyAutoplaySuccessCurrent")
        let autoplayNext = makeSong(id: "RemotePolicyAutoplaySuccessNext")
        try seedDownloadedSongs([current, autoplayNext])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 0.01
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current])
        engine.setAutoplayQueue([autoplayNext])

        let preparation = engine.prepareCrossfadeForAutoplay(nextSong: autoplayNext)
        await preparation.value
        let incoming = try XCTUnwrap(engine.crossfadeManager.incomingPlayer)
        XCTAssertNotNil(incoming.currentItem)

        for _ in 0..<100 where engine.currentTrack?.id != autoplayNext.id {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(engine.currentTrack?.id, autoplayNext.id)
        XCTAssertEqual(engine.autoplayQueue.map(\.id), [])
        XCTAssertTrue(engine.isPlayingFromAutoplay)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertNotNil(incoming.currentItem, "The adopted incoming player must retain its local item")
        XCTAssertEqual(engine.queue.map(\.id), [current.id])
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testSuccessfulLocalAutoplayCrossfadeConsumesOnlyReservedFrontOccurrence() async throws {
        let current = makeSong(id: "RemotePolicyAutoplayDuplicateCurrent")
        let autoplayNext = makeSong(id: "RemotePolicyAutoplayDuplicateNext")
        let later = makeSong(id: "RemotePolicyAutoplayDuplicateLater")
        try seedDownloadedSongs([current, autoplayNext])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 0.01
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current])
        engine.setAutoplayQueue([autoplayNext, autoplayNext, later])

        let preparation = engine.prepareCrossfadeForAutoplay(nextSong: autoplayNext)
        await preparation.value
        let incoming = try XCTUnwrap(engine.crossfadeManager.incomingPlayer)

        for _ in 0..<100 where engine.currentTrack?.id != autoplayNext.id {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(engine.currentTrack?.id, autoplayNext.id)
        XCTAssertEqual(engine.autoplayQueue.map(\.id), [autoplayNext.id, later.id])
        XCTAssertTrue(engine.isPlayingFromAutoplay)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertNotNil(incoming.currentItem, "The incoming player must be adopted exactly once")
        XCTAssertEqual(engine.queue.map(\.id), [current.id])
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testSingletonShuffleRepeatOffDoesNotSelfCrossfadeAndNaturalEndStops() async throws {
        let current = makeSong(id: "RemotePolicySingletonCurrent")
        try seedDownloadedSong(current)

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current])
        engine.shuffleEnabled = true
        engine.repeatMode = .off

        let preparation = engine.beginCrossfade()
        await preparation?.value

        XCTAssertNil(preparation)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertTrue(engine.isPlaying)

        engine.handleTrackEnd()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testSingletonShuffleRepeatOffSelectsLocalAutoplayInsteadOfCurrent() async throws {
        let current = makeSong(id: "RemotePolicySingletonCurrent")
        let autoplayNext = makeSong(id: "RemotePolicySingletonAutoplay")
        try seedDownloadedSongs([current, autoplayNext])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current])
        engine.setAutoplayQueue([autoplayNext])
        engine.shuffleEnabled = true
        engine.repeatMode = .off

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await held.waitUntilSuspended()

        XCTAssertEqual(held.validatedURLs.map(\.lastPathComponent), ["\(autoplayNext.id).m4a"])
        held.resume()
        await preparation.value

        let asset = try XCTUnwrap(
            engine.crossfadeManager.incomingPlayer?.currentItem?.asset as? AVURLAsset
        )
        XCTAssertEqual(asset.url.lastPathComponent, "\(autoplayNext.id).m4a")
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testSingletonShuffleRepeatAllMayCrossfadeToCurrent() async throws {
        let current = makeSong(id: "RemotePolicySingletonCurrent")
        try seedDownloadedSong(current)

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current])
        engine.shuffleEnabled = true
        engine.repeatMode = .all

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await held.waitUntilSuspended()

        XCTAssertEqual(held.validatedURLs.map(\.lastPathComponent), ["\(current.id).m4a"])
        held.resume()
        await preparation.value

        let asset = try XCTUnwrap(
            engine.crossfadeManager.incomingPlayer?.currentItem?.asset as? AVURLAsset
        )
        XCTAssertEqual(asset.url.lastPathComponent, "\(current.id).m4a")
        XCTAssertTrue(engine.crossfadeManager.isCrossfading)
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testRemoteCrossfadeNeverReachesPostLocalValidationBarrier() async {
        let remote = makeSong(
            id: "RemotePolicyBarrierRemote",
            streamURL: "https://remote-prefetch.invalid/barrier.m4a"
        )
        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()

        var barrierCalls = 0
        engine.crossfadeLocalPreparationBarrier = { _ in
            barrierCalls += 1
        }
        var resolverCalls = 0
        engine.streamURLResolver = { _ in
            resolverCalls += 1
            return (
                url: "https://remote-prefetch.invalid/resolved-barrier.m4a",
                contentLength: 64
            )
        }

        await assertNotLocallyAvailable(from: engine, for: remote)

        XCTAssertEqual(barrierCalls, 0)
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.requestCount, 0)
        XCTAssertEqual(RemotePrefetchBodyURLProtocol.bodyByteCount, 0)
    }

    func testSeekInvalidatesHeldPostLocalValidationPreparation() async throws {
        let current = makeSong(id: "RemotePolicySeekCurrent")
        let next = makeSong(id: "RemotePolicySeekNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await held.waitUntilSuspended()
        let queueBeforeSeek = engine.queue.map(\.id)

        engine.seek(to: 30)
        held.resume()
        await preparation.value

        XCTAssertEqual(held.validatedURLs.map(\.lastPathComponent), ["\(next.id).m4a"])
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.queue.map(\.id), queueBeforeSeek)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
    }

    func testInterruptionBeganCancelsActiveLocalCrossfadeWithoutConsumingQueue() async throws {
        let current = makeSong(id: "RemotePolicySystemCurrent")
        let next = makeSong(id: "RemotePolicySystemNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await preparation.value
        let outgoing = try XCTUnwrap(engine.crossfadeManager.outgoingPlayer)
        let incoming = try XCTUnwrap(engine.crossfadeManager.incomingPlayer)
        XCTAssertTrue(engine.crossfadeManager.isCrossfading)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.outgoingPlayer)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertNil(incoming.currentItem)
        XCTAssertEqual(outgoing.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.queue.map(\.id), [current.id, next.id])
        XCTAssertFalse(engine.isPlaying)
    }

    func testOldDeviceUnavailableCancelsActiveLocalCrossfadeWithoutConsumingQueue() async throws {
        let current = makeSong(id: "RemotePolicySystemCurrent")
        let next = makeSong(id: "RemotePolicySystemNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await preparation.value
        let outgoing = try XCTUnwrap(engine.crossfadeManager.outgoingPlayer)
        let incoming = try XCTUnwrap(engine.crossfadeManager.incomingPlayer)
        XCTAssertTrue(engine.crossfadeManager.isCrossfading)

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )

        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.outgoingPlayer)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertNil(incoming.currentItem)
        XCTAssertEqual(outgoing.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.queue.map(\.id), [current.id, next.id])
        XCTAssertFalse(engine.isPlaying)
    }

    func testSeekBackResetsTriggerAndRetriesSameEligibleLocalCrossfade() async throws {
        let current = makeSong(id: "RemotePolicySeekCurrent")
        let next = makeSong(id: "RemotePolicySeekNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])
        let firstPreparation = try XCTUnwrap(engine.beginCrossfade())
        await firstPreparation.value
        let firstIncoming = try XCTUnwrap(engine.crossfadeManager.incomingPlayer)
        XCTAssertTrue(engine.crossfadeManager.isCrossfading)

        engine.seek(to: 0)

        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(firstIncoming.currentItem)
        XCTAssertTrue(
            engine.crossfadeManager.shouldTrigger(
                currentTime: 170,
                duration: 180,
                repeatMode: .off
            )
        )

        let retryPreparation = try XCTUnwrap(engine.beginCrossfade())
        await retryPreparation.value

        XCTAssertTrue(engine.crossfadeManager.isCrossfading)
        let retryAsset = try XCTUnwrap(
            engine.crossfadeManager.incomingPlayer?.currentItem?.asset as? AVURLAsset
        )
        XCTAssertEqual(retryAsset.url.lastPathComponent, "\(next.id).m4a")
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testShufflePolicyChangeInvalidatesHeldSequentialResultAndUsesNewReservation() async throws {
        let current = makeSong(id: "RemotePolicyPolicyCurrent")
        let next = makeSong(id: "RemotePolicyPolicyNext")
        let third = makeSong(id: "RemotePolicyPolicyThird")
        try seedDownloadedSongs([current, next, third])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next, third])

        let oldPolicyBarrier = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = oldPolicyBarrier.suspend
        let oldPolicyPreparation = try XCTUnwrap(engine.beginCrossfade())
        await oldPolicyBarrier.waitUntilSuspended()

        engine.shuffleEnabled = true
        oldPolicyBarrier.resume()
        await oldPolicyPreparation.value

        XCTAssertEqual(
            oldPolicyBarrier.validatedURLs.map(\.lastPathComponent),
            ["\(next.id).m4a"]
        )
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)

        let newPolicyBarrier = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = newPolicyBarrier.suspend
        let newPolicyPreparation = try XCTUnwrap(engine.beginCrossfade())
        await newPolicyBarrier.waitUntilSuspended()
        let reservedURL = try XCTUnwrap(newPolicyBarrier.validatedURLs.first)

        engine.handleTrackEnd()
        newPolicyBarrier.resume()
        await newPolicyPreparation.value

        XCTAssertNotEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(reservedURL.lastPathComponent, "\(engine.currentTrack?.id ?? "").m4a")
        XCTAssertEqual(
            engine.currentIndex,
            engine.queue.firstIndex(where: { $0.id == engine.currentTrack?.id })
        )
        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
    }

    func testRepeatOffToOneInvalidatesHeldResultAndRepeatsCurrentTrack() async throws {
        try await assertRepeatOneInvalidatesHeldResult(initialMode: .off)
    }

    func testRepeatAllToOneInvalidatesHeldResultAndRepeatsCurrentTrack() async throws {
        try await assertRepeatOneInvalidatesHeldResult(initialMode: .all)
    }

    func testShufflePolicyChangeCancelsActiveFadeAndRestoresOutgoingPlayer() async throws {
        let current = makeSong(id: "RemotePolicyPolicyCurrent")
        let next = makeSong(id: "RemotePolicyPolicyNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await preparation.value
        let outgoing = try XCTUnwrap(engine.crossfadeManager.outgoingPlayer)
        let incoming = try XCTUnwrap(engine.crossfadeManager.incomingPlayer)

        engine.shuffleEnabled = true

        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.outgoingPlayer)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertNil(incoming.currentItem)
        XCTAssertEqual(outgoing.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testRepeatPolicyChangeCancelsActiveFadeAndRestoresOutgoingPlayer() async throws {
        let current = makeSong(id: "RemotePolicyPolicyCurrent")
        let next = makeSong(id: "RemotePolicyPolicyNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await preparation.value
        let outgoing = try XCTUnwrap(engine.crossfadeManager.outgoingPlayer)
        let incoming = try XCTUnwrap(engine.crossfadeManager.incomingPlayer)

        engine.repeatMode = .one

        XCTAssertFalse(engine.crossfadeManager.isCrossfading)
        XCTAssertNil(engine.crossfadeManager.outgoingPlayer)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer)
        XCTAssertNil(incoming.currentItem)
        XCTAssertEqual(outgoing.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testUnchangedPlaybackPolicyDoesNotInvalidateHeldLocalPreparation() async throws {
        let current = makeSong(id: "RemotePolicyUnchangedCurrent")
        let next = makeSong(id: "RemotePolicyUnchangedNext")
        try seedDownloadedSongs([current, next])

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.play(song: current, fromQueue: [current, next])

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = try XCTUnwrap(engine.beginCrossfade())
        await held.waitUntilSuspended()

        engine.shuffleEnabled = false
        engine.repeatMode = .off
        held.resume()
        await preparation.value

        XCTAssertTrue(engine.crossfadeManager.isCrossfading)
        let asset = try XCTUnwrap(
            engine.crossfadeManager.incomingPlayer?.currentItem?.asset as? AVURLAsset
        )
        XCTAssertTrue(asset.url.isFileURL)
        XCTAssertEqual(asset.url.lastPathComponent, "\(next.id).m4a")
        XCTAssertEqual(engine.currentTrack?.id, current.id)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    private func assertRepeatOneInvalidatesHeldResult(
        initialMode: AudioEngine.RepeatMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let first = makeSong(id: "RemotePolicyRepeatFirst")
        let current = makeSong(id: "RemotePolicyRepeatCurrent")
        let queue: [Song]
        switch initialMode {
        case .all:
            queue = [first, current]
        case .off:
            queue = [current, first]
        case .one:
            XCTFail("The helper requires a policy transition into repeat-one", file: file, line: line)
            return
        }
        try seedDownloadedSongs(queue)

        let engine = AudioEngine()
        engine.downloadManager = DownloadManager()
        let originalCrossfadeDuration = engine.crossfadeManager.crossfadeDuration
        engine.crossfadeManager.crossfadeDuration = 30
        defer {
            engine.crossfadeManager.cancelFade()
            engine.crossfadeManager.crossfadeDuration = originalCrossfadeDuration
        }
        engine.repeatMode = initialMode
        engine.play(song: current, fromQueue: queue)

        let held = HeldCrossfadeLocalValidationBarrier()
        engine.crossfadeLocalPreparationBarrier = held.suspend
        let preparation = try XCTUnwrap(engine.beginCrossfade(), file: file, line: line)
        await held.waitUntilSuspended(file: file, line: line)

        engine.repeatMode = .one
        held.resume()
        await preparation.value

        XCTAssertEqual(
            held.validatedURLs.map(\.lastPathComponent),
            ["\(first.id).m4a"],
            file: file,
            line: line
        )
        XCTAssertEqual(engine.currentTrack?.id, current.id, file: file, line: line)
        XCTAssertFalse(engine.crossfadeManager.isCrossfading, file: file, line: line)
        XCTAssertNil(engine.crossfadeManager.incomingPlayer, file: file, line: line)

        engine.handleTrackEnd()

        XCTAssertEqual(engine.currentTrack?.id, current.id, file: file, line: line)
        XCTAssertEqual(
            engine.currentIndex,
            queue.firstIndex(where: { $0.id == current.id }),
            file: file,
            line: line
        )
        XCTAssertEqual(engine.queue.map(\.id), queue.map(\.id), file: file, line: line)
    }
}
