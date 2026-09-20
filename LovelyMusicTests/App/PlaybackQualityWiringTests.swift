import Foundation
import os
import XCTest

@testable import LovelyMusic

@MainActor
final class PlaybackQualityWiringTests: XCTestCase {
    func testPlaybackResolverUsesEffectiveQualityForEveryNetworkClass() async throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)
        let repository = PlaybackQualityRecordingRepository()
        let useCase = ResolveStreamUseCase(repository: repository)
        let network = PlaybackNetworkSnapshotFixture(
            .wifi(expensive: false, constrained: false)
        )
        let resolver = PlaybackQualityWiring.makePlaybackResolver(
            useCase: useCase,
            settings: settings,
            networkSnapshot: { await network.current() },
            isPremium: { true },
            requestHeaders: ["User-Agent": "LovelyMusic-Test"]
        )

        _ = try await resolver("wifi")
        await network.set(.cellular(constrained: false))
        _ = try await resolver("cellular")
        await network.set(.wifi(expensive: false, constrained: true))
        _ = try await resolver("constrained")
        await network.set(.wifi(expensive: true, constrained: false))
        _ = try await resolver("expensive-wifi")

        let wifiQuality = await repository.quality(for: "wifi")
        let cellularQuality = await repository.quality(for: "cellular")
        let constrainedQuality = await repository.quality(for: "constrained")
        let expensiveWiFiQuality = await repository.quality(for: "expensive-wifi")
        let legacyCallCount = await repository.legacyCallCount
        XCTAssertEqual(wifiQuality, .high)
        XCTAssertEqual(cellularQuality, .medium)
        XCTAssertEqual(constrainedQuality, .low)
        XCTAssertEqual(expensiveWiFiQuality, .low)
        XCTAssertEqual(legacyCallCount, 0)
    }

    func testFreeTierCapOccursAtResolutionWithoutOverwritingIntent() async throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)
        settings.wifi = .high
        let repository = PlaybackQualityRecordingRepository()
        let resolver = PlaybackQualityWiring.makePlaybackResolver(
            useCase: ResolveStreamUseCase(repository: repository),
            settings: settings,
            networkSnapshot: { .wifi(expensive: false, constrained: false) },
            isPremium: { false }
        )

        _ = try await resolver("free-wifi")

        let resolvedQuality = await repository.quality(for: "free-wifi")
        XCTAssertEqual(resolvedQuality, .medium)
        XCTAssertEqual(settings.wifi, .high)
        XCTAssertEqual(fixture.defaults.string(forKey: "audioQualityWiFiV1"), "high")
    }

    func testActualDownloadManagerQueueKeepsCapturedDownloadIntentAcrossChanges() async throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)
        settings.wifi = .low
        settings.cellular = .low
        settings.constrained = .low
        settings.download = .high
        let queuedRecorded = expectation(description: "queued resolver recorded explicit quality")
        let recordedQuality = OSAllocatedUnfairLock<AudioQuality?>(initialState: nil)
        let repository = QueuedDownloadQualityRepository { videoID, quality in
            guard videoID == "quality-queued" else { return }
            recordedQuality.withLock { $0 = quality }
            queuedRecorded.fulfill()
        }
        let useCase = ResolveStreamUseCase(repository: repository)
        let manager = DownloadManager()
        let entitlement = PlaybackPremiumFixture(isPremium: false)
        let network = PlaybackNetworkSnapshotFixture(
            .wifi(expensive: false, constrained: false)
        )
        PlaybackQualityWiring.installExplicitDownloadResolverFactory(
            on: manager,
            useCase: useCase,
            settings: settings,
            isPremium: { entitlement.isPremium }
        )
        defer {
            manager.cancelDownload(songId: "quality-active-1")
            manager.cancelDownload(songId: "quality-active-2")
            manager.cancelDownload(songId: "quality-queued")
        }

        manager.downloadSong(makeSong(id: "quality-active-1"))
        manager.downloadSong(makeSong(id: "quality-active-2"))
        manager.downloadSong(makeSong(id: "quality-queued"))
        XCTAssertEqual(manager.downloadState(for: "quality-queued"), .queued)

        // The factory created this pending resolver and froze effective quality
        // synchronously at enqueue. Later state only affects future enqueues.
        await network.set(.cellular(constrained: false))
        let cellularSnapshot = await network.current()
        XCTAssertEqual(
            settings.effectiveStreamingQuality(
                for: cellularSnapshot,
                isPremium: true
            ),
            .low
        )
        entitlement.isPremium = true
        settings.download = .low
        await network.set(.wifi(expensive: true, constrained: false))
        manager.cancelDownload(songId: "quality-active-1")

        await fulfillment(of: [queuedRecorded], timeout: 2)
        let legacyCallCount = await repository.legacyCallCount
        XCTAssertEqual(recordedQuality.withLock { $0 }, .medium)
        XCTAssertEqual(legacyCallCount, 0)
    }

    func testExplicitDownloadQualityDoesNotInheritStreamingNetwork() async throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)
        settings.wifi = .low
        settings.cellular = .low
        settings.constrained = .low
        settings.download = .high
        let repository = PlaybackQualityRecordingRepository()
        let useCase = ResolveStreamUseCase(repository: repository)
        let resolver = PlaybackQualityWiring.makeExplicitDownloadResolver(
            useCase: useCase,
            capturedEffectiveQuality: settings.effectiveDownloadQuality(isPremium: true)
        )

        _ = try await resolver("explicit-download")

        let resolvedQuality = await repository.quality(for: "explicit-download")
        let legacyCallCount = await repository.legacyCallCount
        XCTAssertEqual(resolvedQuality, .high)
        XCTAssertEqual(legacyCallCount, 0)
    }

    func testLegacyNoQualityUseCaseRemainsSourceCompatibleButDeprecatedPathIsNotWired() async throws {
        let repository = PlaybackQualityRecordingRepository()
        let useCase = ResolveStreamUseCase(repository: repository)

        _ = try await useCase.execute(videoId: "legacy-source-compatibility")

        let legacyCallCount = await repository.legacyCallCount
        XCTAssertEqual(legacyCallCount, 1)
    }

    func testExplicitQualityUseCasePreservesTypedDemoLocalResourceFallback() async throws {
        let repository = PlaybackLocalFallbackRepository(
            descriptorError: .localResourceIsNotRemoteRangeEligible
        )
        let useCase = ResolveStreamUseCase(repository: repository)

        let result = try await useCase.execute(
            videoId: "demo-bundled-track",
            quality: .high,
            requestHeaders: ["User-Agent": "LovelyMusic-Test"]
        )

        let descriptorQualities = await repository.descriptorQualities
        let descriptorHeaders = await repository.descriptorHeaders
        let legacyCallCount = await repository.legacyCallCount
        XCTAssertEqual(result.url, "file:///demo-bundled-track.m4a")
        XCTAssertNil(result.contentLength)
        XCTAssertEqual(descriptorQualities, [.high])
        XCTAssertEqual(descriptorHeaders, [["User-Agent": "LovelyMusic-Test"]])
        XCTAssertEqual(legacyCallCount, 1)
    }

    func testExplicitQualityUseCaseResolvesPackagedReviewModeTrack() async throws {
        let useCase = ResolveStreamUseCase(repository: DemoPlayerRepository())

        let result = try await useCase.execute(
            videoId: "demo_song_aurora",
            quality: .high,
            requestHeaders: ["User-Agent": "LovelyMusic-Test"]
        )

        let url = try XCTUnwrap(URL(string: result.url))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.lastPathComponent, "demo_song_aurora.m4a")
        XCTAssertNil(result.contentLength)
    }

    func testExplicitQualityUseCaseDoesNotFallbackForOtherDescriptorFailures() async {
        let repository = PlaybackLocalFallbackRepository(
            descriptorError: .descriptorResolutionUnsupported
        )
        let useCase = ResolveStreamUseCase(repository: repository)

        do {
            _ = try await useCase.execute(videoId: "unsupported", quality: .medium)
            XCTFail("Expected the non-local descriptor failure to propagate")
        } catch {
            XCTAssertEqual(error as? StreamDescriptorError, .descriptorResolutionUnsupported)
        }

        let legacyCallCount = await repository.legacyCallCount
        XCTAssertEqual(legacyCallCount, 0)
    }

    func testDIContainerInstallsOnlyExplicitQualityPlaybackAndDownloadResolvers() throws {
        let source = try sourceText(relativePath: "LovelyMusic/App/DIContainer.swift")

        XCTAssertTrue(source.contains("PlaybackQualityWiring.makePlaybackResolver"))
        XCTAssertTrue(
            source.contains("PlaybackQualityWiring.installExplicitDownloadResolverFactory")
        )
        XCTAssertFalse(source.contains("resolveStreamUseCase.execute(videoId: videoId)"))
    }

    func testPlayerRepositoryHasNoAmbientGlobalQualityOrPremiumRead() throws {
        let source = try sourceText(
            relativePath: "LovelyMusic/Data/Repositories/PlayerRepository.swift"
        )

        XCTAssertFalse(source.contains("UserDefaults"))
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PlaybackQualityWiringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return (defaults, suiteName)
    }

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: "Quality Test \(id)",
            artistName: "Test Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
    }

    private func sourceText(relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private actor PlaybackNetworkSnapshotFixture {
    private var snapshot: NetworkSnapshot

    init(_ snapshot: NetworkSnapshot) {
        self.snapshot = snapshot
    }

    func current() -> NetworkSnapshot { snapshot }
    func set(_ snapshot: NetworkSnapshot) { self.snapshot = snapshot }
}

@MainActor
private final class PlaybackPremiumFixture {
    var isPremium: Bool

    init(isPremium: Bool) {
        self.isPremium = isPremium
    }
}

private actor PlaybackQualityRecordingRepository: PlayerRepositoryProtocol {
    private var qualities: [String: AudioQuality] = [:]
    private(set) var legacyCallCount = 0

    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        qualities[videoId] = quality
        return qualityDescriptor(videoID: videoId, headers: requestHeaders)
    }

    func resolveStreamURL(videoId: String) async throws -> (
        url: String,
        contentLength: Int64?
    ) {
        legacyCallCount += 1
        return ("https://legacy.example.test/\(videoId)", 10)
    }

    func resolveVideoStreamURL(videoId: String) async throws -> (
        url: String,
        contentLength: Int64?
    )? {
        nil
    }

    func quality(for videoID: String) -> AudioQuality? { qualities[videoID] }
}

