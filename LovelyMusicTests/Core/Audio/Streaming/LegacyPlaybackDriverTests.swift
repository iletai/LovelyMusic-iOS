import Foundation
import XCTest

@testable import LovelyMusic

final class LegacyPlaybackDriverTests: XCTestCase {
    func testValidatedLegacyFallbackTokensPreserveExactCoordinatorIdentity() throws {
        let sessionID = PlaybackSessionID.fresh()
        let sourceAttempt = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .legacyDownloadRemux
        )
        let fallback = FallbackAttempt(
            sourceAttempt: sourceAttempt,
            targetSeconds: 37,
            intent: .paused,
            reservationID: StorageReservationID(rawValue: UUID())
        )

        let tokens = try XCTUnwrap(
            ActivePlaybackTokens.validatedLegacyFallback(fallback)
        )

        XCTAssertEqual(tokens.sessionID, sessionID)
        XCTAssertEqual(tokens.currentSourceAttempt, sourceAttempt)
        XCTAssertNil(tokens.latestSeekAttempt)
    }

    func testOffsetZeroPublishesNeutralCompleteRawArtifactBeforeRemuxStarts() async throws {
        let harness = DriverHarness()
        let request = harness.makeRequest(targetSeconds: 0, intent: .playing)

        let downloaded = try await harness.driver.download(request)

        let transportInvocations = await harness.transport.invocationCount
        let remuxInvocations = await harness.remuxer.invocationCount
        let eventKinds = await harness.events.kinds
        let timestamps = await harness.events.events.map(\.monotonicTimestamp)
        XCTAssertEqual(transportInvocations, 1)
        XCTAssertEqual(remuxInvocations, 0)
        XCTAssertEqual(
            eventKinds,
            [
                .downloadCompleted(downloaded.rawURL),
                .rawArtifactPrepared(downloaded.rawURL),
            ]
        )
        XCTAssertEqual(timestamps, [123, 123])
    }

    func testNonzeroFallbackOrdersNeutralArtifactsThenHostAuthorizedSeek() async throws {
        let harness = DriverHarness()
        let request = harness.makeRequest(targetSeconds: 87, intent: .playing)

        let downloaded = try await harness.driver.download(request)
        _ = try await harness.driver.remux(downloaded)
        try await harness.driver.prepareLocalSeek(downloaded, targetSeconds: 87)

        let eventKinds = await harness.events.kinds
        XCTAssertEqual(
            eventKinds,
            [
                .downloadCompleted(downloaded.rawURL),
                .rawArtifactPrepared(downloaded.rawURL),
                .remuxCompleted(downloaded.remuxedURL),
                .localSeekPrepared(
                    downloaded.remuxedURL,
                    targetSeconds: 87
                ),
            ]
        )
    }

    func testDriverEventsNeverEncodeAutoplayFromRequestIntent() async throws {
        for targetSeconds in [0.0, 42.0] {
            let harness = DriverHarness()
            let request = harness.makeRequest(
                targetSeconds: targetSeconds,
                intent: .paused
            )

            let downloaded = try await harness.driver.download(request)
            _ = try await harness.driver.remux(downloaded)
            try await harness.driver.prepareLocalSeek(
                downloaded,
                targetSeconds: targetSeconds
            )

            let eventKinds = await harness.events.kinds
            XCTAssertEqual(
                eventKinds,
                [
                    .downloadCompleted(downloaded.rawURL),
                    .rawArtifactPrepared(downloaded.rawURL),
                    .remuxCompleted(downloaded.remuxedURL),
                    .localSeekPrepared(
                        downloaded.remuxedURL,
                        targetSeconds: targetSeconds
                    ),
                ]
            )
        }
    }

    func testValidatedProgressForwardsOnlyPositiveMonotonicHighWater() async throws {
        let harness = DriverHarness()
        let recorder = LegacyProgressRecorder()
        let downloaded = try await harness.driver.download(
            harness.makeRequest(targetSeconds: 9, intent: .playing),
            progressSink: { progress in await recorder.record(progress) }
        )
        _ = try await harness.driver.remux(
            downloaded,
            progressSink: { progress in await recorder.record(progress) }
        )

        let progress = await recorder.progress
        XCTAssertEqual(
            progress.compactMap(\.validatedResponseBodyBytes),
            [16]
        )
        XCTAssertEqual(progress.compactMap(\.remuxOutputBytes), [8])
        XCTAssertTrue(progress.allSatisfy { $0.tokens == downloaded.request.tokens })
    }

    func testArtifactOwnershipHandoffBoundsDriverBookkeeping() async throws {
        let harness = DriverHarness()
        for target in 0..<20 {
            let downloaded = try await harness.driver.download(
                harness.makeRequest(
                    targetSeconds: TimeInterval(target),
                    intent: .paused
                )
            )
            await harness.driver.finish(downloaded)
        }

        let trackedAttemptCount = await harness.driver.trackedAttemptCount
        XCTAssertEqual(trackedAttemptCount, 0)
    }

    func testRemuxRetryReusesDownloadedArtifactWithoutRestartingNetwork() async throws {
        let harness = DriverHarness(remuxOutcomes: [.failure, .success])
        let downloaded = try await harness.driver.download(
            harness.makeRequest(targetSeconds: 20, intent: .playing)
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.driver.remux(downloaded)
        } verify: { error in
            XCTAssertEqual(error as? LegacyPlaybackDriverError, .remuxFailed)
        }
        let removedAfterFailure = await harness.files.removedURLs
        let failedEventKinds = await harness.events.kinds
        XCTAssertTrue(removedAfterFailure.isEmpty)
        XCTAssertEqual(
            failedEventKinds,
            [
                .downloadCompleted(downloaded.rawURL),
                .rawArtifactPrepared(downloaded.rawURL),
            ]
        )
        _ = try await harness.driver.remux(downloaded)

        let transportInvocations = await harness.transport.invocationCount
        let remuxInvocations = await harness.remuxer.invocationCount
        XCTAssertEqual(transportInvocations, 1)
        XCTAssertEqual(remuxInvocations, 2)
    }

    func testTransportFailureReturnsToGateWithoutInternalNetworkRetry() async {
        let harness = DriverHarness(transportOutcome: .failure)
        let request = harness.makeRequest(targetSeconds: 0, intent: .playing)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.driver.download(request)
        } verify: { error in
            XCTAssertEqual(
                error as? LegacyPlaybackDriverError,
                .transportRequiresRegate(request.reservationID)
            )
        }

        let transportInvocations = await harness.transport.invocationCount
        XCTAssertEqual(transportInvocations, 1)
        await assertExactlyOnceCleanup(harness)
    }

    func testNonpositiveValidatedLengthFailsBeforeArtifactsOrTransport() async {
        for invalidLength in [Int64.zero, -1] {
            let harness = DriverHarness()
            await XCTAssertThrowsErrorAsync {
                _ = try await harness.driver.download(
                    harness.makeRequest(
                        targetSeconds: 0,
                        intent: .playing,
                        validatedContentLength: invalidLength
                    )
                )
            } verify: { error in
                XCTAssertEqual(
                    error as? LegacyPlaybackDriverError,
                    .invalidValidatedContentLength
                )
            }
            let invocationCount = await harness.transport.invocationCount
            let artifacts = await harness.files.lastArtifacts
            XCTAssertEqual(invocationCount, 0)
            XCTAssertNil(artifacts)
        }
    }

    func testNormalCompletionWithTruncatedArtifactIsRejectedBeforePublishing() async {
        let harness = DriverHarness(transportOutcome: .truncated)
        let request = harness.makeRequest(targetSeconds: 0, intent: .playing)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.driver.download(request)
        } verify: { error in
            XCTAssertEqual(
                error as? LegacyPlaybackDriverError,
                .incompleteDownload(expectedBytes: 16, actualBytes: 8)
            )
        }

        let eventKinds = await harness.events.kinds
        XCTAssertTrue(eventKinds.isEmpty)
        await assertExactlyOnceCleanup(harness)
    }

    func testLocalArtifactStatFailureDoesNotRequestNetworkRegate() async {
        let harness = DriverHarness()
        await harness.files.setFileSizeFailure(true)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.driver.download(
                harness.makeRequest(targetSeconds: 0, intent: .playing)
            )
        } verify: { error in
            XCTAssertEqual(
                error as? LegacyPlaybackDriverError,
                .localArtifactFailure
            )
        }

        let transportInvocations = await harness.transport.invocationCount
        XCTAssertEqual(transportInvocations, 1)
        await assertExactlyOnceCleanup(harness)
    }

    func testTransportLocalWriteFailureIsLocalAndNeverRequestsNetworkRegate() async {
        let harness = DriverHarness(transportOutcome: .localWriteFailure)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.driver.download(
                harness.makeRequest(targetSeconds: 0, intent: .playing)
            )
        } verify: { error in
            XCTAssertEqual(
                error as? LegacyPlaybackDriverError,
                .localArtifactFailure
            )
        }

        let transportInvocations = await harness.transport.invocationCount
        XCTAssertEqual(transportInvocations, 1)
        await assertExactlyOnceCleanup(harness)
    }

    func testCancellationCleansTemporaryFilesExactlyOnceBeforeAcknowledgement() async {
        let harness = DriverHarness(transportOutcome: .waitForCancellation)
        let request = harness.makeRequest(targetSeconds: 0, intent: .playing)
        let task = Task { try await harness.driver.download(request) }
        await harness.transport.waitUntilStarted()

        task.cancel()
        _ = try? await task.value
        await harness.driver.cancel(request)

        await assertExactlyOnceCleanup(harness)
    }

    func testTokensBecomingStaleAfterBytesNeverPublishPlayableArtifact() async {
        let validity = TokenValidity(validResults: [true, false])
        let harness = DriverHarness(tokenValidity: validity)
        let request = harness.makeRequest(targetSeconds: 0, intent: .playing)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.driver.download(request)
        } verify: { error in
            XCTAssertEqual(error as? LegacyPlaybackDriverError, .staleTokens)
        }

        let eventKinds = await harness.events.kinds
        XCTAssertTrue(eventKinds.isEmpty)
        await assertExactlyOnceCleanup(harness)

        await harness.driver.cancel(request)
        await assertExactlyOnceCleanup(harness)
    }

    func testTokensBecomingStaleDuringRemuxNeverPublishPreparedArtifact() async throws {
        let validity = TokenValidity(validResults: [true, true, true, false])
        let harness = DriverHarness(tokenValidity: validity)
        let request = harness.makeRequest(targetSeconds: 38, intent: .playing)
        let downloaded = try await harness.driver.download(request)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.driver.remux(downloaded)
        } verify: { error in
            XCTAssertEqual(error as? LegacyPlaybackDriverError, .staleTokens)
        }

        let eventKinds = await harness.events.kinds
        XCTAssertEqual(
            eventKinds,
            [
                .downloadCompleted(downloaded.rawURL),
                .rawArtifactPrepared(downloaded.rawURL),
            ]
        )
        await assertExactlyOnceCleanup(harness)
    }

    func testProductionHeaderProbeRequestsOneByteAndQualifiesContentRangeTotal() async throws {
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/16",
                        "Content-Length": "1",
                    ],
                    bodyChunks: [Data([0x00])]
                )
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let probe = HeaderOnlyLegacyDescriptorProbe(session: session)
        let tokens = ActivePlaybackTokens.freshSession(source: .legacyDownloadRemux)
        let qualified = try await LegacyDescriptorQualifier(probe: probe).qualify(
            descriptor: .fixture(
                contentLength: nil,
                requestHeaders: [
                    "Range": "bytes=0-",
                    "If-Range": "stale-validator",
                    "Accept-Encoding": "gzip",
                ]
            ),
            tokens: tokens
        )

        XCTAssertEqual(qualified.validatedContentLength, 16)
        XCTAssertEqual(qualified.metadataProbeResponseBodyBytes, 1)
        XCTAssertLessThanOrEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 1)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.first?.httpMethod, "GET")
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests.first?
                .value(forHTTPHeaderField: "Range"),
            "bytes=0-0"
        )
        XCTAssertNil(
            MediaURLProtocolStub.capturedRequests.first?
                .value(forHTTPHeaderField: "If-Range")
        )
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests.first?
                .value(forHTTPHeaderField: "Accept-Encoding"),
            "identity"
        )
    }

    func testDescriptorQualifierPropagatesCancellationWithoutMappingPolicyFailure() async {
        await XCTAssertThrowsErrorAsync {
            _ = try await LegacyDescriptorQualifier(
                probe: CancellationLegacyDescriptorProbe()
            ).qualify(
                descriptor: .fixture(contentLength: nil),
                tokens: .freshSession(source: .legacyDownloadRemux)
            )
        } verify: { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // Foundation can defer URLProtocol response-delegate delivery until body/finish.
    // Bodyless fixtures therefore cover typed terminal taxonomy and zero delivered
    // body; the response delegate's source order rejects before returning `.allow`.
    func testProductionHeaderProbeBodylessInvalidRangeHasTypedFailureAndZeroDeliveredBody()
        async
    {
        let cases: [(name: String, status: Int, headers: [String: String])] = [
            (
                "range-ignored",
                200,
                ["Content-Length": "16"]
            ),
            (
                "oversized-206",
                206,
                [
                    "Content-Range": "bytes 0-1/16",
                    "Content-Length": "2",
                ]
            ),
            (
                "mismatched-206",
                206,
                [
                    "Content-Range": "bytes 1-1/16",
                    "Content-Length": "1",
                ]
            ),
        ]

        for testCase in cases {
            let operationCompleted = expectation(
                description: "\(testCase.name) probe operation completed"
            )
            MediaURLProtocolStub.reset(
                responses: [
                    .init(
                        statusCode: testCase.status,
                        headers: testCase.headers,
                        bodyChunks: [],
                        finish: true
                    )
                ]
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MediaURLProtocolStub.self]
            let session = URLSession(configuration: configuration)
            let probe = HeaderOnlyLegacyDescriptorProbe(session: session)
            let completion = ProductionOperationCompletionRecorder()
            let task = Task {
                defer { operationCompleted.fulfill() }
                do {
                    _ = try await LegacyDescriptorQualifier(probe: probe).qualify(
                        descriptor: .fixture(contentLength: nil),
                        tokens: .freshSession(source: .legacyDownloadRemux)
                    )
                    await completion.record(error: nil)
                } catch {
                    await completion.record(error: error)
                }
            }
            await fulfillment(of: [operationCompleted], timeout: 2)

            let operationDidComplete = await completion.isCompleted
            let error = await completion.error
            if !operationDidComplete {
                task.cancel()
            }
            _ = await task.result
            session.invalidateAndCancel()

            XCTAssertTrue(operationDidComplete, testCase.name)
            XCTAssertEqual(
                error as? LegacyDescriptorQualificationError,
                .cannotEstablishValidatedGeneration,
                testCase.name
            )
            XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0, testCase.name)
            XCTAssertEqual(
                MediaURLProtocolStub.capturedRequests.first?
                    .value(forHTTPHeaderField: "Range"),
                "bytes=0-0",
                testCase.name
            )
            XCTAssertEqual(
                MediaURLProtocolStub.capturedRequests.first?.httpMethod,
                "GET",
                testCase.name
            )
        }
    }

    func testProductionHeaderProbeCancellationStopsBeforeHeldNextChunk() async {
        let nextChunk = MediaURLProtocolStub.BodyGate()
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/16",
                        "Content-Length": "1",
                    ],
                    bodyChunks: [Data([0x00]), Data([0x01])],
                    bodyChunkGates: [nil, nextChunk]
                )
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let probe = HeaderOnlyLegacyDescriptorProbe(session: session)
        let tokens = ActivePlaybackTokens.freshSession(source: .legacyDownloadRemux)
        let task = Task {
            try await probe.probe(descriptor: .fixture(contentLength: nil), tokens: tokens)
        }
        await waitUntilDriver { MediaURLProtocolStub.emittedResponseBodyBytes == 1 }

        task.cancel()
        _ = try? await task.value
        await waitUntilDriver { MediaURLProtocolStub.stoppedRequestCount == 1 }
        nextChunk.release()

        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 1)
        XCTAssertEqual(MediaURLProtocolStub.stoppedRequestCount, 1)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.first?.httpMethod, "GET")
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests.first?
                .value(forHTTPHeaderField: "Range"),
            "bytes=0-0"
        )
    }

    func testProductionDownloaderPublishesMonotonicBoundedCumulativeProgress() async throws {
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "16"],
                    bodyChunks: [
                        Data(repeating: 1, count: 4),
                        Data(repeating: 2, count: 4),
                        Data(repeating: 3, count: 4),
                        Data(repeating: 4, count: 4),
                    ]
                )
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let downloader = URLSessionLegacyMediaDownloader(configuration: configuration)
        let recorder = ProductionProgressRecorder()
        let destination = temporaryLegacyDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let request = makeProductionRequest(validatedContentLength: 16)

        try await downloader.download(request, to: destination) { total in
            await recorder.record(total)
        }

        let progressValues = await recorder.values
        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertTrue(
            isStrictlyIncreasingAndBounded(progressValues, upperBound: 16)
        )
        XCTAssertEqual(progressValues.last, 16)
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
            as? NSNumber
        XCTAssertEqual(size?.int64Value, 16)
    }

    func testProductionDownloaderSanitizesSessionAndOwnsFullGetIdentity() async throws {
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "16"],
                    bodyChunks: [Data(repeating: 1, count: 16)]
                )
            ]
        )
        let unsafe = URLSessionConfiguration.default
        unsafe.protocolClasses = [MediaURLProtocolStub.self]
        unsafe.urlCache = .shared
        unsafe.httpCookieStorage = .shared
        unsafe.urlCredentialStorage = .shared
        unsafe.requestCachePolicy = .useProtocolCachePolicy
        unsafe.httpShouldSetCookies = true
        let sanitized = URLSessionLegacyMediaDownloader.sanitizedConfiguration(unsafe)
        XCTAssertNil(sanitized.urlCache)
        XCTAssertNil(sanitized.httpCookieStorage)
        XCTAssertNil(sanitized.urlCredentialStorage)
        XCTAssertFalse(sanitized.httpShouldSetCookies)
        XCTAssertEqual(sanitized.requestCachePolicy, .reloadIgnoringLocalCacheData)

        let downloader = URLSessionLegacyMediaDownloader(configuration: unsafe)
        let destination = temporaryLegacyDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let request = makeProductionRequest(
            validatedContentLength: 16,
            requestHeaders: [
                "Range": "bytes=8-",
                "If-Range": "stale-validator",
                "Accept-Encoding": "gzip",
            ]
        )
        try await downloader.download(request, to: destination) { _ in }

        let captured = try XCTUnwrap(MediaURLProtocolStub.capturedRequests.first)
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertNil(captured.value(forHTTPHeaderField: "Range"))
        XCTAssertNil(captured.value(forHTTPHeaderField: "If-Range"))
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(captured.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testProductionDownloaderCancellationStopsBeforeHeldNextChunk() async {
        let nextChunk = MediaURLProtocolStub.BodyGate()
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "16"],
                    bodyChunks: [Data(repeating: 1, count: 4), Data(repeating: 2, count: 12)],
                    bodyChunkGates: [nil, nextChunk]
                )
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let downloader = URLSessionLegacyMediaDownloader(configuration: configuration)
        let recorder = ProductionProgressRecorder()
        let destination = temporaryLegacyDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let request = makeProductionRequest(validatedContentLength: 16)
        let task = Task {
            try await downloader.download(request, to: destination) { total in
                await recorder.record(total)
            }
        }
        await waitUntilDriver { MediaURLProtocolStub.emittedResponseBodyBytes == 4 }

        task.cancel()
        _ = try? await task.value
        await waitUntilDriver { MediaURLProtocolStub.stoppedRequestCount == 1 }

        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 4)
        let progressAtCancellation = await recorder.values
        XCTAssertTrue(
            isStrictlyIncreasingAndBounded(progressAtCancellation, upperBound: 4)
        )
        XCTAssertEqual(MediaURLProtocolStub.stoppedRequestCount, 1)

        nextChunk.release()
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 4)
        let progressAfterReleasedGate = await recorder.values
        XCTAssertEqual(progressAfterReleasedGate, progressAtCancellation)
    }

    func testProductionDownloaderNeverWritesOrReportsBeyondValidatedLength() async {
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "12"],
                    bodyChunks: [Data(repeating: 1, count: 8), Data(repeating: 2, count: 8)]
                )
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let downloader = URLSessionLegacyMediaDownloader(configuration: configuration)
        let recorder = ProductionProgressRecorder()
        let destination = temporaryLegacyDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let request = makeProductionRequest(validatedContentLength: 12)

        await XCTAssertThrowsErrorAsync {
            try await downloader.download(request, to: destination) { total in
                await recorder.record(total)
            }
        } verify: { error in
            XCTAssertEqual(error as? LegacyMediaDownloadError, .validatedLengthExceeded)
        }

        let progressValues = await recorder.values
        XCTAssertTrue(
            isStrictlyIncreasingAndBounded(progressValues, upperBound: 12)
        )
        let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]
            as? NSNumber
        XCTAssertLessThanOrEqual(size?.int64Value ?? 0, 12)
        XCTAssertEqual(MediaURLProtocolStub.stoppedRequestCount, 1)
    }

    // Foundation can defer URLProtocol response-delegate delivery until body/finish.
    // Bodyless fixtures therefore cover typed terminal taxonomy and zero delivered
    // body; the downloader's source order rejects before creating the destination file.
    func testProductionDownloaderBodylessInvalidStatusAndLengthHaveTypedFailuresAndNoFile()
        async
    {
        let cases: [(
            name: String,
            response: MediaURLProtocolStub.Response,
            expected: LegacyMediaDownloadError
        )] = [
            (
                "non-2xx",
                .init(
                    statusCode: 503,
                    headers: ["Content-Length": "16"],
                    bodyChunks: [],
                    finish: true
                ),
                .unacceptableHTTPStatus(503)
            ),
            (
                "partial-response",
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 1-16/16",
                        "Content-Length": "16",
                    ],
                    bodyChunks: [],
                    finish: true
                ),
                .partialResponseNotAllowed
            ),
            (
                "declared-length-mismatch",
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "17"],
                    bodyChunks: [],
                    finish: true
                ),
                .responseContentLengthMismatch(expected: 16, actual: 17)
            ),
        ]

        for testCase in cases {
            MediaURLProtocolStub.reset(responses: [testCase.response])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MediaURLProtocolStub.self]
            let downloader = URLSessionLegacyMediaDownloader(configuration: configuration)
            let recorder = ProductionProgressRecorder()
            let destination = temporaryLegacyDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let completion = ProductionOperationCompletionRecorder()
            let operationCompleted = expectation(
                description: "\(testCase.name) download operation completed"
            )

            let task = Task {
                defer { operationCompleted.fulfill() }
                do {
                    try await downloader.download(
                        makeProductionRequest(validatedContentLength: 16),
                        to: destination
                    ) { total in
                        await recorder.record(total)
                    }
                    await completion.record(error: nil)
                } catch {
                    await completion.record(error: error)
                }
            }
            await fulfillment(of: [operationCompleted], timeout: 2)
            let operationDidComplete = await completion.isCompleted
            let error = await completion.error
            if !operationDidComplete { task.cancel() }
            _ = await task.result

            XCTAssertTrue(operationDidComplete, testCase.name)
            XCTAssertEqual(error as? LegacyMediaDownloadError, testCase.expected)
            XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0, testCase.name)
            let progressValues = await recorder.values
            XCTAssertTrue(progressValues.isEmpty, testCase.name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), testCase.name)
            XCTAssertEqual(MediaURLProtocolStub.stoppedRequestCount, 1, testCase.name)
        }
    }


    func testPrecancelledDownloaderStartsNoRequestAndReceivesNoBody() async {
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "16"],
                    bodyChunks: [Data(repeating: 1, count: 16)]
                )
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let downloader = URLSessionLegacyMediaDownloader(configuration: configuration)
        let startGate = ProductionAsyncGate()
        let destination = temporaryLegacyDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task {
            await startGate.wait()
            try await downloader.download(
                makeProductionRequest(validatedContentLength: 16),
                to: destination
            ) { _ in }
        }
        task.cancel()
        await startGate.release()
        _ = try? await task.value

        XCTAssertTrue(MediaURLProtocolStub.capturedRequests.isEmpty)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloaderCancellationInInstallWindowNeverResumesRequest() async {
        MediaURLProtocolStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let barrier = ProductionInstallBarrier()
        let downloader = URLSessionLegacyMediaDownloader(
            configuration: configuration,
            beforeTaskResume: { await barrier.hold() }
        )
        let destination = temporaryLegacyDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task {
            try await downloader.download(
                makeProductionRequest(validatedContentLength: 16),
                to: destination
            ) { _ in }
        }
        await waitUntilDriver { await barrier.isHolding }

        task.cancel()
        await barrier.release()
        _ = try? await task.value

        XCTAssertTrue(MediaURLProtocolStub.capturedRequests.isEmpty)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testProbeCancellationInInstallWindowNeverResumesRequest() async {
        MediaURLProtocolStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let barrier = ProductionInstallBarrier()
        let probe = HeaderOnlyLegacyDescriptorProbe(
            session: session,
            beforeTaskResume: { await barrier.hold() }
        )
        let task = Task {
            try await probe.probe(
                descriptor: .fixture(contentLength: nil),
                tokens: .freshSession(source: .legacyDownloadRemux)
            )
        }
        await waitUntilDriver { await barrier.isHolding }

        task.cancel()
        await barrier.release()
        _ = try? await task.value

        XCTAssertTrue(MediaURLProtocolStub.capturedRequests.isEmpty)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
    }

    private func assertExactlyOnceCleanup(
        _ harness: DriverHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let removed = await harness.files.removedURLs
        let artifacts = await harness.files.lastArtifacts
        XCTAssertEqual(removed.count, 2, file: file, line: line)
        XCTAssertEqual(
            removed.filter { $0 == artifacts?.rawURL }.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            removed.filter { $0 == artifacts?.remuxedURL }.count,
            1,
            file: file,
            line: line
        )
    }
}

