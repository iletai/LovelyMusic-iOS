import XCTest

@testable import LovelyMusic

/// Verifies T1 of `doc/exec-plans/active/2026-05-04-video-load-race.md`:
/// `PlayerRepository` coalesces concurrent callers for the same `videoId` onto
/// a single underlying `InnerTubeAPI` round-trip, evicts on completion, and
/// keeps audio and video caches independent.
final class PlayerRepositorySingleFlightTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal player JSON body that `PlayerRepository.extractStreamURL`
    /// (audio path) decodes to a valid result. The audio path requires a
    /// playable `audio/mp4` adaptive format.
    private func audioPlayerJSON(url: String, contentLength: String = "12345") -> Data {
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "adaptiveFormats": [
                    [
                        "itag": 140,
                        "url": url,
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "bitrate": 128000,
                        "contentLength": contentLength,
                    ]
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func audioPlayerJSON(
        initializationRange: [String: String],
        indexRange: [String: String]
    ) -> Data {
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "adaptiveFormats": [
                    [
                        "itag": 140,
                        "url": "https://cdn.example/malformed-range.mp4",
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "bitrate": 128_000,
                        "contentLength": "4000000",
                        "initRange": initializationRange,
                        "indexRange": indexRange,
                    ]
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func descriptorAudioPlayerJSON(
        mutatingFormat: ((inout [String: Any]) -> Void)? = nil
    ) -> Data {
        var format = descriptorAudioFormat()
        mutatingFormat?(&format)
        return descriptorAudioPlayerJSON(formats: [format])
    }

    private func descriptorAudioFormat(
        url: String = "https://cdn.example/descriptor.mp4",
        mimeType: String = "audio/mp4; codecs=\"mp4a.40.2\"",
        bitrate: Int = 128_000
    ) -> [String: Any] {
        [
            "itag": 140,
            "url": url,
            "mimeType": mimeType,
            "bitrate": bitrate,
            "contentLength": "4000000",
            "approxDurationMs": "245678",
            "initRange": ["start": "0", "end": "699"],
            "indexRange": ["start": "700", "end": "1199"],
        ]
    }

    private func descriptorAudioPlayerJSON(formats: [[String: Any]]) -> Data {
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["adaptiveFormats": formats],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// Build a minimal player JSON body that `extractVideoStreamURL` decodes
    /// to a valid muxed-format result.
    private func videoPlayerJSON(url: String) -> Data {
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "hlsManifestUrl": url,
                "formats": [
                    [
                        "itag": 18,
                        "url": url,
                        "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                        "bitrate": 500_000,
                        "width": 640,
                        "height": 360,
                        "contentLength": "98765",
                    ]
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func repository(
        api: MockPlayerAPI,
        audioJoinProbe: InflightJoinProbe? = nil,
        videoJoinProbe: InflightJoinProbe? = nil
    ) -> PlayerRepository {
        PlayerRepository(
            api: api,
            audioInflightDidJoin: audioJoinProbe.map { probe -> InflightJoinObserver in
                { @Sendable in probe.recordJoin() }
            },
            videoInflightDidJoin: videoJoinProbe.map { probe -> InflightJoinObserver in
                { @Sendable in probe.recordJoin() }
            }
        )
    }

    // MARK: - Test 1: 10 concurrent video resolves coalesce to 1 underlying call

    func testVideoResolveCoalescesConcurrentCallers() async throws {
        let mock = MockPlayerAPI()
        let videoData = videoPlayerJSON(url: "https://cdn.example/video.mp4")
        await mock.setHandler { _, _ in videoData }
        await mock.setSuspendOnPlayer(true)

        let videoJoins = InflightJoinProbe()
        let repo = repository(api: mock, videoJoinProbe: videoJoins)

        async let r1 = repo.resolveVideoStreamURL(videoId: "X")
        async let r2 = repo.resolveVideoStreamURL(videoId: "X")
        async let r3 = repo.resolveVideoStreamURL(videoId: "X")
        async let r4 = repo.resolveVideoStreamURL(videoId: "X")
        async let r5 = repo.resolveVideoStreamURL(videoId: "X")
        async let r6 = repo.resolveVideoStreamURL(videoId: "X")
        async let r7 = repo.resolveVideoStreamURL(videoId: "X")
        async let r8 = repo.resolveVideoStreamURL(videoId: "X")
        async let r9 = repo.resolveVideoStreamURL(videoId: "X")
        async let r10 = repo.resolveVideoStreamURL(videoId: "X")

        // Wait until every caller has joined the in-flight entry, then verify
        // that the single underlying call is actually parked in the fake.
        try await videoJoins.waitForCount(10)
        try await mock.waitForPlayerCallCount(1)
        await mock.releaseAll()

        let results = try await [r1, r2, r3, r4, r5, r6, r7, r8, r9, r10]
        let playerCalls = await mock.playerCallCount
        XCTAssertEqual(playerCalls, 1, "Expected exactly one underlying API round-trip")
        for r in results {
            XCTAssertEqual(r?.url, "https://cdn.example/video.mp4")
        }
    }

    // MARK: - Test 2: cache evicts on completion (next call hits the API again)

    func testVideoResolveEvictsAfterCompletion() async throws {
        let mock = MockPlayerAPI()
        let videoData = videoPlayerJSON(url: "https://cdn.example/v.mp4")
        await mock.setHandler { _, _ in videoData }

        let repo = PlayerRepository(api: mock)
        _ = try await repo.resolveVideoStreamURL(videoId: "Y")
        _ = try await repo.resolveVideoStreamURL(videoId: "Y")

        let calls = await mock.playerCallCount
        XCTAssertEqual(calls, 2, "Cache must be evicted after completion")
    }

    // MARK: - Test 3: thrown error evicts entry; retry produces a fresh call

    func testVideoResolveEvictsAfterError() async throws {
        let mock = MockPlayerAPI()
        await mock.setHandler { _, _ in throw URLError(.notConnectedToInternet) }
        await mock.setSuspendOnPlayer(true)

        let videoJoins = InflightJoinProbe()
        let repo = repository(api: mock, videoJoinProbe: videoJoins)

        async let a: (url: String, contentLength: Int64?)? = repo.resolveVideoStreamURL(
            videoId: "Z")
        async let b: (url: String, contentLength: Int64?)? = repo.resolveVideoStreamURL(
            videoId: "Z")

        try await videoJoins.waitForCount(2)
        try await mock.waitForPlayerCallCount(1)
        await mock.releaseAll()

        var errorsSeen = 0
        do { _ = try await a } catch { errorsSeen += 1 }
        do { _ = try await b } catch { errorsSeen += 1 }
        XCTAssertEqual(errorsSeen, 2, "Both concurrent callers must receive the error")

        let firstWaveCalls = await mock.playerCallCount
        XCTAssertEqual(firstWaveCalls, 1, "First wave should coalesce to one underlying call")

        // Third sequential call must produce a fresh underlying call.
        await mock.setHandler { _, _ in throw URLError(.notConnectedToInternet) }
        await mock.setSuspendOnPlayer(false)
        do {
            _ = try await repo.resolveVideoStreamURL(videoId: "Z")
            XCTFail("Expected error")
        } catch {
            // expected
        }
        let total = await mock.playerCallCount
        XCTAssertEqual(total, 2, "Errored entry must be evicted; sequential retry hits API again")
    }

    // MARK: - Test 4: audio path coalescing

    func testAudioResolveCoalescesConcurrentCallers() async throws {
        let mock = MockPlayerAPI()
        let audioData = audioPlayerJSON(url: "https://cdn.example/audio.mp4")
        await mock.setHandler { _, _ in audioData }
        await mock.setSuspendSessionOnly(true)

        let audioJoins = InflightJoinProbe()
        let repo = repository(api: mock, audioJoinProbe: audioJoins)
        var tasks: [Task<(url: String, contentLength: Int64?), Error>] = []
        for _ in 0..<10 {
            tasks.append(Task { try await repo.resolveStreamURL(videoId: "A") })
        }
        try await audioJoins.waitForCount(10)
        try await mock.waitForSessionCallCount(1)
        await mock.releaseAll()

        for t in tasks {
            let result = try await t.value
            XCTAssertEqual(result.url, "https://cdn.example/audio.mp4")
        }

        // ANDROID_VR(session) succeeds first try, so only that path is hit once.
        let sessionCalls = await mock.playerWithSessionCallCount
        XCTAssertEqual(sessionCalls, 1, "Audio path must coalesce to one underlying call")
    }

    // MARK: - Test 5: audio + video for same id use independent caches

    func testAudioAndVideoCachesAreIndependent() async throws {
        let mock = MockPlayerAPI()
        let audioData = audioPlayerJSON(url: "https://cdn.example/audio.mp4")
        let videoData = videoPlayerJSON(url: "https://cdn.example/video.mp4")
        await mock.setHandler { kind, _ in
            switch kind {
            case .session:
                return audioData
            case .player:
                return videoData
            }
        }
        await mock.setSuspendPlayerOnly(true)
        await mock.setSuspendSessionOnly(true)

        let audioJoins = InflightJoinProbe()
        let videoJoins = InflightJoinProbe()
        let repo = repository(
            api: mock,
            audioJoinProbe: audioJoins,
            videoJoinProbe: videoJoins
        )

        async let audio = repo.resolveStreamURL(videoId: "DUAL")
        async let video = repo.resolveVideoStreamURL(videoId: "DUAL")

        try await audioJoins.waitForCount(1)
        try await videoJoins.waitForCount(1)
        try await mock.waitForSessionCallCount(1)
        try await mock.waitForPlayerCallCount(1)
        await mock.releaseAll()

        let audioResult = try await audio
        let videoResult = try await video

        XCTAssertEqual(audioResult.url, "https://cdn.example/audio.mp4")
        XCTAssertEqual(videoResult?.url, "https://cdn.example/video.mp4")

        let session = await mock.playerWithSessionCallCount
        let player = await mock.playerCallCount
        XCTAssertEqual(session, 1, "Audio cache hit once")
        XCTAssertEqual(player, 1, "Video cache hit once")
    }

    // MARK: - Test 6 (AG2/CX2): cache independence under contention
    //
    // Hold the video path indefinitely; the audio path must complete on its
    // own. Proves the audio and video caches are NOT keyed by `videoId`
    // alone — they are independent and non-blocking.

    func testAudioCompletesWhileVideoForSameIdIsHeldIndefinitely() async throws {
        let mock = MockPlayerAPI()
        let audioData = audioPlayerJSON(url: "https://cdn.example/audio.mp4")
        let videoData = videoPlayerJSON(url: "https://cdn.example/video.mp4")
        await mock.setHandler { kind, _ in
            switch kind {
            case .session:
                return audioData
            case .player:
                return videoData
            }
        }
        // Suspend ONLY the video path. Audio must flow through unblocked.
        await mock.setSuspendPlayerOnly(true)

        let videoJoins = InflightJoinProbe()
        let repo = repository(api: mock, videoJoinProbe: videoJoins)

        // Kick off a video resolve that will block on the suspended player.
        let videoTask = Task {
            try await repo.resolveVideoStreamURL(videoId: "DUAL")
        }

        // Wait for video to park before initiating audio
        try await videoJoins.waitForCount(1)
        try await mock.waitForPlayerCallCount(1)

        // Audio must complete without ever touching the video path's latch.
        let audioResult = try await repo.resolveStreamURL(videoId: "DUAL")
        XCTAssertEqual(audioResult.url, "https://cdn.example/audio.mp4")

        XCTAssertFalse(
            videoTask.isCancelled,
            "Video task must not be cancelled by audio completion"
        )
        let playerCountWhileVideoHeld = await mock.playerCallCount
        XCTAssertEqual(
            playerCountWhileVideoHeld, 1,
            "Video path must still be in flight (called once, not yet returned)"
        )

        // Cleanup: release video path so the task can finish.
        await mock.setSuspendPlayerOnly(false)
        _ = try await videoTask.value

        let session = await mock.playerWithSessionCallCount
        let player = await mock.playerCallCount
        XCTAssertEqual(session, 1, "Audio resolved exactly once")
        XCTAssertEqual(player, 1, "Video resolved exactly once")
    }

    // MARK: - Test 7 (AG1/CX3): caller cancellation does NOT propagate to peer
    //
    // Caller A is wrapped in a cancellable Task and cancelled mid-flight.
    // Caller B (started before the cancel) must still receive the value, and
    // the underlying API must be hit exactly once.

    func testCallerCancellationDoesNotPropagateToPeer() async throws {
        let mock = MockPlayerAPI()
        let videoData = videoPlayerJSON(url: "https://cdn.example/video.mp4")
        await mock.setHandler { _, _ in videoData }
        await mock.setSuspendPlayerOnly(true)

        let videoJoins = InflightJoinProbe()
        let repo = repository(api: mock, videoJoinProbe: videoJoins)

        // Caller A — cancellable, awaits the shared task. We capture
        // cancellation observed inside A's body via `withTaskCancellationHandler`
        // so we can assert it *causally* (rather than relying on `Task.value`
        // to propagate awaiter cancellation, which it does not).
        let aCancelObserved = AtomicFlag()
        let aTask = Task<(url: String, contentLength: Int64?)?, Error> {
            try await withTaskCancellationHandler {
                try await repo.resolveVideoStreamURL(videoId: "X")
            } onCancel: {
                aCancelObserved.set()
            }
        }

        // Caller B — peer, also awaits the shared task.
        async let bResult = repo.resolveVideoStreamURL(videoId: "X")

        // Wait until both callers joined the shared entry before cancellation.
        try await videoJoins.waitForCount(2)
        try await mock.waitForPlayerCallCount(1)

        // Cancel A while the underlying call is still suspended.
        aTask.cancel()

        // Now release the underlying call.
        await mock.setSuspendPlayerOnly(false)

        // A's body will return the value (since `Task.value` does not
        // propagate awaiter cancellation), but A's outer task IS cancelled.
        _ = try await aTask.value
        XCTAssertTrue(
            aCancelObserved.get(),
            "Caller A's cancellation handler must have fired"
        )
        XCTAssertTrue(
            aTask.isCancelled,
            "Caller A's task must be in cancelled state"
        )

        // B must succeed regardless of A's cancellation — proves insulation.
        let bValue = try await bResult
        XCTAssertEqual(bValue?.url, "https://cdn.example/video.mp4")

        let player = await mock.playerCallCount
        XCTAssertEqual(player, 1, "Underlying API must be called exactly once")
    }

    func testSharedInflightCacheRejectsSameKeyRecursiveReentryAndEvicts() {
        let cache = InflightCache<String, Int>()
        let completed = expectation(description: "recursive reentry is rejected")
        let outcome = LockedBox<InflightReentryOutcome>()

        let task = Task {
            var rejectedRecursiveReentry = false
            do {
                _ = try await cache.run("same-key") {
                    try await cache.run("same-key") { 99 }
                }
            } catch InflightCacheError.recursiveReentry {
                rejectedRecursiveReentry = true
            } catch {
                // The assertions below retain the unexpected-error signal.
            }

            let inflightCountAfterError = await cache.inflightCount
            let retryValue = try? await cache.run("same-key") { 42 }
            outcome.set(
                InflightReentryOutcome(
                    rejectedRecursiveReentry: rejectedRecursiveReentry,
                    inflightCountAfterError: inflightCountAfterError,
                    retryValue: retryValue
                )
            )
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        guard let result = outcome.get() else {
            task.cancel()
            return
        }
        XCTAssertTrue(result.rejectedRecursiveReentry)
        XCTAssertEqual(result.inflightCountAfterError, 0)
        XCTAssertEqual(result.retryValue, 42)
    }

    func testDescriptorSameQualityCoalescesAndKeepsCallerHeadersIsolated() async throws {
        let mock = MockPlayerAPI()
        let audioData = audioPlayerJSON(url: "https://cdn.example/audio.mp4")
        await mock.setHandler { _, _ in audioData }
        await mock.setSuspendSessionOnly(true)
        let audioJoins = InflightJoinProbe()
        let repo = repository(api: mock, audioJoinProbe: audioJoins)

        async let first = repo.resolveStreamDescriptor(
            videoId: "HEADERS",
            quality: .medium,
            requestHeaders: ["Origin": "https://caller-a.example", "X-Caller": "A"]
        )
        async let second = repo.resolveStreamDescriptor(
            videoId: "HEADERS",
            quality: .medium,
            requestHeaders: ["Origin": "https://caller-b.example", "X-Caller": "B"]
        )

        try await audioJoins.waitForCount(2)
        try await mock.waitForSessionCallCount(1)
        await mock.setSuspendSessionOnly(false)
        let (firstDescriptor, secondDescriptor) = try await (first, second)

        let callCount = await mock.playerWithSessionCallCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(firstDescriptor.requestHeaders["X-Caller"], "A")
        XCTAssertEqual(secondDescriptor.requestHeaders["X-Caller"], "B")
        XCTAssertEqual(firstDescriptor.requestHeaders["Origin"], "https://caller-a.example")
        XCTAssertEqual(secondDescriptor.requestHeaders["Origin"], "https://caller-b.example")
    }

    func testDescriptorDifferentQualitiesDoNotCoalesceAndSelectTheirOwnTier() async throws {
        let mock = MockPlayerAPI()
        let audioData = multiQualityAudioPlayerJSON()
        await mock.setHandler { _, _ in audioData }
        await mock.setSuspendSessionOnly(true)
        let audioJoins = InflightJoinProbe()
        let repo = repository(api: mock, audioJoinProbe: audioJoins)

        async let low = repo.resolveStreamDescriptor(
            videoId: "QUALITY",
            quality: .low,
            requestHeaders: [:]
        )
        async let high = repo.resolveStreamDescriptor(
            videoId: "QUALITY",
            quality: .high,
            requestHeaders: [:]
        )

        try await audioJoins.waitForCount(2)
        try await mock.waitForSessionCallCount(2)
        await mock.setSuspendSessionOnly(false)
        let (lowDescriptor, highDescriptor) = try await (low, high)

        let callCount = await mock.playerWithSessionCallCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(lowDescriptor.itag, 139)
        XCTAssertEqual(lowDescriptor.bitrate, 48_000)
        XCTAssertEqual(highDescriptor.itag, 141)
        XCTAssertEqual(highDescriptor.bitrate, 192_000)
    }

    func testDescriptorFallbackOrderAndResetBehaviorRemainExact() async throws {
        let mock = MockPlayerAPI()
        let unavailable = try JSONSerialization.data(withJSONObject: [
            "playabilityStatus": ["status": "ERROR", "reason": "client unavailable"]
        ])
        let success = audioPlayerJSON(url: "https://cdn.example/fallback.mp4")
        await mock.setHandler { kind, _ in
            switch kind {
            case .session:
                return unavailable
            case .player(let clientName):
                return clientName == "WEB_REMIX" ? success : unavailable
            }
        }
        let repo = PlayerRepository(api: mock)

        let descriptor = try await repo.resolveStreamDescriptor(
            videoId: "FALLBACK",
            quality: .medium,
            requestHeaders: [:]
        )

        XCTAssertEqual(descriptor.remoteURL.absoluteString, "https://cdn.example/fallback.mp4")
        let callOrder = await mock.callOrder
        let resetCount = await mock.resetSessionCallCount
        XCTAssertEqual(callOrder, ["ANDROID_VR(session)", "IOS", "WEB_REMIX"])
        XCTAssertEqual(resetCount, 1)
    }

    func testDescriptorRetainsLatestTypedRangeErrorAcrossRetriesAndFallbacks() async {
        let mock = MockPlayerAPI()
        let overflowedInitializationRange = audioPlayerJSON(
            initializationRange: ["start": "0", "end": String(Int64.max)],
            indexRange: ["start": "700", "end": "1199"]
        )
        let partialIndexRange = audioPlayerJSON(
            initializationRange: ["start": "0", "end": "699"],
            indexRange: ["start": "700"]
        )
        await mock.setHandler { kind, _ in
            switch kind {
            case .session:
                return overflowedInitializationRange
            case .player:
                return partialIndexRange
            }
        }
        let repo = PlayerRepository(api: mock)

        do {
            _ = try await repo.resolveStreamDescriptor(
                videoId: "INVALID-RANGE",
                quality: .medium,
                requestHeaders: [:]
            )
            XCTFail("Expected the latest descriptor validation error")
        } catch {
            XCTAssertEqual(error as? StreamDescriptorError, .invalidIndexRange)
        }

        let callOrder = await mock.callOrder
        let resetCount = await mock.resetSessionCallCount
        XCTAssertEqual(
            callOrder,
            Array(repeating: "ANDROID_VR(session)", count: 3)
                + Array(repeating: "IOS", count: 3)
                + Array(repeating: "WEB_REMIX", count: 3)
        )
        XCTAssertEqual(resetCount, 1)
    }

    func testDescriptorWrongInitializationRangeScalarTypePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .invalidInitializationRange,
            videoID: "WRONG-INIT-RANGE-TYPE"
        ) { format in
            format["initRange"] = ["start": 0, "end": "699"] as [String: Any]
        }
    }

    func testDescriptorWrongInitializationRangeContainerShapesPropagateTypedError() async {
        let malformedShapes: [(String, Any)] = [
            ("SCALAR", 42),
            ("ARRAY", [["start": "0", "end": "699"]]),
        ]

        for (suffix, shape) in malformedShapes {
            await assertRepositoryDescriptorError(
                .invalidInitializationRange,
                videoID: "WRONG-INIT-CONTAINER-\(suffix)"
            ) { format in
                format["initRange"] = shape
            }
        }
    }

    func testDescriptorMissingAndNullURLPropagateTypedError() async {
        await assertRepositoryDescriptorError(
            .missingURL,
            videoID: "MISSING-URL"
        ) { format in
            format.removeValue(forKey: "url")
        }
        await assertRepositoryDescriptorError(
            .missingURL,
            videoID: "NULL-URL"
        ) { format in
            format["url"] = NSNull()
        }
    }

    func testDescriptorWrongURLScalarTypePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .invalidURL,
            videoID: "WRONG-URL-TYPE"
        ) { format in
            format["url"] = 42
        }
    }

    func testDescriptorMissingAndNullMIMETypePropagateTypedError() async {
        await assertRepositoryDescriptorError(
            .missingMIMEType,
            videoID: "MISSING-MIME"
        ) { format in
            format.removeValue(forKey: "mimeType")
        }
        await assertRepositoryDescriptorError(
            .missingMIMEType,
            videoID: "NULL-MIME"
        ) { format in
            format["mimeType"] = NSNull()
        }
    }

    func testDescriptorWrongMIMEScalarTypePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .missingMIMEType,
            videoID: "WRONG-MIME-TYPE"
        ) { format in
            format["mimeType"] = ["audio/mp4"]
        }
    }

    func testDescriptorPrefersLaterValidURLOverMalformedHigherBitrateCandidate() async throws {
        let mock = MockPlayerAPI()
        var malformed = descriptorAudioFormat(
            url: "ftp://cdn.example/malformed.mp4",
            bitrate: 192_000
        )
        malformed["itag"] = 141
        var valid = descriptorAudioFormat(
            url: "https://cdn.example/valid.mp4?sig=a%2Bb&x=1&x=2",
            bitrate: 128_000
        )
        valid["itag"] = 140
        let response = descriptorAudioPlayerJSON(formats: [malformed, valid])
        await mock.setHandler { _, _ in response }
        let repo = PlayerRepository(api: mock)

        let descriptor = try await repo.resolveStreamDescriptor(
            videoId: "PREFER-VALID-URL",
            quality: .high,
            requestHeaders: [:]
        )

        XCTAssertEqual(descriptor.itag, 140)
        XCTAssertEqual(
            descriptor.remoteURL.absoluteString,
            "https://cdn.example/valid.mp4?sig=a%2Bb&x=1&x=2"
        )
        let callCount = await mock.playerWithSessionCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testDescriptorPrefersLaterValidMIMEOverMalformedHigherBitrateCandidate() async throws {
        let mock = MockPlayerAPI()
        var malformed = descriptorAudioFormat(bitrate: 192_000)
        malformed["itag"] = 141
        malformed["mimeType"] = 42
        var valid = descriptorAudioFormat(bitrate: 128_000)
        valid["itag"] = 140
        let response = descriptorAudioPlayerJSON(formats: [malformed, valid])
        await mock.setHandler { _, _ in response }
        let repo = PlayerRepository(api: mock)

        let descriptor = try await repo.resolveStreamDescriptor(
            videoId: "PREFER-VALID-MIME",
            quality: .high,
            requestHeaders: [:]
        )

        XCTAssertEqual(descriptor.itag, 140)
        XCTAssertEqual(descriptor.mimeType, "audio/mp4")
        let callCount = await mock.playerWithSessionCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testDescriptorPrefersLaterValidMIMEOverMalformedBaseCandidate() async throws {
        let mock = MockPlayerAPI()
        var malformed = descriptorAudioFormat(
            mimeType: "audio/mp4/extra; codecs=\"mp4a.40.2\"",
            bitrate: 192_000
        )
        malformed["itag"] = 141
        var valid = descriptorAudioFormat(bitrate: 128_000)
        valid["itag"] = 140
        let response = descriptorAudioPlayerJSON(formats: [malformed, valid])
        await mock.setHandler { _, _ in response }
        let repo = PlayerRepository(api: mock)

        let descriptor = try await repo.resolveStreamDescriptor(
            videoId: "PREFER-VALID-MIME-BASE",
            quality: .high,
            requestHeaders: [:]
        )

        XCTAssertEqual(descriptor.itag, 140)
        XCTAssertEqual(descriptor.mimeType, "audio/mp4")
        let callCount = await mock.playerWithSessionCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testDescriptorWrongIndexRangeScalarTypePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .invalidIndexRange,
            videoID: "WRONG-INDEX-RANGE-TYPE"
        ) { format in
            format["indexRange"] = ["start": "700", "end": false] as [String: Any]
        }
    }

    func testDescriptorWrongIndexRangeContainerShapesPropagateTypedError() async {
        let malformedShapes: [(String, Any)] = [
            ("SCALAR", "700-1199"),
            ("ARRAY", ["700", "1199"]),
        ]

        for (suffix, shape) in malformedShapes {
            await assertRepositoryDescriptorError(
                .invalidIndexRange,
                videoID: "WRONG-INDEX-CONTAINER-\(suffix)"
            ) { format in
                format["indexRange"] = shape
            }
        }
    }

    func testDescriptorMalformedMIMEBasePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .missingMIMEType,
            videoID: "MALFORMED-MIME-BASE"
        ) { format in
            format["mimeType"] = "audio/mp4/extra; codecs=\"mp4a.40.2\""
        }
    }

    func testDescriptorNonASCIIMIMEBasePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .missingMIMEType,
            videoID: "NON-ASCII-MIME-BASE"
        ) { format in
            format["mimeType"] = "audio/mK4; codecs=\"mp4a.40.2\""
        }
    }

    func testDescriptorMalformedQuotedMIMEBasePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .missingMIMEType,
            videoID: "QUOTED-MALFORMED-MIME-BASE"
        ) { format in
            format["mimeType"] = "audio/mp\"4; codecs=\"mp4a.40.2\""
        }
    }

    func testDescriptorWrongContentLengthScalarTypePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .invalidContentLength,
            videoID: "WRONG-CONTENT-LENGTH-TYPE"
        ) { format in
            format["contentLength"] = ["unexpected": "4000000"]
        }
    }

    func testDescriptorWrongDurationScalarTypePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .invalidDuration,
            videoID: "WRONG-DURATION-TYPE"
        ) { format in
            format["approxDurationMs"] = 245_678
        }
    }

    func testDescriptorWrongBitrateScalarTypePropagatesTypedError() async {
        await assertRepositoryDescriptorError(
            .invalidBitrate,
            videoID: "WRONG-BITRATE-TYPE"
        ) { format in
            format["bitrate"] = "128000"
        }
    }

    func testDescriptorRejectsNonHTTPSchemeThroughRepositoryPath() async {
        await assertRepositoryDescriptorError(
            .invalidURL,
            videoID: "FTP-SCHEME"
        ) { format in
            format["url"] = "ftp://cdn.example/descriptor.mp4"
        }
    }

    func testLegacyTupleAPIProjectsDescriptorURLAndContentLength() async throws {
        let mock = MockPlayerAPI()
        let url = "https://example.test/videoplayback?sig=a%2Bb&x=1&x=2&range=7-9"
        await mock.setHandler { _, _ in self.audioPlayerJSON(url: url, contentLength: "4000000") }
        let repo = PlayerRepository(api: mock)

        let result = try await repo.resolveStreamURL(videoId: "LEGACY")

        XCTAssertEqual(result.url, url)
        XCTAssertEqual(result.contentLength, 4_000_000)
    }

    func testLegacyTupleAPIPreservesNoStreamErrorForMalformedDescriptor() async {
        let mock = MockPlayerAPI()
        let malformed = audioPlayerJSON(
            initializationRange: ["start": "0", "end": "699"],
            indexRange: ["start": "700"]
        )
        await mock.setHandler { _, _ in malformed }
        let repo = PlayerRepository(api: mock)

        do {
            _ = try await repo.resolveStreamURL(videoId: "LEGACY-INVALID-RANGE")
            XCTFail("Expected legacy no-stream behavior")
        } catch let error as InnerTubeError {
            guard case .noStreamAvailable = error else {
                return XCTFail("Expected noStreamAvailable, got \(error)")
            }
        } catch {
            XCTFail("Expected InnerTubeError.noStreamAvailable, got \(error)")
        }
    }

    func testLegacyTupleAPITranslatesWrongRangeContainerToNoStream() async {
        let mock = MockPlayerAPI()
        let malformed = descriptorAudioPlayerJSON { format in
            format["initRange"] = 42
        }
        await mock.setHandler { _, _ in malformed }
        let repo = PlayerRepository(api: mock)

        do {
            _ = try await repo.resolveStreamURL(videoId: "LEGACY-WRONG-RANGE-CONTAINER")
            XCTFail("Expected legacy no-stream behavior")
        } catch let error as InnerTubeError {
            guard case .noStreamAvailable = error else {
                return XCTFail("Expected noStreamAvailable, got \(error)")
            }
        } catch {
            XCTFail("Expected InnerTubeError.noStreamAvailable, got \(error)")
        }
    }

    func testLegacyTupleAPITranslatesMissingURLAndMIMEErrorsToNoStream() async {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("LEGACY-MISSING-URL", { $0.removeValue(forKey: "url") }),
            ("LEGACY-MISSING-MIME", { $0.removeValue(forKey: "mimeType") }),
            (
                "LEGACY-QUOTED-MALFORMED-MIME",
                { $0["mimeType"] = "audio/mp\"4; codecs=\"mp4a.40.2\"" }
            ),
        ]

        for (videoID, mutation) in mutations {
            let mock = MockPlayerAPI()
            let response = descriptorAudioPlayerJSON(mutatingFormat: mutation)
            await mock.setHandler { _, _ in response }
            let repo = PlayerRepository(api: mock)

            do {
                _ = try await repo.resolveStreamURL(videoId: videoID)
                XCTFail("Expected legacy no-stream error")
            } catch let error as InnerTubeError {
                guard case .noStreamAvailable = error else {
                    XCTFail("Expected legacy no-stream error")
                    continue
                }
            } catch {
                XCTFail("Expected legacy no-stream error")
            }
        }
    }

    private func assertRepositoryDescriptorError(
        _ expected: StreamDescriptorError,
        videoID: String,
        mutatingFormat: @escaping (inout [String: Any]) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let mock = MockPlayerAPI()
        let response = descriptorAudioPlayerJSON(mutatingFormat: mutatingFormat)
        await mock.setHandler { _, _ in response }
        let repo = PlayerRepository(api: mock)

        do {
            _ = try await repo.resolveStreamDescriptor(
                videoId: videoID,
                quality: .medium,
                requestHeaders: [:]
            )
            XCTFail("Expected descriptor validation error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StreamDescriptorError, expected, file: file, line: line)
        }

        let callOrder = await mock.callOrder
        let resetCount = await mock.resetSessionCallCount
        XCTAssertEqual(
            callOrder,
            Array(repeating: "ANDROID_VR(session)", count: 3)
                + Array(repeating: "IOS", count: 3)
                + Array(repeating: "WEB_REMIX", count: 3),
            file: file,
            line: line
        )
        XCTAssertEqual(resetCount, 1, file: file, line: line)
    }

    private func multiQualityAudioPlayerJSON() -> Data {
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "adaptiveFormats": [
                    [
                        "itag": 139,
                        "url": "https://cdn.example/low.mp4",
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.5\"",
                        "bitrate": 48_000,
                        "contentLength": "1000",
                    ],
                    [
                        "itag": 140,
                        "url": "https://cdn.example/medium.mp4",
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "bitrate": 128_000,
                        "contentLength": "2000",
                    ],
                    [
                        "itag": 141,
                        "url": "https://cdn.example/high.mp4",
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "bitrate": 192_000,
                        "contentLength": "3000",
                    ],
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}

/// Test-only join barrier. Production synchronously calls `recordJoin()` only
/// after an existing task was selected or a new task was stored. Waiting for
/// the exact count therefore cannot release the controlled API fake before all
/// peer callers have joined the shared task.
private final class InflightJoinProbe: @unchecked Sendable {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var joinCount = 0
    private var waiters: [UUID: Waiter] = [:]

    func recordJoin() {
        let continuations: [CheckedContinuation<Void, Error>]
        lock.lock()
        joinCount += 1
        let readyTokens = waiters.compactMap { token, waiter in
            waiter.expectedCount <= joinCount ? token : nil
        }
        continuations = readyTokens.compactMap {
            waiters.removeValue(forKey: $0)?.continuation
        }
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForCount(_ expectedCount: Int) async throws {
        precondition(expectedCount > 0)
        let token = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                var immediateError: Error?
                var shouldResume = false

                lock.lock()
                if Task.isCancelled {
                    immediateError = CancellationError()
                } else if joinCount >= expectedCount {
                    shouldResume = true
                } else {
                    waiters[token] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
                lock.unlock()

                if let immediateError {
                    continuation.resume(throwing: immediateError)
                } else if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelWaiter(token)
        }
    }

    private func cancelWaiter(_ token: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: token)?.continuation
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private struct InflightReentryOutcome {
    let rejectedRecursiveReentry: Bool
    let inflightCountAfterError: Int
    let retryValue: Int?
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Minimal lock-protected Bool flag for cross-task observation in tests.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set() {
        lock.lock()
        _value = true
        lock.unlock()
    }
    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

// MARK: - MockPlayerAPI

/// In-memory mock of `PlayerAPIClient` that counts calls and supports a
/// suspend/release continuation per test (used to ensure concurrent callers
/// arrive before the underlying call returns).
actor MockPlayerAPI: PlayerAPIClient {
    enum CallKind { case session, player(String) }
    typealias Handler = @Sendable (CallKind, String) throws -> Data

    private enum CountKind: Sendable {
        case session
        case player
    }

    private struct CallCountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var handler: Handler = { _, _ in Data() }
    private var suspendOnPlayer = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    // Per-kind suspension — used by tests that need to hold one path
    // indefinitely while letting the other path complete (cache independence
    // under contention).
    private var suspendSessionOnly = false
    private var suspendPlayerOnly = false
    private var isPlayerSuspended = false
    private var sessionContinuations: [CheckedContinuation<Void, Never>] = []
    private var playerContinuations: [CheckedContinuation<Void, Never>] = []
    private var parkedSessionCallCount = 0
    private var parkedPlayerCallCount = 0
    private var sessionCallCountWaiters: [UUID: CallCountWaiter] = [:]
    private var playerCallCountWaiters: [UUID: CallCountWaiter] = [:]

    private(set) var playerCallCount = 0
    private(set) var playerWithSessionCallCount = 0
    private(set) var resetSessionCallCount = 0
    private(set) var callOrder: [String] = []

    func setHandler(_ h: @escaping Handler) {
        self.handler = h
    }

    func setSuspendOnPlayer(_ enabled: Bool) {
        self.suspendOnPlayer = enabled
        if !enabled { releaseAllInternal() }
    }

    /// Suspend ONLY `player(...)` calls. Session calls pass through.
    func setSuspendPlayerOnly(_ enabled: Bool) {
        self.suspendPlayerOnly = enabled
        if !enabled {
            isPlayerSuspended = false
            let pending = playerContinuations
            playerContinuations.removeAll()
            for c in pending { c.resume() }
        }
    }

    /// Suspend ONLY `playerWithSession(...)` calls. Player calls pass through.
    func setSuspendSessionOnly(_ enabled: Bool) {
        self.suspendSessionOnly = enabled
        if !enabled {
            let pending = sessionContinuations
            sessionContinuations.removeAll()
            for c in pending { c.resume() }
        }
    }

    func releaseAll() {
        releaseAllInternal()
    }

    func waitForSessionCallCount(_ expectedCount: Int) async throws {
        try await waitForCallCount(expectedCount, kind: .session)
    }

    func waitForPlayerCallCount(_ expectedCount: Int) async throws {
        try await waitForCallCount(expectedCount, kind: .player)
    }

    private func waitForCallCount(_ expectedCount: Int, kind: CountKind) async throws {
        precondition(expectedCount > 0)
        let token = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                switch kind {
                case .session where parkedSessionCallCount >= expectedCount,
                    .player where parkedPlayerCallCount >= expectedCount:
                    continuation.resume()
                case .session:
                    sessionCallCountWaiters[token] = CallCountWaiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                case .player:
                    playerCallCountWaiters[token] = CallCountWaiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelCallCountWaiter(token, kind: kind)
            }
        }
    }

    private func cancelCallCountWaiter(_ token: UUID, kind: CountKind) {
        let waiter: CallCountWaiter?
        switch kind {
        case .session:
            waiter = sessionCallCountWaiters.removeValue(forKey: token)
        case .player:
            waiter = playerCallCountWaiters.removeValue(forKey: token)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func recordParkedCall(_ kind: CallKind) {
        switch kind {
        case .session:
            parkedSessionCallCount += 1
            let readyTokens = sessionCallCountWaiters.compactMap { token, waiter in
                waiter.expectedCount <= parkedSessionCallCount ? token : nil
            }
            for token in readyTokens {
                sessionCallCountWaiters.removeValue(forKey: token)?.continuation.resume()
            }
        case .player:
            parkedPlayerCallCount += 1
            let readyTokens = playerCallCountWaiters.compactMap { token, waiter in
                waiter.expectedCount <= parkedPlayerCallCount ? token : nil
            }
            for token in readyTokens {
                playerCallCountWaiters.removeValue(forKey: token)?.continuation.resume()
            }
        }
    }

    private func releaseAllInternal() {
        isPlayerSuspended = false
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
        let sp = sessionContinuations
        sessionContinuations.removeAll()
        for c in sp { c.resume() }
        let pp = playerContinuations
        playerContinuations.removeAll()
        for c in pp { c.resume() }
    }

    private func waitIfSuspended(kind: CallKind) async {
        if suspendOnPlayer {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                continuations.append(c)
                recordParkedCall(kind)
            }
            return
        }
        switch kind {
        case .session:
            guard suspendSessionOnly else { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                sessionContinuations.append(c)
                recordParkedCall(kind)
            }
        case .player:
            guard suspendPlayerOnly else { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                playerContinuations.append(c)
                recordParkedCall(kind)
            }
        }
    }

    // MARK: PlayerAPIClient

    func playerWithSession(videoId: String, playlistId: String?) async throws -> Data {
        playerWithSessionCallCount += 1
        callOrder.append("ANDROID_VR(session)")
        await waitIfSuspended(kind: .session)
        return try handler(.session, videoId)
    }

    func player(client: YouTubeClient, videoId: String, playlistId: String?) async throws -> Data {
        playerCallCount += 1
        callOrder.append(client.clientName)
        await waitIfSuspended(kind: .player(client.clientName))
        return try handler(.player(client.clientName), videoId)
    }

    func playerWithVisionOS(videoId: String) async throws -> Data {
        if suspendPlayerOnly {
            if isPlayerSuspended {
                return try handler(.session, videoId)
            }
            isPlayerSuspended = true
            playerCallCount += 1
            await waitIfSuspended(kind: .player("VISIONOS"))
            return try handler(.player("VISIONOS"), videoId)
        }
        playerCallCount += 1
        if suspendOnPlayer {
            await waitIfSuspended(kind: .player("VISIONOS"))
            return try handler(.player("VISIONOS"), videoId)
        }
        return try handler(.player("VISIONOS"), videoId)
    }

    func resetSession() async {
        resetSessionCallCount += 1
    }
}