private actor QueuedDownloadQualityRepository: PlayerRepositoryProtocol {
    enum Stop: Error { case afterRecording }

    private var qualities: [String: AudioQuality] = [:]
    private let activeResolutionGate = PlaybackQualityCancellationGate()
    private let didRecord: @Sendable (String, AudioQuality) -> Void
    private(set) var legacyCallCount = 0

    init(didRecord: @escaping @Sendable (String, AudioQuality) -> Void) {
        self.didRecord = didRecord
    }

    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        if videoId.hasPrefix("quality-active") {
            try await activeResolutionGate.wait(id: videoId)
        }

        qualities[videoId] = quality
        didRecord(videoId, quality)
        throw Stop.afterRecording
    }

    func resolveStreamURL(videoId: String) async throws -> (
        url: String,
        contentLength: Int64?
    ) {
        legacyCallCount += 1
        throw Stop.afterRecording
    }

    func resolveVideoStreamURL(videoId: String) async throws -> (
        url: String,
        contentLength: Int64?
    )? {
        nil
    }

}

private actor PlaybackLocalFallbackRepository: PlayerRepositoryProtocol {
    let descriptorError: StreamDescriptorError
    private(set) var descriptorQualities: [AudioQuality] = []
    private(set) var descriptorHeaders: [[String: String]] = []
    private(set) var legacyCallCount = 0

    init(descriptorError: StreamDescriptorError) {
        self.descriptorError = descriptorError
    }

    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        descriptorQualities.append(quality)
        descriptorHeaders.append(requestHeaders)
        throw descriptorError
    }

    func resolveStreamURL(videoId: String) async throws -> (
        url: String,
        contentLength: Int64?
    ) {
        legacyCallCount += 1
        return ("file:///\(videoId).m4a", nil)
    }

    func resolveVideoStreamURL(videoId: String) async throws -> (
        url: String,
        contentLength: Int64?
    )? {
        nil
    }
}

private final class PlaybackQualityCancellationGate: Sendable {
    private struct State {
        var cancelled: Set<String> = []
        var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait(id: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeCancelled = state.withLock { state -> Bool in
                    if state.cancelled.remove(id) != nil { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    private func cancel(id: String) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
            state.cancelled.insert(id)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private func qualityDescriptor(
    videoID: String,
    headers: [String: String]
) -> StreamDescriptor {
    StreamDescriptor(
        videoID: videoID,
        remoteURL: URL(string: "https://audio.example.test/\(videoID)")!,
        itag: 140,
        mimeType: "audio/mp4",
        codec: "mp4a.40.2",
        bitrate: 128_000,
        contentLength: 10,
        duration: .seconds(1),
        initializationRange: 0..<2,
        indexRange: 2..<4,
        expiresAt: nil,
        requestHeaders: headers,
        provisionalResourceKey: ProvisionalResourceKey(
            videoID: videoID,
            itag: 140,
            codec: "mp4a.40.2",
            declaredTotalLength: 10
        )
    )
}