private actor ProductionProgressRecorder {
    private(set) var values: [Int64] = []

    func record(_ value: Int64) {
        values.append(value)
    }
}

private actor ProductionOperationCompletionRecorder {
    private(set) var isCompleted = false
    private(set) var error: Error?

    func record(error: Error?) {
        self.error = error
        isCompleted = true
    }
}

private func isStrictlyIncreasingAndBounded(
    _ values: [Int64],
    upperBound: Int64
) -> Bool {
    values.allSatisfy { $0 > 0 && $0 <= upperBound }
        && zip(values, values.dropFirst()).allSatisfy { pair in
            pair.0 < pair.1
        }
}

private actor ProductionAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ProductionInstallBarrier {
    private(set) var isHolding = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHolding = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isHolding = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func makeProductionRequest(
    validatedContentLength: Int64,
    requestHeaders: [String: String] = [:]
) -> LegacyPlaybackRequest {
    LegacyPlaybackRequest(
        descriptor: .fixture(
            contentLength: validatedContentLength,
            requestHeaders: requestHeaders
        ),
        validatedContentLength: validatedContentLength,
        targetSeconds: 0,
        intent: .playing,
        reservationID: StorageReservationID(rawValue: UUID()),
        tokens: .freshSession(source: .legacyDownloadRemux)
    )
}

private func temporaryLegacyDestination() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("task8-production-\(UUID().uuidString).m4a")
}

private func waitUntilDriver(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        await Task.yield()
    }
    if await condition() { return }
    XCTFail("Timed out waiting for driver test condition", file: file, line: line)
}

private final class DriverHarness: @unchecked Sendable {
    let transport: FakeLegacyMediaTransport
    let remuxer: FakeMediaRemuxer
    let files = FakeLegacyFileSystem()
    let clock = FakeLegacyClock()
    let events = LegacyEventRecorder()
    let tokenValidity: TokenValidity
    let driver: LegacyPlaybackDriver

    init(
        transportOutcome: FakeLegacyMediaTransport.Outcome = .success,
        remuxOutcomes: [FakeMediaRemuxer.Outcome] = [.success],
        tokenValidity: TokenValidity = TokenValidity()
    ) {
        transport = FakeLegacyMediaTransport(
            outcome: transportOutcome,
            fileSystem: files
        )
        remuxer = FakeMediaRemuxer(outcomes: remuxOutcomes)
        self.tokenValidity = tokenValidity
        let events = self.events
        driver = LegacyPlaybackDriver(
            transport: transport,
            remuxer: remuxer,
            fileSystem: files,
            clock: clock,
            tokenValidator: { tokens in
                await tokenValidity.accepts(tokens)
            },
            eventSink: { event in
                await events.record(event)
            }
        )
    }

    func makeRequest(
        targetSeconds: TimeInterval,
        intent: DesiredPlaybackIntent,
        validatedContentLength: Int64 = 16
    ) -> LegacyPlaybackRequest {
        let tokens = ActivePlaybackTokens.freshSession(source: .legacyDownloadRemux)
        return LegacyPlaybackRequest(
            descriptor: StreamDescriptor.fixture(),
            validatedContentLength: validatedContentLength,
            targetSeconds: targetSeconds,
            intent: intent,
            reservationID: StorageReservationID(rawValue: UUID()),
            tokens: tokens
        )
    }
}

private actor FakeLegacyMediaTransport: LegacyMediaDownloading {
    enum Outcome {
        case success, truncated, failure, localWriteFailure, waitForCancellation
    }

    private let outcome: Outcome
    private let fileSystem: FakeLegacyFileSystem
    private(set) var invocationCount = 0
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    init(outcome: Outcome, fileSystem: FakeLegacyFileSystem) {
        self.outcome = outcome
        self.fileSystem = fileSystem
    }

    func download(
        _ request: LegacyPlaybackRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        invocationCount += 1
        hasStarted = true
        let continuations = startedContinuations
        startedContinuations.removeAll()
        continuations.forEach { $0.resume() }

        switch outcome {
        case .success:
            let byteCount = request.descriptor.contentLength ?? 16
            await fileSystem.setFileSize(byteCount, for: destination)
            await progress(-1)
            await progress(request.validatedContentLength + 1)
            await progress(byteCount)
            await progress(byteCount)
            await progress(byteCount - 1)
        case .truncated:
            await fileSystem.setFileSize(8, for: destination)
            await progress(8)
        case .failure:
            throw URLError(.networkConnectionLost)
        case .localWriteFailure:
            throw LegacyMediaDownloadError.localWriteFailed
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }
}

private actor FakeMediaRemuxer: MediaRemuxing {
    enum Outcome { case success, failure }

    private var outcomes: [Outcome]
    private(set) var invocationCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func remux(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        invocationCount += 1
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        switch outcome {
        case .success:
            await progress(0)
            await progress(8)
            await progress(8)
        case .failure:
            throw LegacyPlaybackDriverError.remuxFailed
        }
    }
}

private actor FakeLegacyFileSystem: LegacyPlaybackFileManaging {
    private(set) var removedURLs: [URL] = []
    private(set) var lastArtifacts: LegacyPlaybackArtifacts?
    private var fileSizes: [URL: Int64] = [:]
    private var shouldFailFileSize = false

    func artifacts(for request: LegacyPlaybackRequest) async throws -> LegacyPlaybackArtifacts {
        let base = URL(fileURLWithPath: "/tmp/legacy-\(request.tokens.currentSourceAttempt.id.rawValue)")
        let artifacts = LegacyPlaybackArtifacts(
            rawURL: base.appendingPathExtension("raw.m4a"),
            remuxedURL: base.appendingPathExtension("remuxed.m4a")
        )
        lastArtifacts = artifacts
        return artifacts
    }

    func removeIfPresent(_ url: URL) async {
        removedURLs.append(url)
        fileSizes.removeValue(forKey: url)
    }

    func fileSize(_ url: URL) async throws -> Int64 {
        if shouldFailFileSize { throw CocoaError(.fileReadUnknown) }
        return fileSizes[url] ?? 0
    }

    func setFileSizeFailure(_ shouldFail: Bool) {
        shouldFailFileSize = shouldFail
    }

    func setFileSize(_ byteCount: Int64, for url: URL) {
        fileSizes[url] = byteCount
    }
}

private struct CancellationLegacyDescriptorProbe: LegacyDescriptorProbing {
    func probe(
        descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> LegacyDescriptorProbeResult {
        throw CancellationError()
    }
}

private actor LegacyEventRecorder {
    private(set) var events: [LegacyPlaybackEvent] = []

    var kinds: [LegacyPlaybackEvent.Kind] { events.map(\.kind) }
    func record(_ event: LegacyPlaybackEvent) {
        events.append(event)
    }
}

private actor LegacyProgressRecorder {
    private(set) var progress: [LegacyPlaybackProgress] = []

    func record(_ value: LegacyPlaybackProgress) {
        progress.append(value)
    }
}

private final class FakeLegacyClock: LegacyPlaybackMonotonicClock, @unchecked Sendable {
    var now: TimeInterval { 123 }
}

private actor TokenValidity {
    private var validResults: [Bool]

    init(validResults: [Bool] = []) {
        self.validResults = validResults
    }

    func accepts(_ tokens: ActivePlaybackTokens) -> Bool {
        validResults.isEmpty ? true : validResults.removeFirst()
    }
}

private extension StreamDescriptor {
    static func fixture(
        contentLength: Int64? = 16,
        requestHeaders: [String: String] = ["Origin": "https://music.youtube.com"]
    ) -> Self {
        Self(
            videoID: "video",
            remoteURL: URL(string: "https://r1---sn.example.test/videoplayback?id=redacted")!,
            itag: 140,
            mimeType: "audio/mp4",
            codec: "mp4a.40.2",
            bitrate: 128_000,
            contentLength: contentLength,
            duration: .seconds(180),
            initializationRange: 0..<8,
            indexRange: 8..<16,
            expiresAt: nil,
            requestHeaders: requestHeaders,
            provisionalResourceKey: ProvisionalResourceKey(
                videoID: "video",
                itag: 140,
                codec: "mp4a.40.2",
                declaredTotalLength: contentLength
            )
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}
