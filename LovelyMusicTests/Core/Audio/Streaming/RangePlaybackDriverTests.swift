import AVFoundation
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LovelyMusic

@MainActor
final class RangePlaybackDriverTests: XCTestCase {
    private let authorizedEpoch: UInt64 = 71
    private let signedURL = URL(
        string: "https://media.example.test/videoplayback?sig=task9-secret-query&token=task9-secret-token"
    )!

    func testAssetUsesOpaqueLovelyRangeURLAndRetainsDelegateWithoutOriginSecrets()
        async throws
    {
        let descriptor = makeDescriptor()
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: payload(count: 16),
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let delegateInstaller = RangeResourceLoaderDelegateInstallerSpy()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            resourceLoaderDelegateInstaller: { resourceLoader, delegate, queue in
                delegateInstaller.install(
                    resourceLoader: resourceLoader,
                    delegate: delegate,
                    queue: queue
                )
            }
        )

        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let components = try XCTUnwrap(
            URLComponents(url: handle.asset.url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "lovely-range-v1")
        XCTAssertEqual(components.host, descriptor.provisionalResourceKey.digest)
        XCTAssertEqual(components.path, "/media")
        XCTAssertNil(components.query)
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertEqual(handle.attempt, tokens.currentSourceAttempt)
        XCTAssertTrue(handle.asset.resourceLoader.delegate === handle.loader)
        let delegateQueue = handle.delegateQueue
        XCTAssertTrue(handle.delegateQueue === delegateQueue)
        let installation = try XCTUnwrap(delegateInstaller.observation())
        XCTAssertEqual(installation.callCount, 1)
        XCTAssertEqual(
            installation.delegateIdentity,
            ObjectIdentifier(handle.loader)
        )
        XCTAssertEqual(
            installation.queueIdentity,
            ObjectIdentifier(delegateQueue)
        )

        let queueProbe = RangeDelegateQueueExecutionProbe(queue: delegateQueue)
        queueProbe.begin()
        await queueProbe.waitUntilFirstExecutionEntered()
        queueProbe.releaseFirstExecution()
        await queueProbe.waitUntilCompleted()
        let queueObservation = queueProbe.observation()
        XCTAssertEqual(
            queueObservation.events,
            [.firstEntered, .firstExited, .secondEntered, .secondExited]
        )
        XCTAssertEqual(queueObservation.maximumConcurrentExecutions, 1)
        XCTAssertTrue(queueObservation.allExecutionsMatchedQueueIdentity)
        XCTAssertFalse(queueObservation.executedOnMainThread)
        XCTAssertFalse(queueObservation.firstExecutionTimedOut)

        _ = try await fixture.validateGeneration(for: descriptor, tokens: tokens)
        let observationText = String(reflecting: await fixture.observation())
        for secret in secretValues() {
            XCTAssertFalse(handle.asset.url.absoluteString.contains(secret))
            XCTAssertFalse(observationText.contains(secret))
        }
        XCTAssertTrue(observationText.contains("cookie"))
        XCTAssertTrue(observationText.contains("origin"))
    }

    func testCandidateManifestMayBeLocatedButPayloadReadWaitsForOriginValidation()
        async throws
    {
        let data = payload(count: 16)
        let descriptor = makeDescriptor(contentLength: Int64(data.count))
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let events = RangeTestEventRecorder()
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\""),
            eventSink: { event in events.recordFixtureEvent(event) }
        )
        let candidates = RangeCandidateSpy(
            fullPayload: data,
            events: events
        )
        let driver = makeDriver(
            transport: fixture,
            candidateReader: candidates,
            tokens: tokens
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false,
            events: events
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        let order = events.snapshot()
        let locateIndex = try XCTUnwrap(order.firstIndex(of: .candidateManifestLocated))
        let validationIndex = try XCTUnwrap(
            order.firstIndex(of: .generationValidationCompleted)
        )
        let readIndex = try XCTUnwrap(order.firstIndex(of: .candidatePayloadRead))
        let informationIndex = try XCTUnwrap(
            order.firstIndex(of: .contentInformationSet)
        )
        let responseIndex = try XCTUnwrap(order.firstIndex(of: .responseDelivered))
        XCTAssertLessThan(locateIndex, validationIndex)
        XCTAssertLessThan(validationIndex, readIndex)
        XCTAssertLessThan(validationIndex, informationIndex)
        XCTAssertLessThan(informationIndex, responseIndex)
        let candidateObservation = await candidates.observation()
        let fixtureObservation = await fixture.observation()
        XCTAssertEqual(candidateObservation.readCount, 1)
        XCTAssertEqual(candidateObservation.writeCount, 0)
        XCTAssertEqual(fixtureObservation.byteRequestCount, 0)
        XCTAssertEqual(request.observation().respondedData, data)
        XCTAssertEqual(request.observation().finishCount, 1)
    }

    func testFailedGenerationProbeExposesNoCandidatePayloadOrContentInformation()
        async throws
    {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let events = RangeTestEventRecorder()
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .redirects(
                to: URL(string: "https://blocked.example.test/secret-target")!,
                approved: false
            ),
            eventSink: { event in events.recordFixtureEvent(event) }
        )
        let candidates = RangeCandidateSpy(fullPayload: data, events: events)
        let driver = makeDriver(
            transport: fixture,
            candidateReader: candidates,
            tokens: tokens
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            dataDemand: nil,
            events: events
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        let candidateObservation = await candidates.observation()
        let loadingObservation = request.observation()
        XCTAssertEqual(candidateObservation.locateCount, 1)
        XCTAssertEqual(candidateObservation.readCount, 0)
        XCTAssertEqual(candidateObservation.writeCount, 0)
        XCTAssertNil(loadingObservation.contentInformation)
        XCTAssertTrue(loadingObservation.respondedData.isEmpty)
        XCTAssertEqual(loadingObservation.finishCount, 0)
        XCTAssertEqual(loadingObservation.errorFinishCount, 1)
        XCTAssertEqual(
            loadingObservation.error as? RangeLoaderError,
            .generationValidationFailed
        )
        let fixtureObservation = await fixture.observation()
        XCTAssertEqual(fixtureObservation.byteRequestCount, 0)
        let errorText = String(describing: loadingObservation.error)
        for secret in secretValues() {
            XCTAssertFalse(errorText.contains(secret))
        }
    }

    func testContentInformationUsesValidatedMIMETypeLengthAndRangeSupport()
        async throws
    {
        let data = payload(count: 16)
        let descriptor = makeDescriptor(contentLength: nil)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let events = RangeTestEventRecorder()
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\""),
            eventSink: { event in events.recordFixtureEvent(event) }
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            dataDemand: nil,
            events: events
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilContentInformation()

        let order = events.snapshot()
        let validationIndex = try XCTUnwrap(
            order.firstIndex(of: .generationValidationCompleted)
        )
        let informationIndex = try XCTUnwrap(
            order.firstIndex(of: .contentInformationSet)
        )
        XCTAssertLessThan(validationIndex, informationIndex)
        let information = try XCTUnwrap(request.observation().contentInformation)
        XCTAssertEqual(
            information.contentType,
            UTType(mimeType: descriptor.mimeType)?.identifier
        )
        XCTAssertEqual(information.contentLength, Int64(data.count))
        XCTAssertTrue(information.isByteRangeAccessSupported)
        XCTAssertNil(request.dataDemand)

        await request.waitUntilTerminal()
        XCTAssertEqual(request.observation().finishCount, 1)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        let fixtureObservation = await fixture.observation()
        XCTAssertEqual(fixtureObservation.byteRequestCount, 0)
    }

    func testTwoHandlesForSameSourceAttemptShareOneGenerationProbe()
        async throws
    {
        let data = payload(count: 16)
        let descriptor = makeDescriptor(contentLength: Int64(data.count))
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let firstHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let secondHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(dataDemand: nil)
        let second = RecordingResourceLoadingRequest(dataDemand: nil)

        firstHandle.loader.startLoading(first, requestID: UUID())
        secondHandle.loader.startLoading(second, requestID: UUID())
        await first.waitUntilTerminal()
        await second.waitUntilTerminal()

        let transport = await fixture.observation()
        XCTAssertEqual(transport.generationValidationCount, 1)
        XCTAssertEqual(transport.generationProbeBodyBytes, 1)
        XCTAssertEqual(transport.byteRequestCount, 0)
        XCTAssertEqual(first.observation().finishCount, 1)
        XCTAssertEqual(second.observation().finishCount, 1)
        XCTAssertNotNil(first.observation().contentInformation)
        XCTAssertNotNil(second.observation().contentInformation)
    }

    func testTwoHandlesShareActiveOverlapAndFetchOnlyNetworkUnion() async throws {
        let chunkBytes = 64 * 1024
        let data = payload(count: 96 * 1024)
        let descriptor = makeDescriptor(contentLength: Int64(data.count))
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsEveryByteRequestBeforeBody,
            maximumChunkBytes: chunkBytes
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let firstHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let secondHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        let second = RecordingResourceLoadingRequest(
            requestedOffset: Int64(chunkBytes / 2),
            currentOffset: Int64(chunkBytes / 2),
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )

        firstHandle.loader.startLoading(first, requestID: UUID())
        await fixture.waitUntilStalledRequestCount(1)
        secondHandle.loader.startLoading(second, requestID: UUID())
        let attached = await firstHandle.loader.waitUntilSharedConsumerCount(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            upstreamRange: 0..<Int64(chunkBytes),
            count: 2,
            timeoutNanoseconds: 5_000_000_000
        )

        let held = await fixture.observation()
        XCTAssertTrue(attached)
        XCTAssertEqual(held.generationValidationCount, 1)
        XCTAssertEqual(held.generationProbeBodyBytes, 1)
        XCTAssertEqual(held.byteRequestCount, 1)
        XCTAssertEqual(held.mediaRequestedRanges, [0..<Int64(chunkBytes)])
        XCTAssertEqual(held.mediaResponseBodyBytes, 0)

        await fixture.releaseStalledRequests()
        await first.waitUntilTerminal()
        await second.waitUntilTerminal()

        let terminal = await fixture.observation()
        XCTAssertEqual(terminal.generationValidationCount, 1)
        XCTAssertEqual(terminal.byteRequestCount, 2)
        XCTAssertEqual(
            terminal.mediaRequestedRanges,
            [
                0..<Int64(chunkBytes),
                Int64(chunkBytes)..<Int64(data.count),
            ]
        )
        XCTAssertEqual(terminal.mediaResponseBodyBytes, Int64(data.count))
        XCTAssertEqual(terminal.servedRangeUnion, [0..<Int64(data.count)])
        XCTAssertEqual(first.observation().respondedData, data.subdata(in: 0..<chunkBytes))
        XCTAssertEqual(
            second.observation().respondedData,
            data.subdata(in: (chunkBytes / 2)..<data.count)
        )
        XCTAssertEqual(first.observation().finishCount, 1)
        XCTAssertEqual(second.observation().finishCount, 1)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testTwoHandlesShareFullAttemptBudgetReservation() async throws {
        let chunkBytes = 64 * 1024
        let attemptBudget: Int64 = 65_537
        let data = payload(count: chunkBytes * 2)
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: nil,
            indexRange: nil,
            bitrate: 31_775
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsEveryByteRequestBeforeBody
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            }
        )
        let firstHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let secondHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        let second = RecordingResourceLoadingRequest(
            requestedOffset: Int64(chunkBytes),
            currentOffset: Int64(chunkBytes),
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )

        firstHandle.loader.startLoading(first, requestID: firstID)
        await fixture.waitUntilStalledRequestCount(1)
        secondHandle.loader.startLoading(second, requestID: secondID)
        let suspended = await secondHandle.loader.waitUntilDemandSuspended(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID,
            timeoutNanoseconds: 5_000_000_000
        )

        let held = await fixture.observation()
        XCTAssertTrue(suspended)
        XCTAssertEqual(held.generationValidationCount, 1)
        XCTAssertEqual(held.generationProbeBodyBytes, 1)
        XCTAssertEqual(held.byteRequestCount, 1)
        XCTAssertEqual(held.mediaRequestedRanges, [0..<Int64(chunkBytes)])
        XCTAssertEqual(held.mediaByteCeilings, [attemptBudget - 1])
        XCTAssertEqual(held.mediaResponseBodyBytes, 0)

        secondHandle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID
        )
        firstHandle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: firstID
        )
        XCTAssertEqual(firstHandle.loader.activeRequestCount, 0)
        XCTAssertEqual(secondHandle.loader.activeRequestCount, 0)
        await fixture.waitUntilCancellationCount(1)
        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(1)
        await exitProbe.waitUntilRecorded(2)

        let terminal = await fixture.observation()
        XCTAssertEqual(terminal.generationValidationCount, 1)
        XCTAssertEqual(terminal.byteRequestCount, 1)
        XCTAssertEqual(terminal.cancellationCount, 1)
        XCTAssertEqual(terminal.lateCallbackDrainCount, 1)
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertTrue(second.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testSameAttemptRejectsDescriptorWithDifferentProvisionalIdentity()
        async throws
    {
        let data = payload(count: 16)
        let descriptor = makeDescriptor(contentLength: Int64(data.count))
        let mismatchedDescriptor = makeDescriptor(
            contentLength: Int64(data.count + 1)
        )
        XCTAssertNotEqual(
            descriptor.provisionalResourceKey.digest,
            mismatchedDescriptor.provisionalResourceKey.digest
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let firstHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(dataDemand: nil)
        firstHandle.loader.startLoading(first, requestID: UUID())
        await first.waitUntilTerminal()

        var capturedError: RangeLoaderError?
        do {
            let unexpectedHandle = try driver.makeRangeAsset(
                descriptor: mismatchedDescriptor,
                attempt: tokens.currentSourceAttempt
            )
            let unexpectedRequest = RecordingResourceLoadingRequest(dataDemand: nil)
            unexpectedHandle.loader.startLoading(
                unexpectedRequest,
                requestID: UUID()
            )
            await unexpectedRequest.waitUntilTerminal()
            XCTFail("same attempt accepted a different provisional identity")
        } catch let error as RangeLoaderError {
            capturedError = error
        } catch {
            XCTFail("same attempt returned an unexpected error type")
        }

        XCTAssertEqual(capturedError, .structuralResponse)
        let transport = await fixture.observation()
        XCTAssertEqual(transport.generationValidationCount, 1)
        XCTAssertEqual(transport.generationProbeBodyBytes, 1)
        XCTAssertEqual(transport.byteRequestCount, 0)
    }

    func testGenerationProbePreservesPolicyErrorTaxonomy() async throws {
        let cases: [(MediaTransportError.Reason, RangeLoaderError)] = [
            (.killSwitchEnabled, .killSwitchEnabled),
            (.staleKillSwitchEpoch, .staleKillSwitchEpoch),
            (.stalePlaybackTokens, .stalePlaybackTokens),
        ]

        for (reason, expectedError) in cases {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let fixture = RangeFixtureServer(
                payload: payload(count: 16),
                behavior: .generationProbeError(reason)
            )
            let driver = makeDriver(transport: fixture, tokens: tokens)
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(),
                attempt: tokens.currentSourceAttempt
            )
            let request = RecordingResourceLoadingRequest(dataDemand: nil)

            handle.loader.startLoading(request, requestID: UUID())
            await request.waitUntilTerminal()

            let loading = request.observation()
            let transport = await fixture.observation()
            XCTAssertEqual(loading.error as? RangeLoaderError, expectedError)
            XCTAssertNil(loading.contentInformation)
            XCTAssertTrue(loading.respondedData.isEmpty)
            XCTAssertEqual(loading.finishCount, 0)
            XCTAssertEqual(loading.errorFinishCount, 1)
            XCTAssertEqual(transport.generationValidationCount, 1)
            XCTAssertEqual(transport.generationProbeBodyBytes, 0)
            XCTAssertEqual(transport.byteRequestCount, 0)
            XCTAssertEqual(transport.mediaResponseBodyBytes, 0)
        }
    }

    func testInvalidOrEmptyMIMETypeFallsBackToM4AContentType() async throws {
        guard let fallbackIdentifier = UTType(
            filenameExtension: "m4a"
        )?.identifier else {
            return XCTFail("m4a fallback type must be available")
        }

        for mimeType in ["", "not a mime type"] {
            XCTAssertNil(UTType(mimeType: mimeType))
            let data = payload(count: 16)
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let fixture = RangeFixtureServer(
                payload: data,
                behavior: .valid206(etag: "\"task9-generation\"")
            )
            let driver = makeDriver(transport: fixture, tokens: tokens)
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(
                    contentLength: Int64(data.count),
                    mimeType: mimeType
                ),
                attempt: tokens.currentSourceAttempt
            )
            let request = RecordingResourceLoadingRequest(dataDemand: nil)

            handle.loader.startLoading(request, requestID: UUID())
            await request.waitUntilTerminal()

            guard let information = request.observation().contentInformation else {
                XCTFail("invalid MIME row did not publish content information")
                continue
            }
            XCTAssertEqual(information.contentType, fallbackIdentifier)
            guard let contentType = information.contentType else {
                XCTFail("invalid MIME row published a nil fallback")
                continue
            }
            XCTAssertFalse(contentType.isEmpty)
            XCTAssertEqual(information.contentLength, Int64(data.count))
            XCTAssertEqual(request.observation().finishCount, 1)
        }
    }

    func testResourceCallbackDoesNotHoldControlLockNeededByDelegateQueueCancellation()
        async throws
    {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let loader = handle.loader
        let requestID = UUID()
        let request = RangeCancellationDuringResponseRequest(
            dataDemand: ResourceLoadingDataDemand(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            ),
            delegateQueue: handle.delegateQueue,
            cancelAndCheckLease: {
                loader.didCancel(
                    sessionID: tokens.sessionID,
                    sourceAttemptID: tokens.currentSourceAttempt.id,
                    requestID: requestID
                )
                return !loader.hasActiveLease(tokens: tokens, requestID: requestID)
            }
        )

        loader.startLoading(request, requestID: requestID)
        await request.waitUntilCancellationEntered()
        await request.waitUntilCancellationReturned()
        await exitProbe.waitUntilRecorded()

        let observation = request.observation()
        XCTAssertTrue(observation.cancellationEntered)
        XCTAssertTrue(observation.cancellationReturned)
        XCTAssertTrue(observation.cancellationReturnedBeforeResponseReturned)
        XCTAssertTrue(observation.leaseWasAbsentWhenCancellationReturned)
        XCTAssertFalse(loader.hasActiveLease(tokens: tokens, requestID: requestID))
        XCTAssertEqual(loader.activeRequestCount, 0)
        XCTAssertEqual(observation.finishCount, 0)
        XCTAssertEqual(observation.errorFinishCount, 0)
    }

    func testCancellationBeforeRequestTaskEntryStartsNoWork() async throws {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let candidates = RangeCandidateSpy(fullPayload: data)
        let requestID = UUID()
        let lifecycle = RangeLifecycleGate(target: .requestTaskEntry(requestID))
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            candidateReader: candidates,
            tokens: tokens,
            requestDidExit: { callbackTokens, callbackRequestID in
                await exitProbe.record(
                    tokens: callbackTokens,
                    requestID: callbackRequestID
                )
            },
            lifecycleHook: { event in await lifecycle.handle(event) }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: requestID)
        await lifecycle.waitUntilHeld()
        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        XCTAssertFalse(handle.loader.hasActiveLease(tokens: tokens, requestID: requestID))
        await lifecycle.release()
        await lifecycle.waitUntilDrained()
        await exitProbe.waitUntilRecorded()

        let candidate = await candidates.observation()
        let transport = await fixture.observation()
        let gate = await lifecycle.observation()
        XCTAssertEqual(gate.tokens, tokens)
        XCTAssertEqual(gate.requestID, requestID)
        XCTAssertEqual(candidate.locateCount, 0)
        XCTAssertEqual(candidate.readCount, 0)
        XCTAssertEqual(candidate.writeCount, 0)
        XCTAssertEqual(transport.generationValidationCount, 0)
        XCTAssertEqual(transport.byteRequestCount, 0)
        XCTAssertNil(request.observation().contentInformation)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 0)
    }

    func testLastGenerationConsumerCancellationBeforeChildTransportStartsZeroWork()
        async throws
    {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let requestID = UUID()
        let upstreamGate = RangeLifecycleGate(
            target: .upstreamTaskStart(requestID, nil)
        )
        let fixture = RangeFixtureServer(
            payload: payload(count: 16),
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, callbackRequestID in
                await exitProbe.record(
                    tokens: callbackTokens,
                    requestID: callbackRequestID
                )
            },
            lifecycleHook: { event in
                await upstreamGate.handle(event)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: 16),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(dataDemand: nil)

        handle.loader.startLoading(request, requestID: requestID)
        await upstreamGate.waitUntilHeld()
        let held = await upstreamGate.observation()
        XCTAssertEqual(held.tokens, tokens)
        XCTAssertEqual(held.requestID, requestID)
        XCTAssertNil(held.range)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        XCTAssertFalse(
            handle.loader.hasActiveLease(tokens: tokens, requestID: requestID)
        )
        let beforeRelease = await fixture.observation()
        XCTAssertEqual(beforeRelease.generationValidationCount, 0)
        XCTAssertEqual(beforeRelease.generationProbeBodyBytes, 0)
        XCTAssertEqual(beforeRelease.mediaStreamInvocationCount, 0)
        XCTAssertEqual(beforeRelease.byteRequestCount, 0)

        await upstreamGate.release()
        await upstreamGate.waitUntilDrained()
        await exitProbe.waitUntilRecorded()

        let terminal = await fixture.observation()
        XCTAssertEqual(terminal.generationValidationCount, 0)
        XCTAssertEqual(terminal.generationProbeBodyBytes, 0)
        XCTAssertEqual(terminal.mediaStreamInvocationCount, 0)
        XCTAssertEqual(terminal.byteRequestCount, 0)
        XCTAssertNil(request.observation().contentInformation)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 0)
    }

    func testLastFetchConsumerCancellationBeforeChildTransportStartsZeroWork()
        async throws
    {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let requestID = UUID()
        let mediaRange: Range<Int64> = 0..<Int64(data.count)
        let upstreamGate = RangeLifecycleGate(
            target: .upstreamTaskStart(requestID, mediaRange)
        )
        let terminalGate = RangeLifecycleGate(
            target: .fetchTerminalReservation(requestID, mediaRange)
        )
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsEveryByteRequestBeforeBody
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, callbackRequestID in
                await exitProbe.record(
                    tokens: callbackTokens,
                    requestID: callbackRequestID
                )
            },
            lifecycleHook: { event in
                await upstreamGate.handle(event)
                await terminalGate.handle(event)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: requestID)
        await upstreamGate.waitUntilHeld()
        let heldUpstream = await upstreamGate.observation()
        XCTAssertEqual(heldUpstream.tokens, tokens)
        XCTAssertEqual(heldUpstream.requestID, requestID)
        XCTAssertEqual(heldUpstream.range, mediaRange)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        XCTAssertFalse(
            handle.loader.hasActiveLease(tokens: tokens, requestID: requestID)
        )
        await upstreamGate.release()
        await upstreamGate.waitUntilDrained()
        await terminalGate.waitUntilHeld()

        let beforeReservationRelease = await fixture.observation()
        XCTAssertEqual(beforeReservationRelease.generationValidationCount, 1)
        XCTAssertEqual(beforeReservationRelease.generationProbeBodyBytes, 1)
        XCTAssertEqual(beforeReservationRelease.mediaStreamInvocationCount, 0)
        XCTAssertEqual(beforeReservationRelease.byteRequestCount, 0)
        XCTAssertEqual(beforeReservationRelease.mediaResponseBodyBytes, 0)
        XCTAssertEqual(beforeReservationRelease.cancellationCount, 0)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 0)

        await terminalGate.release()
        await terminalGate.waitUntilDrained()
        if beforeReservationRelease.mediaStreamInvocationCount > 0 {
            await fixture.waitUntilCancellationCount(1)
            await fixture.releaseStalledRequests()
            await fixture.waitUntilLateCallbackDrainCount(1)
        } else {
            await fixture.releaseStalledRequests()
        }
        await exitProbe.waitUntilRecorded()

        let terminal = await fixture.observation()
        XCTAssertEqual(terminal.mediaStreamInvocationCount, 0)
        XCTAssertEqual(terminal.byteRequestCount, 0)
        XCTAssertEqual(terminal.mediaResponseBodyBytes, 0)
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 0)
    }

    func testAuthorizationDenialAtPermitBoundaryTerminatesInsteadOfSuspending()
        async throws
    {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let featureBox = RangeFeatureSnapshotBox(
            enabledSnapshot(epoch: authorizedEpoch)
        )
        let requestID = UUID()
        let lifecycle = RangeLifecycleGate(target: .permitResolution(requestID))
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            featureBox: featureBox,
            requestDidExit: { callbackTokens, callbackRequestID in
                await exitProbe.record(
                    tokens: callbackTokens,
                    requestID: callbackRequestID
                )
            },
            lifecycleHook: { event in await lifecycle.handle(event) }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: requestID)
        await lifecycle.waitUntilHeld()
        featureBox.update(enabledSnapshot(epoch: authorizedEpoch + 1))
        await lifecycle.release()
        await lifecycle.waitUntilDrained()
        async let didTerminate = request.waitUntilTerminalResult()
        async let didSuspend = handle.loader.waitUntilDemandSuspended(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID,
            timeoutNanoseconds: 5_000_000_000
        )
        let terminalResult = await didTerminate
        let suspensionResult = await didSuspend
        if !terminalResult {
            handle.loader.didCancel(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: requestID
            )
        }
        await exitProbe.waitUntilRecorded()

        let transport = await fixture.observation()
        XCTAssertTrue(terminalResult)
        XCTAssertFalse(suspensionResult)
        XCTAssertEqual(
            request.observation().error as? RangeLoaderError,
            .staleKillSwitchEpoch
        )
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(transport.byteRequestCount, 0)
    }

    func testCandidateReadHasImmediateAuthorizationBoundary() async throws {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let candidates = RangeCandidateSpy(fullPayload: data)
        let featureBox = RangeFeatureSnapshotBox(
            enabledSnapshot(epoch: authorizedEpoch)
        )
        let requestID = UUID()
        let lifecycle = RangeLifecycleGate(target: .candidateRead(requestID))
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            candidateReader: candidates,
            tokens: tokens,
            featureBox: featureBox,
            requestDidExit: { callbackTokens, callbackRequestID in
                await exitProbe.record(
                    tokens: callbackTokens,
                    requestID: callbackRequestID
                )
            },
            lifecycleHook: { event in await lifecycle.handle(event) }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: requestID)
        await lifecycle.waitUntilHeld()
        let heldCandidate = await candidates.observation()
        XCTAssertEqual(heldCandidate.locateCount, 1)
        XCTAssertEqual(heldCandidate.readCount, 0)
        featureBox.update(enabledSnapshot(epoch: authorizedEpoch + 1))
        await lifecycle.release()
        await lifecycle.waitUntilDrained()
        await request.waitUntilTerminal()
        await exitProbe.waitUntilRecorded()

        let candidate = await candidates.observation()
        let transport = await fixture.observation()
        let gate = await lifecycle.observation()
        XCTAssertEqual(gate.tokens, tokens)
        XCTAssertEqual(gate.requestID, requestID)
        XCTAssertEqual(gate.range, 0..<Int64(data.count))
        XCTAssertEqual(candidate.readCount, 0)
        XCTAssertEqual(candidate.writeCount, 0)
        XCTAssertEqual(transport.generationValidationCount, 1)
        XCTAssertEqual(transport.byteRequestCount, 0)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(
            request.observation().error as? RangeLoaderError,
            .staleKillSwitchEpoch
        )
    }

    func testNewSeekStartsFullTokenFetchWhileOldDetachIsHeld() async throws {
        let chunkBytes = 64 * 1024
        let data = payload(count: 96 * 1024)
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        _ = try XCTUnwrap(tokens.beginSeek(targetSeconds: 5))
        let oldTokens = tokens
        let oldRequestID = UUID()
        let lifecycle = RangeLifecycleGate(target: .staleDetach(oldRequestID))
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsEveryByteRequestBeforeBody,
            expectedTokens: oldTokens
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: oldTokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            },
            lifecycleHook: { event in await lifecycle.handle(event) }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: oldTokens.currentSourceAttempt
        )
        let oldRequest = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(oldRequest, requestID: oldRequestID)
        await fixture.waitUntilStalledRequestCount(1)

        _ = try XCTUnwrap(tokens.beginSeek(targetSeconds: 9))
        await fixture.expectTokens(tokens, resetObservation: true)
        XCTAssertTrue(driver.activate(tokens: tokens))
        await lifecycle.waitUntilHeld()
        let preReplacement = await fixture.observation()
        XCTAssertEqual(preReplacement.cancellationCount, 0)
        XCTAssertFalse(
            handle.loader.hasActiveLease(tokens: oldTokens, requestID: oldRequestID)
        )

        let newRequestID = UUID()
        let newRequest = RecordingResourceLoadingRequest(
            requestedOffset: Int64(chunkBytes / 2),
            currentOffset: Int64(chunkBytes / 2),
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(newRequest, requestID: newRequestID)
        await fixture.waitUntilStalledRequestCount(2)

        let held = await fixture.observation()
        XCTAssertEqual(
            held.mediaRequestedRanges,
            [0..<Int64(chunkBytes), Int64(chunkBytes / 2)..<Int64(96 * 1024)]
        )
        XCTAssertEqual(held.matchingTokenRequestCount, 1)
        XCTAssertEqual(held.mismatchingTokenRequestCount, 0)
        XCTAssertTrue(
            handle.loader.hasActiveLease(tokens: tokens, requestID: newRequestID)
        )
        let gate = await lifecycle.observation()
        XCTAssertEqual(gate.tokens, oldTokens)
        XCTAssertEqual(gate.requestID, oldRequestID)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: newRequestID
        )
        await lifecycle.release()
        await lifecycle.waitUntilDrained()
        await fixture.waitUntilCancellationCount(2)
        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(2)
        await exitProbe.waitUntilRecorded(2)

        XCTAssertTrue(oldRequest.observation().respondedData.isEmpty)
        XCTAssertTrue(newRequest.observation().respondedData.isEmpty)
        XCTAssertEqual(oldRequest.observation().finishCount, 0)
        XCTAssertEqual(newRequest.observation().finishCount, 0)
        XCTAssertEqual(oldRequest.observation().errorFinishCount, 0)
        XCTAssertEqual(newRequest.observation().errorFinishCount, 0)
    }

    func testSharedGenerationProbeCancelsOnlyAfterLastRegisteredConsumerLeaves()
        async throws
    {
        let dataLength: Int64 = 16
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let transport = RangeHeldGenerationTransport(payloadLength: dataLength)
        let lifecycle = RangeLifecycleGate(target: .generationConsumerCount(2))
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: transport,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            },
            lifecycleHook: { event in await lifecycle.handle(event) }
        )
        let descriptor = makeDescriptor(contentLength: dataLength)
        let firstHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let secondHandle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = RecordingResourceLoadingRequest(dataDemand: nil)
        let second = RecordingResourceLoadingRequest(dataDemand: nil)

        firstHandle.loader.startLoading(first, requestID: firstID)
        await transport.waitUntilValidationCount(1)
        secondHandle.loader.startLoading(second, requestID: secondID)
        await lifecycle.waitUntilHeld()
        let attached = await lifecycle.observation()
        let sharedBeforeCancellation = await transport.observation()
        XCTAssertEqual(attached.consumerCount, 2)
        XCTAssertEqual(sharedBeforeCancellation.validationCount, 1)

        firstHandle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: firstID
        )
        await exitProbe.waitUntilRecorded()
        let afterFirstCancellation = await transport.observation()
        XCTAssertEqual(afterFirstCancellation.cancellationCount, 0)
        XCTAssertTrue(
            secondHandle.loader.hasActiveLease(tokens: tokens, requestID: secondID)
        )

        await lifecycle.release()
        await lifecycle.waitUntilDrained()
        secondHandle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID
        )
        await transport.waitUntilCancellationCount(1)
        await transport.release()
        await exitProbe.waitUntilRecorded(2)

        let terminal = await transport.observation()
        XCTAssertEqual(terminal.validationCount, 1)
        XCTAssertEqual(terminal.cancellationCount, 1)
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertTrue(second.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testGenerationValidationRestartsAfterLastConsumerCancellation()
        async throws
    {
        let dataLength: Int64 = 16
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let transport = RangeHeldGenerationTransport(payloadLength: dataLength)
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: transport,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: dataLength),
            attempt: tokens.currentSourceAttempt
        )
        let firstID = UUID()
        let first = RecordingResourceLoadingRequest(dataDemand: nil)

        handle.loader.startLoading(first, requestID: firstID)
        await transport.waitUntilValidationCount(1)
        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: firstID
        )
        await transport.waitUntilCancellationCount(1)
        await transport.release()
        await exitProbe.waitUntilRecorded()

        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)

        let second = RecordingResourceLoadingRequest(dataDemand: nil)
        handle.loader.startLoading(second, requestID: UUID())
        await transport.waitUntilValidationCount(2)
        await second.waitUntilTerminal()
        await exitProbe.waitUntilRecorded(2)

        let terminalTransport = await transport.observation()
        XCTAssertEqual(terminalTransport.validationCount, 2)
        XCTAssertEqual(terminalTransport.cancellationCount, 1)
        XCTAssertNotNil(second.observation().contentInformation)
        XCTAssertEqual(second.observation().finishCount, 1)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
        XCTAssertNil(second.observation().error)
    }

    func testNewSeekGenerationConsumerDoesNotJoinOldTokenRun() async throws {
        let dataLength: Int64 = 16
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        _ = try XCTUnwrap(tokens.beginSeek(targetSeconds: 5))
        let oldTokens = tokens
        _ = try XCTUnwrap(tokens.beginSeek(targetSeconds: 9))
        let newTokens = tokens
        let oldID = UUID()
        let newID = UUID()
        let detachGate = RangeLifecycleGate(
            target: .generationConsumerDetach(oldID)
        )
        let attachGate = RangeLifecycleGate(
            target: .generationConsumerCount(2)
        )
        let transport = RangeHeldGenerationTransport(
            payloadLength: dataLength,
            expectedValidationTokens: [oldTokens, newTokens],
            expectedCancellationTokens: [oldTokens, newTokens]
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: transport,
            tokens: oldTokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            },
            lifecycleHook: { event in
                await detachGate.handle(event)
                await attachGate.handle(event)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: dataLength),
            attempt: oldTokens.currentSourceAttempt
        )
        let oldRequest = RecordingResourceLoadingRequest(dataDemand: nil)
        handle.loader.startLoading(oldRequest, requestID: oldID)
        await transport.waitUntilValidationCount(1)

        XCTAssertTrue(driver.activate(tokens: newTokens))
        await detachGate.waitUntilHeld()
        XCTAssertFalse(
            handle.loader.hasActiveLease(tokens: oldTokens, requestID: oldID)
        )

        let newRequest = RecordingResourceLoadingRequest(dataDemand: nil)
        handle.loader.startLoading(newRequest, requestID: newID)
        await attachGate.waitUntilHeld()
        let attached = await attachGate.observation()
        XCTAssertEqual(attached.tokens, newTokens)
        XCTAssertEqual(attached.requestID, newID)
        XCTAssertEqual(attached.consumerCount, 2)
        await attachGate.release()
        await attachGate.waitUntilDrained()

        let heldDetach = await detachGate.observation()
        XCTAssertEqual(heldDetach.tokens, oldTokens)
        XCTAssertEqual(heldDetach.requestID, oldID)
        await detachGate.release()
        await detachGate.waitUntilDrained()
        await transport.waitUntilCancellationCount(1)
        await transport.waitUntilValidationCount(2)

        let replacementRunning = await transport.observation()
        XCTAssertEqual(replacementRunning.validationCount, 2)
        XCTAssertEqual(replacementRunning.cancellationCount, 1)
        XCTAssertEqual(replacementRunning.matchingValidationTokenCount, 2)
        XCTAssertEqual(replacementRunning.mismatchingValidationTokenCount, 0)
        XCTAssertEqual(replacementRunning.matchingCancellationTokenCount, 1)
        XCTAssertEqual(replacementRunning.mismatchingCancellationTokenCount, 0)
        XCTAssertTrue(
            handle.loader.hasActiveLease(tokens: newTokens, requestID: newID)
        )
        XCTAssertTrue(oldRequest.observation().respondedData.isEmpty)
        XCTAssertTrue(newRequest.observation().respondedData.isEmpty)
        XCTAssertEqual(oldRequest.observation().finishCount, 0)
        XCTAssertEqual(newRequest.observation().finishCount, 0)

        handle.loader.didCancel(
            sessionID: newTokens.sessionID,
            sourceAttemptID: newTokens.currentSourceAttempt.id,
            requestID: newID
        )
        await transport.waitUntilCancellationCount(2)
        await transport.release()
        await exitProbe.waitUntilRecorded(2)

        let terminal = await transport.observation()
        XCTAssertEqual(terminal.validationCount, 2)
        XCTAssertEqual(terminal.cancellationCount, 2)
        XCTAssertEqual(terminal.matchingValidationTokenCount, 2)
        XCTAssertEqual(terminal.mismatchingValidationTokenCount, 0)
        XCTAssertEqual(terminal.matchingCancellationTokenCount, 2)
        XCTAssertEqual(terminal.mismatchingCancellationTokenCount, 0)
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
        XCTAssertEqual(oldRequest.observation().errorFinishCount, 0)
        XCTAssertEqual(newRequest.observation().errorFinishCount, 0)
    }

    func testCancelledGenerationConsumerCannotAuthorizeCompletedRunCache()
        async throws
    {
        let dataLength: Int64 = 16
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let firstID = UUID()
        let secondID = UUID()
        let detachGate = RangeLifecycleGate(
            target: .generationConsumerDetach(firstID)
        )
        let reconcileGate = RangeLifecycleGate(
            target: .generationRunReconcile(firstID)
        )
        let transport = RangeHeldGenerationTransport(
            payloadLength: dataLength,
            expectedValidationTokens: [tokens, tokens]
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: transport,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            },
            lifecycleHook: { event in
                await detachGate.handle(event)
                await reconcileGate.handle(event)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: dataLength),
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(dataDemand: nil)
        handle.loader.startLoading(first, requestID: firstID)
        await transport.waitUntilValidationCount(1)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: firstID
        )
        await detachGate.waitUntilHeld()
        await transport.releaseSuccessfully()
        await reconcileGate.waitUntilHeld()

        let reconciled = await reconcileGate.observation()
        XCTAssertEqual(reconciled.tokens, tokens)
        XCTAssertEqual(reconciled.requestID, firstID)
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertNil(first.observation().contentInformation)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)

        let second = RecordingResourceLoadingRequest(dataDemand: nil)
        handle.loader.startLoading(second, requestID: secondID)
        await transport.waitUntilValidationCount(2)
        await second.waitUntilTerminal()

        let replacement = await transport.observation()
        XCTAssertEqual(replacement.validationCount, 2)
        XCTAssertEqual(replacement.matchingValidationTokenCount, 2)
        XCTAssertEqual(replacement.mismatchingValidationTokenCount, 0)
        XCTAssertNotNil(second.observation().contentInformation)
        XCTAssertEqual(second.observation().finishCount, 1)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
        XCTAssertNil(second.observation().error)

        await reconcileGate.release()
        await reconcileGate.waitUntilDrained()
        await detachGate.release()
        await detachGate.waitUntilDrained()
        await exitProbe.waitUntilRecorded(2)

        let terminal = await transport.observation()
        XCTAssertEqual(terminal.validationCount, 2)
        XCTAssertEqual(terminal.cancellationCount, 0)
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
    }

    func testPendingGenerationAuthorizationClassificationCannotOrphanConsumer()
        async throws
    {
        let enabled = enabledSnapshot(epoch: authorizedEpoch)
        let stale = enabledSnapshot(epoch: authorizedEpoch + 1)
        let featureBox = try XCTUnwrap(
            RangeFeatureSnapshotBox(
                scriptedSnapshots: Array(repeating: enabled, count: 4) + [stale]
            )
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: payload(count: 16),
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            featureBox: featureBox,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: 16),
            attempt: tokens.currentSourceAttempt
        )
        let requestID = UUID()
        let request = RecordingResourceLoadingRequest(dataDemand: nil)

        handle.loader.startLoading(request, requestID: requestID)
        let terminated = await request.waitUntilTerminalResult()
        if !terminated {
            handle.loader.didCancel(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: requestID
            )
        }
        await exitProbe.waitUntilRecorded()

        let transport = await fixture.observation()
        XCTAssertTrue(terminated)
        // Read #5 denies at the child-task transport boundary; read #6
        // preserves that typed denial while the run reconciles.
        XCTAssertEqual(featureBox.invocationCount(), 6)
        XCTAssertEqual(transport.generationValidationCount, 0)
        XCTAssertEqual(transport.byteRequestCount, 0)
        XCTAssertNil(request.observation().contentInformation)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 1)
        XCTAssertEqual(
            request.observation().error as? RangeLoaderError,
            .staleKillSwitchEpoch
        )
    }

    func testCurrentOffsetRequestsOnlyTheUnfulfilledAbsoluteRemainder() async throws {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 4,
            requestedLength: 12,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        let observation = await fixture.observation()
        XCTAssertEqual(observation.mediaRequestedRanges, [4..<12])
        XCTAssertEqual(observation.byteRequestCount, 1)
        XCTAssertEqual(
            request.observation().respondedData,
            data.subdata(in: 4..<12)
        )
        XCTAssertEqual(request.observation().finishCount, 1)
        XCTAssertEqual(request.observation().errorFinishCount, 0)
    }

    func testNonzeroRangeReceiving200FailsStructurallyWithoutResponding() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: payload(count: 16),
            behavior: .ignoresRangeWith200
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 4,
            currentOffset: 4,
            requestedLength: 8,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        let loading = request.observation()
        XCTAssertTrue(loading.respondedData.isEmpty)
        XCTAssertEqual(loading.finishCount, 0)
        XCTAssertEqual(loading.errorFinishCount, 1)
        XCTAssertEqual(loading.error as? RangeLoaderError, .structuralResponse)
        let fixtureObservation = await fixture.observation()
        XCTAssertEqual(fixtureObservation.mediaResponseBodyBytes, 0)
    }

    func testAllDataToEndStaysOpenAfterBoundedChunkAndFinishesOnlyAtEOF()
        async throws
    {
        let chunkBytes = 64 * 1024
        let data = payload(count: chunkBytes * 2)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsAfterBytes(Int64(chunkBytes)),
            maximumChunkBytes: chunkBytes
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: 1,
            requestsAllDataToEndOfResource: true
        )

        handle.loader.startLoading(request, requestID: UUID())
        await fixture.waitUntilStalledRequestCount(1)
        await request.waitUntilRespondedByteCount(chunkBytes)

        let held = request.observation()
        XCTAssertEqual(held.respondedData.count, chunkBytes)
        XCTAssertEqual(held.finishCount, 0)
        XCTAssertEqual(held.errorFinishCount, 0)
        let heldTransport = await fixture.observation()
        let heldMediaRanges = heldTransport.requestedRanges.compactMap { $0 }
            .filter { $0 != 0..<1 }
        XCTAssertEqual(heldMediaRanges, [0..<Int64(chunkBytes)])
        XCTAssertEqual(heldTransport.mediaResponseBodyBytes, Int64(chunkBytes))
        XCTAssertEqual(
            heldTransport.validatedChunkCumulativeBodyBytes,
            [Int64(chunkBytes) + 1]
        )

        await fixture.releaseStalledRequests()
        await request.waitUntilTerminal()

        let terminal = request.observation()
        XCTAssertEqual(terminal.respondedData, data)
        XCTAssertEqual(terminal.finishCount, 1)
        XCTAssertEqual(terminal.errorFinishCount, 0)
        let transport = await fixture.observation()
        XCTAssertEqual(transport.mediaResponseBodyBytes, Int64(data.count))
        XCTAssertEqual(transport.servedRangeUnion, [0..<Int64(data.count)])
        XCTAssertEqual(
            try XCTUnwrap(transport.validatedChunkCumulativeBodyBytes.last),
            Int64(data.count) + 1
        )
    }

    func testAllDataToEndWaitsWhenAttemptBudgetIsExhaustedBeforeEOF()
        async throws
    {
        let controller = makeDemandController()
        let constrained = NetworkSnapshot.wifi(expensive: false, constrained: true)
        let attemptBudget = controller.activeTrackByteBudget(
            playedSeconds: 0,
            network: constrained
        )
        let mediaBudget = attemptBudget - 1 // The generation probe is body byte one.
        let data = payload(count: Int(attemptBudget + 64 * 1024))
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: 0..<4_096,
            indexRange: 2_048..<8_192
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let requestExitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            network: constrained,
            requestDidExit: { callbackTokens, requestID in
                await requestExitProbe.record(
                    tokens: callbackTokens,
                    requestID: requestID
                )
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let requestID = UUID()
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: 1,
            requestsAllDataToEndOfResource: true
        )

        handle.loader.startLoading(request, requestID: requestID)
        let suspended = await handle.loader.waitUntilDemandSuspended(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID,
            timeoutNanoseconds: 5_000_000_000
        )
        XCTAssertTrue(suspended)

        let transport = await fixture.observation()
        XCTAssertEqual(transport.generationProbeBodyBytes, 1)
        XCTAssertEqual(transport.byteRequestCount, 2)
        XCTAssertEqual(transport.mediaResponseBodyBytes, mediaBudget)
        XCTAssertEqual(
            try XCTUnwrap(transport.validatedChunkCumulativeBodyBytes.last),
            attemptBudget
        )
        XCTAssertEqual(
            transport.mediaRequestedRanges,
            [
                0..<Int64(64 * 1024),
                Int64(64 * 1024)..<mediaBudget,
            ]
        )
        XCTAssertEqual(
            transport.mediaByteCeilings,
            [mediaBudget, mediaBudget - Int64(64 * 1024)]
        )
        XCTAssertEqual(request.observation().respondedData.count, Int(mediaBudget))
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 0)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        XCTAssertFalse(
            handle.loader.hasActiveLease(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: requestID
            )
        )
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
        await requestExitProbe.waitUntilRecorded()
        let exitedIdentity = await requestExitProbe.identity()
        XCTAssertEqual(exitedIdentity?.tokens, tokens)
        XCTAssertEqual(exitedIdentity?.requestID, requestID)
        let cancelledTransport = await fixture.observation()
        XCTAssertEqual(cancelledTransport.cancellationCount, 0)
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 0)
    }

    func testAllDataToEndReevaluatesDemandAfterPlaybackProgressAdvances()
        async throws
    {
        let controller = makeDemandController()
        let constrained = NetworkSnapshot.wifi(expensive: false, constrained: true)
        let initialBudget = controller.activeTrackByteBudget(
            playedSeconds: 0,
            network: constrained
        )
        let initialMediaBudget = initialBudget - 1
        let data = payload(count: Int(initialMediaBudget + 64 * 1024))
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: 0..<4_096,
            indexRange: 2_048..<8_192
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            network: constrained
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let requestID = UUID()
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: 1,
            requestsAllDataToEndOfResource: true
        )

        handle.loader.startLoading(request, requestID: requestID)
        let suspended = await handle.loader.waitUntilDemandSuspended(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID,
            timeoutNanoseconds: 5_000_000_000
        )
        XCTAssertTrue(suspended)
        let suspendedTransport = await fixture.observation()
        XCTAssertEqual(suspendedTransport.byteRequestCount, 2)
        XCTAssertEqual(
            suspendedTransport.mediaResponseBodyBytes,
            initialMediaBudget
        )
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 0)

        XCTAssertTrue(
            driver.updatePlaybackProgress(
                tokens: tokens,
                playedSeconds: 5,
                bufferedSeconds: 0
            )
        )
        await request.waitUntilTerminal()

        let terminal = request.observation()
        let terminalTransport = await fixture.observation()
        XCTAssertEqual(terminal.respondedData, data)
        XCTAssertEqual(terminal.finishCount, 1)
        XCTAssertEqual(terminal.errorFinishCount, 0)
        XCTAssertEqual(terminalTransport.byteRequestCount, 3)
        XCTAssertEqual(
            terminalTransport.mediaRequestedRanges,
            [
                0..<Int64(64 * 1024),
                Int64(64 * 1024)..<initialMediaBudget,
                initialMediaBudget..<Int64(data.count),
            ]
        )
        XCTAssertEqual(terminalTransport.mediaResponseBodyBytes, Int64(data.count))
        XCTAssertEqual(
            try XCTUnwrap(terminalTransport.validatedChunkCumulativeBodyBytes.last),
            Int64(data.count) + 1
        )
    }

    func testConcurrentDisjointFetchesReserveAttemptBudgetBeforeTransportBytesArrive()
        async throws
    {
        let chunkBytes = 64 * 1024
        let attemptBudget: Int64 = 65_537
        let data = payload(count: chunkBytes * 2)
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: nil,
            indexRange: nil,
            bitrate: 31_775
        )
        let controller = RangeDemandController(
            bitrate: descriptor.bitrate,
            initializationRange: descriptor.initializationRange,
            indexRange: descriptor.indexRange,
            authorizedKillSwitchEpoch: authorizedEpoch
        )
        XCTAssertEqual(
            controller.activeTrackByteBudget(
                playedSeconds: 0,
                network: .wifi(expensive: false, constrained: false)
            ),
            attemptBudget
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsEveryByteRequestBeforeBody
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        let second = RecordingResourceLoadingRequest(
            requestedOffset: Int64(chunkBytes),
            currentOffset: Int64(chunkBytes),
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(first, requestID: firstID)
        await fixture.waitUntilStalledRequestCount(1)
        handle.loader.startLoading(second, requestID: secondID)
        let secondSuspended = await handle.loader.waitUntilDemandSuspended(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID,
            timeoutNanoseconds: 5_000_000_000
        )

        let held = await fixture.observation()
        XCTAssertTrue(secondSuspended)
        XCTAssertEqual(held.generationValidationCount, 1)
        XCTAssertEqual(held.generationProbeBodyBytes, 1)
        XCTAssertEqual(held.byteRequestCount, 1)
        XCTAssertEqual(held.mediaRequestedRanges, [0..<Int64(chunkBytes)])
        XCTAssertEqual(held.mediaByteCeilings, [attemptBudget - 1])
        XCTAssertEqual(held.mediaResponseBodyBytes, 0)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID
        )
        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: firstID
        )
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
        await fixture.waitUntilCancellationCount(1)
        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(1)
        await exitProbe.waitUntilRecorded(2)

        let terminalTransport = await fixture.observation()
        XCTAssertEqual(terminalTransport.byteRequestCount, 1)
        XCTAssertEqual(terminalTransport.cancellationCount, 1)
        XCTAssertEqual(terminalTransport.lateCallbackDrainCount, 1)
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertTrue(second.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testSuspendedDisjointDemandStartsAfterActiveFetchCancellationAcknowledges()
        async throws
    {
        let chunkBytes = 64 * 1024
        let attemptBudget: Int64 = 65_537
        let data = payload(count: chunkBytes * 2)
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: nil,
            indexRange: nil,
            bitrate: 31_775
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsEveryByteRequestBeforeBody
        )
        let firstID = UUID()
        let secondID = UUID()
        let lifecycle = RangeLifecycleGate(
            target: .fetchTerminalReservation(
                firstID,
                0..<Int64(chunkBytes)
            )
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            },
            lifecycleHook: { event in await lifecycle.handle(event) }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        let second = RecordingResourceLoadingRequest(
            requestedOffset: Int64(chunkBytes),
            currentOffset: Int64(chunkBytes),
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(first, requestID: firstID)
        await fixture.waitUntilStalledRequestCount(1)
        handle.loader.startLoading(second, requestID: secondID)
        let suspended = await handle.loader.waitUntilDemandSuspended(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID,
            timeoutNanoseconds: 5_000_000_000
        )

        let beforeCancellation = await fixture.observation()
        XCTAssertTrue(suspended)
        XCTAssertEqual(beforeCancellation.byteRequestCount, 1)
        XCTAssertEqual(
            beforeCancellation.mediaRequestedRanges,
            [0..<Int64(chunkBytes)]
        )
        XCTAssertEqual(beforeCancellation.mediaByteCeilings, [attemptBudget - 1])
        XCTAssertTrue(second.observation().respondedData.isEmpty)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: firstID
        )
        await lifecycle.waitUntilHeld()

        let beforeReservationRelease = await fixture.observation()
        let heldLifecycle = await lifecycle.observation()
        XCTAssertEqual(heldLifecycle.tokens, tokens)
        XCTAssertEqual(heldLifecycle.requestID, firstID)
        XCTAssertEqual(heldLifecycle.range, 0..<Int64(chunkBytes))
        XCTAssertEqual(beforeReservationRelease.byteRequestCount, 1)
        XCTAssertTrue(
            handle.loader.hasActiveLease(tokens: tokens, requestID: secondID)
        )
        XCTAssertTrue(second.observation().respondedData.isEmpty)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)

        await lifecycle.release()
        await lifecycle.waitUntilDrained()
        await fixture.waitUntilCancellationCount(1)
        await fixture.waitUntilByteRequestCount(2)
        await fixture.waitUntilStalledRequestCount(2)

        let afterAcknowledgement = await fixture.observation()
        XCTAssertEqual(afterAcknowledgement.byteRequestCount, 2)
        XCTAssertEqual(
            afterAcknowledgement.mediaRequestedRanges,
            [
                0..<Int64(chunkBytes),
                Int64(chunkBytes)..<Int64(chunkBytes * 2),
            ]
        )
        XCTAssertEqual(
            afterAcknowledgement.mediaByteCeilings,
            [attemptBudget - 1, attemptBudget - 1]
        )
        XCTAssertTrue(
            handle.loader.hasActiveLease(tokens: tokens, requestID: secondID)
        )

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID
        )
        await fixture.waitUntilCancellationCount(2)
        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(2)
        await exitProbe.waitUntilRecorded(2)

        let terminal = await fixture.observation()
        XCTAssertEqual(terminal.byteRequestCount, 2)
        XCTAssertEqual(terminal.cancellationCount, 2)
        XCTAssertEqual(terminal.lateCallbackDrainCount, 2)
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertTrue(second.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testCancelledValidatedChunkStillReducesNextPermitBudget() async throws {
        let firstChunkBytes: Int64 = 8_192
        let attemptBudget: Int64 = 65_537
        let data = payload(count: 128 * 1024)
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: nil,
            indexRange: nil,
            bitrate: 31_775
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let firstID = UUID()
        let secondID = UUID()
        let lifecycle = RangeLifecycleGate(
            target: .transportChunkAccounting(
                firstID,
                0..<firstChunkBytes,
                firstChunkBytes + 1
            )
        )
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsMediaRequestBeforeBody(2)
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            },
            lifecycleHook: { event in await lifecycle.handle(event) }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: Int(firstChunkBytes),
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(first, requestID: firstID)
        await lifecycle.waitUntilHeld()

        let beforeAccounting = await fixture.observation()
        let heldLifecycle = await lifecycle.observation()
        XCTAssertEqual(heldLifecycle.tokens, tokens)
        XCTAssertEqual(heldLifecycle.requestID, firstID)
        XCTAssertEqual(heldLifecycle.range, 0..<firstChunkBytes)
        XCTAssertEqual(beforeAccounting.byteRequestCount, 1)
        XCTAssertEqual(beforeAccounting.mediaResponseBodyBytes, firstChunkBytes)
        XCTAssertEqual(
            beforeAccounting.validatedChunkCumulativeBodyBytes,
            [firstChunkBytes + 1]
        )
        XCTAssertTrue(first.observation().respondedData.isEmpty)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: firstID
        )
        await lifecycle.release()
        await lifecycle.waitUntilDrained()
        await exitProbe.waitUntilRecorded()

        let second = RecordingResourceLoadingRequest(
            requestedOffset: firstChunkBytes,
            currentOffset: firstChunkBytes,
            requestedLength: 64 * 1024,
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(second, requestID: secondID)
        await fixture.waitUntilStalledRequestCount(1)

        let remainingBudget = attemptBudget - 1 - firstChunkBytes
        let afterCancellation = await fixture.observation()
        XCTAssertEqual(afterCancellation.byteRequestCount, 2)
        XCTAssertEqual(
            afterCancellation.mediaRequestedRanges,
            [
                0..<firstChunkBytes,
                firstChunkBytes..<(firstChunkBytes + remainingBudget),
            ]
        )
        XCTAssertEqual(
            afterCancellation.mediaByteCeilings,
            [attemptBudget - 1, remainingBudget]
        )
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
        XCTAssertTrue(second.observation().respondedData.isEmpty)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID
        )
        await fixture.waitUntilCancellationCount(1)
        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(1)
        await exitProbe.waitUntilRecorded(2)
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testTransportErrorCumulativeBytesReduceNextPermitForSameAttempt()
        async throws
    {
        let errorBodyBytes: Int64 = 8_192
        let attemptBudget: Int64 = 65_537
        let data = payload(count: 128 * 1024)
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: nil,
            indexRange: nil,
            bitrate: 31_775
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .firstMediaRequestAccountsThenFails(
                bodyBytes: errorBodyBytes
            )
        )
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: Int(errorBodyBytes),
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(first, requestID: UUID())
        await first.waitUntilTerminal()
        await exitProbe.waitUntilRecorded()

        let firstTransport = await fixture.observation()
        XCTAssertEqual(firstTransport.mediaResponseBodyBytes, errorBodyBytes)
        XCTAssertEqual(firstTransport.mediaByteCeilings, [attemptBudget - 1])
        XCTAssertTrue(firstTransport.validatedChunkCumulativeBodyBytes.isEmpty)
        XCTAssertTrue(first.observation().respondedData.isEmpty)
        XCTAssertEqual(first.observation().finishCount, 0)
        XCTAssertEqual(first.observation().errorFinishCount, 1)
        XCTAssertEqual(
            first.observation().error as? RangeLoaderError,
            .structuralResponse
        )

        let secondID = UUID()
        let second = RecordingResourceLoadingRequest(
            requestedOffset: errorBodyBytes,
            currentOffset: errorBodyBytes,
            requestedLength: 64 * 1024,
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(second, requestID: secondID)
        await fixture.waitUntilStalledRequestCount(1)

        let remainingBudget = attemptBudget - 1 - errorBodyBytes
        let held = await fixture.observation()
        XCTAssertEqual(held.byteRequestCount, 2)
        XCTAssertEqual(
            held.mediaRequestedRanges,
            [0..<errorBodyBytes, errorBodyBytes..<errorBodyBytes + remainingBudget]
        )
        XCTAssertEqual(
            held.mediaByteCeilings,
            [attemptBudget - 1, remainingBudget]
        )
        XCTAssertEqual(held.mediaResponseBodyBytes, errorBodyBytes)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: secondID
        )
        await fixture.waitUntilCancellationCount(1)
        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(1)
        await exitProbe.waitUntilRecorded(2)
        XCTAssertTrue(second.observation().respondedData.isEmpty)
        XCTAssertEqual(second.observation().finishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testCancellationRequiresExactIdentityAndLateCallbackCannotMutateRequest()
        async throws
    {
        let chunkBytes = 64 * 1024
        let data = payload(count: chunkBytes * 2)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsAfterBytes(Int64(chunkBytes)),
            maximumChunkBytes: chunkBytes
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let requestID = UUID()
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: requestID)
        await fixture.waitUntilStalledRequestCount(1)
        await request.waitUntilRespondedByteCount(chunkBytes)

        handle.loader.didCancel(
            sessionID: PlaybackSessionID.fresh(),
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: SourceAttemptID.fresh(),
            requestID: requestID
        )
        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: UUID()
        )
        XCTAssertTrue(
            handle.loader.hasActiveLease(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: requestID
            )
        )
        let preCancellationTransport = await fixture.observation()
        XCTAssertEqual(preCancellationTransport.cancellationCount, 0)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        XCTAssertFalse(
            handle.loader.hasActiveLease(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: requestID
            )
        )
        await fixture.waitUntilCancellationCount(1)
        let cancelled = request.observation()
        XCTAssertEqual(cancelled.finishCount, 0)
        XCTAssertEqual(cancelled.errorFinishCount, 0)
        XCTAssertNil(cancelled.error)

        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(1)
        let afterLateCallback = request.observation()
        XCTAssertEqual(afterLateCallback.respondedData, cancelled.respondedData)
        XCTAssertEqual(afterLateCallback.finishCount, cancelled.finishCount)
        XCTAssertEqual(
            afterLateCallback.errorFinishCount,
            cancelled.errorFinishCount
        )
    }

    func testExactCancellationRevokesValidatedChunkQueuedBeforeRespond()
        async throws
    {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let responseGate = RangeValidatedChunkResponseGate()
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            validatedChunkWillRespond: { callbackTokens, requestID in
                await responseGate.hold(
                    tokens: callbackTokens,
                    requestID: requestID
                )
            },
            validatedChunkDidAttemptRespond: { callbackTokens, requestID in
                await responseGate.recordRespondAttempt(
                    tokens: callbackTokens,
                    requestID: requestID
                )
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(),
            attempt: tokens.currentSourceAttempt
        )
        let requestID = UUID()
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: requestID)
        await responseGate.waitUntilHeld()
        let heldIdentity = await responseGate.identity()
        XCTAssertEqual(heldIdentity?.tokens, tokens)
        XCTAssertEqual(heldIdentity?.requestID, requestID)
        let heldTransport = await fixture.observation()
        XCTAssertEqual(heldTransport.generationValidationCount, 1)
        XCTAssertEqual(heldTransport.byteRequestCount, 1)
        XCTAssertEqual(heldTransport.mediaResponseBodyBytes, Int64(data.count))
        XCTAssertEqual(
            heldTransport.validatedChunkCumulativeBodyBytes,
            [Int64(data.count) + 1]
        )
        XCTAssertTrue(request.observation().respondedData.isEmpty)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        XCTAssertFalse(
            handle.loader.hasActiveLease(tokens: tokens, requestID: requestID)
        )
        XCTAssertEqual(handle.loader.activeRequestCount, 0)

        await responseGate.release()
        await responseGate.waitUntilDrained()
        await responseGate.waitUntilRespondAttempted()
        let attemptIdentity = await responseGate.respondAttemptIdentity()
        XCTAssertEqual(attemptIdentity?.tokens, tokens)
        XCTAssertEqual(attemptIdentity?.requestID, requestID)
        let terminal = request.observation()
        XCTAssertTrue(terminal.respondedData.isEmpty)
        XCTAssertEqual(terminal.finishCount, 0)
        XCTAssertEqual(terminal.errorFinishCount, 0)
        XCTAssertNil(terminal.error)
    }

    func testActivateTokensRevokesOldSeekLeaseBeforeReplacementFetch() async throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        _ = try XCTUnwrap(tokens.beginSeek(targetSeconds: 5))
        let oldTokens = tokens
        let data = payload(count: 16)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsAfterBytes(0),
            expectedTokens: oldTokens
        )
        let driver = makeDriver(transport: fixture, tokens: oldTokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(),
            attempt: oldTokens.currentSourceAttempt
        )
        let oldRequestID = UUID()
        let oldRequest = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(oldRequest, requestID: oldRequestID)
        await fixture.waitUntilStalledRequestCount(1)

        _ = try XCTUnwrap(tokens.beginSeek(targetSeconds: 9))
        XCTAssertEqual(tokens.sessionID, oldTokens.sessionID)
        XCTAssertEqual(tokens.currentSourceAttempt, oldTokens.currentSourceAttempt)
        XCTAssertNotEqual(tokens.latestSeekAttempt, oldTokens.latestSeekAttempt)
        XCTAssertTrue(driver.activate(tokens: tokens))
        XCTAssertFalse(
            handle.loader.hasActiveLease(tokens: oldTokens, requestID: oldRequestID)
        )
        XCTAssertFalse(
            driver.activate(
                tokens: ActivePlaybackTokens.freshSession(source: .rangeStream)
            )
        )
        var wrongSourceTokens = tokens
        var sourceLock = try XCTUnwrap(
            PlaybackSourceLock(initialRangeAttempt: tokens.currentSourceAttempt)
        )
        _ = try XCTUnwrap(
            wrongSourceTokens.downgradeToLegacy(using: &sourceLock)
        )
        XCTAssertEqual(wrongSourceTokens.sessionID, tokens.sessionID)
        XCTAssertNotEqual(
            wrongSourceTokens.currentSourceAttempt.source,
            tokens.currentSourceAttempt.source
        )
        XCTAssertFalse(driver.activate(tokens: wrongSourceTokens))
        var refreshedRangeTokens = tokens
        let refreshedRangeAttempt = refreshedRangeTokens.refreshCurrentSourceAttempt()
        XCTAssertEqual(refreshedRangeTokens.sessionID, tokens.sessionID)
        XCTAssertEqual(
            refreshedRangeAttempt.source,
            tokens.currentSourceAttempt.source
        )
        XCTAssertNotEqual(refreshedRangeAttempt.id, tokens.currentSourceAttempt.id)
        XCTAssertFalse(driver.activate(tokens: refreshedRangeTokens))

        await fixture.waitUntilCancellationCount(1)
        await fixture.releaseStalledRequests()
        await fixture.waitUntilLateCallbackDrainCount(1)
        let oldTokenObservation = await fixture.observation()
        XCTAssertEqual(oldTokenObservation.matchingTokenRequestCount, 2)
        XCTAssertEqual(oldTokenObservation.mismatchingTokenRequestCount, 0)
        XCTAssertTrue(oldRequest.observation().respondedData.isEmpty)
        XCTAssertEqual(oldRequest.observation().finishCount, 0)
        XCTAssertEqual(oldRequest.observation().errorFinishCount, 0)
        XCTAssertNil(oldRequest.observation().error)

        await fixture.expectTokens(tokens, resetObservation: true)
        let replacement = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: data.count,
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(replacement, requestID: UUID())
        await replacement.waitUntilTerminal()
        XCTAssertEqual(replacement.observation().respondedData, data)
        XCTAssertEqual(replacement.observation().finishCount, 1)
        let replacementTokenObservation = await fixture.observation()
        XCTAssertEqual(replacementTokenObservation.matchingTokenRequestCount, 1)
        XCTAssertEqual(replacementTokenObservation.mismatchingTokenRequestCount, 0)
        XCTAssertEqual(replacementTokenObservation.generationValidationCount, 1)
        XCTAssertEqual(replacementTokenObservation.byteRequestCount, 2)
    }

    func testAuthorizationIsRecheckedBeforeEveryRespondAndNextFetch() async throws {
        let killed = PlaybackFeatureSnapshot(
            rangeStreamingV1: true,
            cohortPercent: 100,
            boundedPreloadV1: false,
            killSwitch: true,
            killSwitchEpoch: authorizedEpoch,
            loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
            headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
        )

        do {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let featureBox = RangeFeatureSnapshotBox(
                enabledSnapshot(epoch: authorizedEpoch)
            )
            let fixture = RangeFixtureServer(
                payload: payload(count: 16),
                behavior: .stallsAfterBytes(0)
            )
            let driver = makeDriver(
                transport: fixture,
                tokens: tokens,
                featureBox: featureBox
            )
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(),
                attempt: tokens.currentSourceAttempt
            )
            let request = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: 16,
                requestsAllDataToEndOfResource: false
            )
            handle.loader.startLoading(request, requestID: UUID())
            await fixture.waitUntilStalledRequestCount(1)
            featureBox.update(killed)
            await fixture.releaseStalledRequests()
            await request.waitUntilTerminal()

            XCTAssertTrue(request.observation().respondedData.isEmpty)
            XCTAssertEqual(
                request.observation().error as? RangeLoaderError,
                .killSwitchEnabled
            )
        }

        do {
            let chunkBytes = 64 * 1024
            let data = payload(count: chunkBytes * 2)
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let featureBox = RangeFeatureSnapshotBox(
                enabledSnapshot(epoch: authorizedEpoch)
            )
            let fixture = RangeFixtureServer(
                payload: data,
                behavior: .stallsAfterBytes(Int64(chunkBytes)),
                maximumChunkBytes: chunkBytes
            )
            let driver = makeDriver(
                transport: fixture,
                tokens: tokens,
                featureBox: featureBox
            )
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(contentLength: Int64(data.count)),
                attempt: tokens.currentSourceAttempt
            )
            let request = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: 1,
                requestsAllDataToEndOfResource: true
            )
            handle.loader.startLoading(request, requestID: UUID())
            await fixture.waitUntilStalledRequestCount(1)
            await request.waitUntilRespondedByteCount(chunkBytes)
            featureBox.update(killed)
            await fixture.releaseStalledRequests()
            await request.waitUntilTerminal()

            XCTAssertEqual(request.observation().respondedData.count, chunkBytes)
            let fixtureObservation = await fixture.observation()
            XCTAssertEqual(fixtureObservation.byteRequestCount, 1)
            XCTAssertEqual(
                request.observation().error as? RangeLoaderError,
                .killSwitchEnabled
            )
        }
    }

    func testAuthorizationIsRecheckedBeforeCachedAndCoalescedResponds() async throws {
        let killed = PlaybackFeatureSnapshot(
            rangeStreamingV1: true,
            cohortPercent: 100,
            boundedPreloadV1: false,
            killSwitch: true,
            killSwitchEpoch: authorizedEpoch,
            loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
            headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
        )

        do {
            let data = payload(count: 16)
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let featureBox = RangeFeatureSnapshotBox(
                enabledSnapshot(epoch: authorizedEpoch)
            )
            let fixture = RangeFixtureServer(
                payload: data,
                behavior: .valid206(etag: "\"task9-generation\"")
            )
            let candidates = RangeCandidateSpy(
                fullPayload: data,
                holdsPayloadReads: true
            )
            let driver = makeDriver(
                transport: fixture,
                candidateReader: candidates,
                tokens: tokens,
                featureBox: featureBox
            )
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(),
                attempt: tokens.currentSourceAttempt
            )
            let request = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )
            handle.loader.startLoading(request, requestID: UUID())
            await candidates.waitUntilPayloadReadIsHeld()
            featureBox.update(killed)
            await candidates.releasePayloadRead()
            await request.waitUntilTerminal()

            XCTAssertTrue(request.observation().respondedData.isEmpty)
            let candidateObservation = await candidates.observation()
            let fixtureObservation = await fixture.observation()
            XCTAssertEqual(candidateObservation.readCount, 1)
            XCTAssertEqual(fixtureObservation.byteRequestCount, 0)
            XCTAssertEqual(
                request.observation().error as? RangeLoaderError,
                .killSwitchEnabled
            )
        }

        do {
            let chunkBytes = 64 * 1024
            let data = payload(count: 96 * 1024)
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let featureBox = RangeFeatureSnapshotBox(
                enabledSnapshot(epoch: authorizedEpoch)
            )
            let fixture = RangeFixtureServer(
                payload: data,
                behavior: .stallsAfterBytes(Int64(chunkBytes)),
                maximumChunkBytes: chunkBytes
            )
            let driver = makeDriver(
                transport: fixture,
                tokens: tokens,
                featureBox: featureBox
            )
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(contentLength: Int64(data.count)),
                attempt: tokens.currentSourceAttempt
            )
            let firstRequestID = UUID()
            let first = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )
            handle.loader.startLoading(first, requestID: firstRequestID)
            await fixture.waitUntilStalledRequestCount(1)
            await first.waitUntilRespondedByteCount(chunkBytes)
            featureBox.update(killed)

            let overlapping = RecordingResourceLoadingRequest(
                requestedOffset: Int64(chunkBytes / 2),
                currentOffset: Int64(chunkBytes / 2),
                requestedLength: chunkBytes / 2,
                requestsAllDataToEndOfResource: false
            )
            handle.loader.startLoading(overlapping, requestID: UUID())
            await overlapping.waitUntilTerminal()
            XCTAssertTrue(overlapping.observation().respondedData.isEmpty)
            XCTAssertEqual(
                overlapping.observation().error as? RangeLoaderError,
                .killSwitchEnabled
            )
            let fixtureObservation = await fixture.observation()
            XCTAssertEqual(fixtureObservation.byteRequestCount, 1)

            handle.loader.didCancel(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: firstRequestID
            )
            await fixture.waitUntilCancellationCount(1)
            await fixture.releaseStalledRequests()
            await fixture.waitUntilLateCallbackDrainCount(1)
            XCTAssertEqual(first.observation().finishCount, 0)
            XCTAssertEqual(first.observation().errorFinishCount, 0)
        }
    }

    func testEpochChangeDuringLiveSharedFetchDeniesEveryConsumerBeforeRespond()
        async throws
    {
        let chunkBytes = 64 * 1024
        let data = payload(count: chunkBytes)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let featureBox = RangeFeatureSnapshotBox(
            enabledSnapshot(epoch: authorizedEpoch)
        )
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsAfterBytes(0)
        )
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            featureBox: featureBox
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        let second = RecordingResourceLoadingRequest(
            requestedOffset: Int64(chunkBytes / 2),
            currentOffset: Int64(chunkBytes / 2),
            requestedLength: chunkBytes / 2,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(first, requestID: UUID())
        await fixture.waitUntilStalledRequestCount(1)
        handle.loader.startLoading(second, requestID: UUID())
        let attached = await handle.loader.waitUntilSharedConsumerCount(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            upstreamRange: 0..<Int64(chunkBytes),
            count: 2,
            timeoutNanoseconds: 5_000_000_000
        )
        XCTAssertTrue(attached)
        let attachedTransport = await fixture.observation()
        XCTAssertEqual(attachedTransport.byteRequestCount, 1)

        featureBox.update(enabledSnapshot(epoch: authorizedEpoch + 1))
        await fixture.releaseStalledRequests()
        await first.waitUntilTerminal()
        await second.waitUntilTerminal()

        for request in [first, second] {
            let observation = request.observation()
            XCTAssertTrue(observation.respondedData.isEmpty)
            XCTAssertEqual(observation.finishCount, 0)
            XCTAssertEqual(observation.errorFinishCount, 1)
            XCTAssertEqual(
                observation.error as? RangeLoaderError,
                .staleKillSwitchEpoch
            )
        }
        let terminalTransport = await fixture.observation()
        XCTAssertEqual(terminalTransport.byteRequestCount, 1)
    }

    func testSharedFetchCancellationIsReferenceCountedAcrossExactConsumers()
        async throws
    {
        let data = payload(count: 64 * 1024)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)

        do {
            let fixture = RangeFixtureServer(
                payload: data,
                behavior: .stallsAfterBytes(0)
            )
            let driver = makeDriver(transport: fixture, tokens: tokens)
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(contentLength: Int64(data.count)),
                attempt: tokens.currentSourceAttempt
            )
            let cancelledID = UUID()
            let survivorID = UUID()
            let cancelled = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )
            let survivor = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )

            handle.loader.startLoading(cancelled, requestID: cancelledID)
            await fixture.waitUntilStalledRequestCount(1)
            handle.loader.startLoading(survivor, requestID: survivorID)
            let bothAttached = await handle.loader.waitUntilSharedConsumerCount(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                upstreamRange: 0..<Int64(data.count),
                count: 2,
                timeoutNanoseconds: 5_000_000_000
            )
            XCTAssertTrue(bothAttached)

            handle.loader.didCancel(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: cancelledID
            )
            let survivorAttached = await handle.loader.waitUntilSharedConsumerCount(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                upstreamRange: 0..<Int64(data.count),
                count: 1,
                timeoutNanoseconds: 5_000_000_000
            )
            XCTAssertTrue(survivorAttached)
            let preReleaseTransport = await fixture.observation()
            XCTAssertEqual(preReleaseTransport.cancellationCount, 0)

            await fixture.releaseStalledRequests()
            await survivor.waitUntilTerminal()
            XCTAssertEqual(survivor.observation().respondedData, data)
            XCTAssertEqual(survivor.observation().finishCount, 1)
            XCTAssertTrue(cancelled.observation().respondedData.isEmpty)
            XCTAssertEqual(cancelled.observation().finishCount, 0)
            XCTAssertEqual(cancelled.observation().errorFinishCount, 0)
            let terminalTransport = await fixture.observation()
            XCTAssertEqual(terminalTransport.cancellationCount, 0)
        }

        do {
            let fixture = RangeFixtureServer(
                payload: data,
                behavior: .stallsAfterBytes(0)
            )
            let driver = makeDriver(transport: fixture, tokens: tokens)
            let handle = try driver.makeRangeAsset(
                descriptor: makeDescriptor(contentLength: Int64(data.count)),
                attempt: tokens.currentSourceAttempt
            )
            let firstID = UUID()
            let lastID = UUID()
            let first = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )
            let last = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )

            handle.loader.startLoading(first, requestID: firstID)
            await fixture.waitUntilStalledRequestCount(1)
            handle.loader.startLoading(last, requestID: lastID)
            let bothAttached = await handle.loader.waitUntilSharedConsumerCount(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                upstreamRange: 0..<Int64(data.count),
                count: 2,
                timeoutNanoseconds: 5_000_000_000
            )
            XCTAssertTrue(bothAttached)

            handle.loader.didCancel(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: firstID
            )
            let finalConsumerAttached = await handle.loader.waitUntilSharedConsumerCount(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                upstreamRange: 0..<Int64(data.count),
                count: 1,
                timeoutNanoseconds: 5_000_000_000
            )
            XCTAssertTrue(finalConsumerAttached)
            let preFinalCancelTransport = await fixture.observation()
            XCTAssertEqual(preFinalCancelTransport.cancellationCount, 0)

            handle.loader.didCancel(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                requestID: lastID
            )
            await fixture.waitUntilCancellationCount(1)
            await fixture.releaseStalledRequests()
            await fixture.waitUntilLateCallbackDrainCount(1)
            let cancelledTransport = await fixture.observation()
            XCTAssertEqual(cancelledTransport.cancellationCount, 1)
            for request in [first, last] {
                XCTAssertTrue(request.observation().respondedData.isEmpty)
                XCTAssertEqual(request.observation().finishCount, 0)
                XCTAssertEqual(request.observation().errorFinishCount, 0)
            }
        }
    }

    func testDemandControllerUsesTargetsAndExactCumulativeByteBudget() throws {
        let controller = makeDemandController()

        XCTAssertEqual(
            controller.forwardBufferTargetSeconds(
                for: .wifi(expensive: false, constrained: false)
            ),
            15
        )
        XCTAssertEqual(
            controller.forwardBufferTargetSeconds(for: .cellular(constrained: false)),
            8
        )
        XCTAssertEqual(
            controller.forwardBufferTargetSeconds(
                for: .wifi(expensive: false, constrained: true)
            ),
            5
        )

        let initializationAndIndexUnionBytes: Int64 = 8_192
        let mediaBytes = Int64(128_000 / 8 * (2 + 15))
        let baseBudget = initializationAndIndexUnionBytes + mediaBytes
        let expectedBudget = (baseBudget * 110 + 99) / 100
        XCTAssertEqual(
            controller.activeTrackByteBudget(
                playedSeconds: 2,
                network: .wifi(expensive: false, constrained: false)
            ),
            expectedBudget
        )

        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let remainderDemand = ResourceLoadingDataDemand(
            requestedOffset: 0,
            currentOffset: 64 * 1024,
            requestedLength: Int(expectedBudget * 2),
            requestsAllDataToEndOfResource: false
        )
        let finalPermit = try XCTUnwrap(
            controller.nextFetchPermit(
                demand: remainderDemand,
                playedSeconds: 2,
                bufferedSeconds: 0,
                cumulativeResponseBodyBytes: expectedBudget - 1_024,
                network: .wifi(expensive: false, constrained: false),
                featureSnapshot: enabledSnapshot(epoch: authorizedEpoch),
                tokens: tokens
            )
        )
        XCTAssertEqual(finalPermit.range, 65_536..<66_560)
        XCTAssertEqual(finalPermit.byteCeiling, 1_024)
        XCTAssertNil(
            controller.nextFetchPermit(
                demand: remainderDemand,
                playedSeconds: 2,
                bufferedSeconds: 0,
                cumulativeResponseBodyBytes: expectedBudget,
                network: .wifi(expensive: false, constrained: false),
                featureSnapshot: enabledSnapshot(epoch: authorizedEpoch),
                tokens: tokens
            )
        )
    }

    func testFinishPolicyRequiresExactEOFAndFiniteTargetBounds() {
        let eof: Int64 = 16

        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: true,
                deliveredOffset: eof - 1,
                targetEnd: eof,
                validatedEOF: eof
            )
        )
        XCTAssertTrue(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: true,
                deliveredOffset: eof,
                targetEnd: eof,
                validatedEOF: eof
            )
        )
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: true,
                deliveredOffset: eof + 1,
                targetEnd: eof,
                validatedEOF: eof
            )
        )
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: true,
                deliveredOffset: eof - 1,
                targetEnd: eof - 1,
                validatedEOF: eof
            )
        )
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: true,
                deliveredOffset: eof,
                targetEnd: eof + 1,
                validatedEOF: eof
            )
        )

        let finiteTarget: Int64 = 8
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: false,
                deliveredOffset: finiteTarget - 1,
                targetEnd: finiteTarget,
                validatedEOF: eof
            )
        )
        for deliveredOffset in [finiteTarget, finiteTarget + 1, eof] {
            XCTAssertTrue(
                RangeFinishPolicy.mayFinish(
                    requestsAllDataToEnd: false,
                    deliveredOffset: deliveredOffset,
                    targetEnd: finiteTarget,
                    validatedEOF: eof
                )
            )
        }
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: false,
                deliveredOffset: eof + 1,
                targetEnd: finiteTarget,
                validatedEOF: eof
            )
        )
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: false,
                deliveredOffset: eof + 1,
                targetEnd: eof + 1,
                validatedEOF: eof
            )
        )
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: false,
                deliveredOffset: 0,
                targetEnd: -1,
                validatedEOF: eof
            )
        )
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: false,
                deliveredOffset: -1,
                targetEnd: 0,
                validatedEOF: eof
            )
        )
        XCTAssertFalse(
            RangeFinishPolicy.mayFinish(
                requestsAllDataToEnd: false,
                deliveredOffset: 0,
                targetEnd: 0,
                validatedEOF: -1
            )
        )
    }

    func testStaleKillSwitchEpochGrantsZeroDemandAndStartsNoTransport() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let staleSnapshot = enabledSnapshot(epoch: authorizedEpoch + 1)
        let controller = makeDemandController()
        let demand = ResourceLoadingDataDemand(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: 128 * 1024,
            requestsAllDataToEndOfResource: false
        )
        XCTAssertNil(
            controller.nextFetchPermit(
                demand: demand,
                playedSeconds: 0,
                bufferedSeconds: 0,
                cumulativeResponseBodyBytes: 0,
                network: .wifi(expensive: false, constrained: false),
                featureSnapshot: staleSnapshot,
                tokens: tokens
            )
        )
        let livePermit = try XCTUnwrap(
            controller.nextFetchPermit(
                demand: demand,
                playedSeconds: 0,
                bufferedSeconds: 0,
                cumulativeResponseBodyBytes: 0,
                network: .wifi(expensive: false, constrained: false),
                featureSnapshot: enabledSnapshot(epoch: authorizedEpoch),
                tokens: tokens
            )
        )
        XCTAssertEqual(livePermit.range, 0..<Int64(64 * 1024))
        XCTAssertEqual(
            livePermit.byteCeiling,
            controller.activeTrackByteBudget(
                playedSeconds: 0,
                network: .wifi(expensive: false, constrained: false)
            )
        )
        XCTAssertEqual(livePermit.authorizedKillSwitchEpoch, authorizedEpoch)
        XCTAssertEqual(livePermit.tokens, tokens)

        let unauthorizedSnapshots = [
            PlaybackFeatureSnapshot(
                rangeStreamingV1: false,
                cohortPercent: 100,
                boundedPreloadV1: false,
                killSwitch: false,
                killSwitchEpoch: authorizedEpoch,
                loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
                headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
            ),
            PlaybackFeatureSnapshot(
                rangeStreamingV1: true,
                cohortPercent: 100,
                boundedPreloadV1: false,
                killSwitch: true,
                killSwitchEpoch: authorizedEpoch,
                loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
                headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
            ),
            PlaybackFeatureSnapshot(
                rangeStreamingV1: true,
                cohortPercent: 100,
                boundedPreloadV1: false,
                killSwitch: false,
                killSwitchEpoch: authorizedEpoch,
                loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion + 1,
                headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
            ),
            PlaybackFeatureSnapshot(
                rangeStreamingV1: true,
                cohortPercent: 0,
                boundedPreloadV1: false,
                killSwitch: false,
                killSwitchEpoch: authorizedEpoch,
                loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
                headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
            ),
            PlaybackFeatureSnapshot(
                rangeStreamingV1: true,
                cohortPercent: 101,
                boundedPreloadV1: false,
                killSwitch: false,
                killSwitchEpoch: authorizedEpoch,
                loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
                headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
            ),
            PlaybackFeatureSnapshot(
                rangeStreamingV1: true,
                cohortPercent: 100,
                boundedPreloadV1: false,
                killSwitch: false,
                killSwitchEpoch: authorizedEpoch,
                loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
                headerSchemaVersion:
                    PlaybackFeatureSnapshot.supportedHeaderSchemaVersion + 1
            ),
        ]
        for snapshot in unauthorizedSnapshots {
            XCTAssertNil(
                controller.nextFetchPermit(
                    demand: demand,
                    playedSeconds: 0,
                    bufferedSeconds: 0,
                    cumulativeResponseBodyBytes: 0,
                    network: .wifi(expensive: false, constrained: false),
                    featureSnapshot: snapshot,
                    tokens: tokens
                )
            )
        }

        let fixture = RangeFixtureServer(
            payload: payload(count: 16),
            behavior: .valid206(etag: "\"task9-generation\"")
        )
        let featureBox = RangeFeatureSnapshotBox(staleSnapshot)
        let driver = makeDriver(
            transport: fixture,
            tokens: tokens,
            featureBox: featureBox
        )
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: 16,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        let transport = await fixture.observation()
        XCTAssertEqual(transport.generationValidationCount, 0)
        XCTAssertEqual(transport.byteRequestCount, 0)
        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(
            request.observation().error as? RangeLoaderError,
            .staleKillSwitchEpoch
        )
    }

    func testOverlappingActiveRangesCoalesceSharedNetworkBytesAndFanOut()
        async throws
    {
        let chunkBytes = 64 * 1024
        let requestedUnionBytes = 96 * 1024
        let data = payload(count: requestedUnionBytes)
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: 0..<4_096,
            indexRange: 2_048..<8_192
        )
        let attemptBudget = makeDemandController().activeTrackByteBudget(
            playedSeconds: 0,
            network: .wifi(expensive: false, constrained: false)
        )
        let mediaBudget = attemptBudget - 1
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsAfterBytes(Int64(chunkBytes)),
            maximumChunkBytes: chunkBytes
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: requestedUnionBytes,
            requestsAllDataToEndOfResource: false
        )
        let second = RecordingResourceLoadingRequest(
            requestedOffset: Int64(chunkBytes / 2),
            currentOffset: Int64(chunkBytes / 2),
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(first, requestID: UUID())
        await fixture.waitUntilStalledRequestCount(1)
        await first.waitUntilRespondedByteCount(chunkBytes)
        handle.loader.startLoading(second, requestID: UUID())
        await second.waitUntilRespondedByteCount(chunkBytes / 2)

        let heldTransport = await fixture.observation()
        XCTAssertEqual(heldTransport.byteRequestCount, 1)
        let heldMediaRanges = heldTransport.requestedRanges.compactMap { $0 }
            .filter { $0 != 0..<1 }
        XCTAssertEqual(heldMediaRanges, [0..<Int64(chunkBytes)])
        XCTAssertEqual(heldTransport.servedRangeUnion, [0..<Int64(chunkBytes)])

        await fixture.releaseStalledRequests()
        await first.waitUntilTerminal()
        await second.waitUntilTerminal()

        XCTAssertEqual(first.observation().respondedData, data)
        XCTAssertEqual(
            second.observation().respondedData,
            data.subdata(in: (chunkBytes / 2)..<requestedUnionBytes)
        )
        let terminalTransport = await fixture.observation()
        XCTAssertEqual(terminalTransport.byteRequestCount, 2)
        XCTAssertEqual(
            terminalTransport.mediaRequestedRanges,
            [
                0..<Int64(chunkBytes),
                Int64(chunkBytes)..<Int64(requestedUnionBytes),
            ]
        )
        XCTAssertEqual(
            terminalTransport.mediaByteCeilings,
            [mediaBudget, mediaBudget - Int64(chunkBytes)]
        )
        XCTAssertEqual(
            terminalTransport.mediaResponseBodyBytes,
            Int64(requestedUnionBytes)
        )
        XCTAssertEqual(
            terminalTransport.servedRangeUnion,
            [0..<Int64(requestedUnionBytes)]
        )
    }

    func testReverseOverlapFetchesOnlyTheUncoveredPrefix() async throws {
        let chunkBytes = 64 * 1024
        let halfChunkBytes = chunkBytes / 2
        let data = payload(count: 96 * 1024)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .stallsEveryByteRequestBeforeBody,
            maximumChunkBytes: chunkBytes
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let first = RecordingResourceLoadingRequest(
            requestedOffset: Int64(halfChunkBytes),
            currentOffset: Int64(halfChunkBytes),
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )
        let second = RecordingResourceLoadingRequest(
            requestedOffset: 0,
            currentOffset: 0,
            requestedLength: chunkBytes,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(first, requestID: UUID())
        await fixture.waitUntilStalledRequestCount(1)
        handle.loader.startLoading(second, requestID: UUID())
        let attached = await handle.loader.waitUntilSharedConsumerCount(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            upstreamRange: Int64(halfChunkBytes)..<Int64(96 * 1024),
            count: 2,
            timeoutNanoseconds: 5_000_000_000
        )
        XCTAssertTrue(attached)
        await fixture.releaseStalledRequests()
        await first.waitUntilTerminal()
        await second.waitUntilTerminal()

        let transport = await fixture.observation()
        XCTAssertEqual(
            transport.mediaRequestedRanges,
            [
                Int64(halfChunkBytes)..<Int64(96 * 1024),
                0..<Int64(halfChunkBytes),
            ]
        )
        XCTAssertEqual(transport.byteRequestCount, 2)
        XCTAssertEqual(transport.mediaResponseBodyBytes, Int64(data.count))
        XCTAssertEqual(transport.servedRangeUnion, [0..<Int64(data.count)])
        XCTAssertEqual(
            first.observation().respondedData,
            data.subdata(in: halfChunkBytes..<data.count)
        )
        XCTAssertEqual(
            second.observation().respondedData,
            data.subdata(in: 0..<chunkBytes)
        )
        XCTAssertEqual(first.observation().finishCount, 1)
        XCTAssertEqual(second.observation().finishCount, 1)
        XCTAssertEqual(first.observation().errorFinishCount, 0)
        XCTAssertEqual(second.observation().errorFinishCount, 0)
    }

    func testReverseDeliveredDisjointCumulativeWatermarksMergeByMaximum()
        async throws
    {
        let data = payload(count: 48)
        let descriptor = makeDescriptor(contentLength: Int64(data.count))
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let transport = RangeReverseDeliveryTransport(payload: data)
        let driver = makeDriver(transport: transport, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        let lowRange: Range<Int64> = 0..<16
        let highRange: Range<Int64> = 16..<32
        let followUpRange: Range<Int64> = 32..<48
        let low = RecordingResourceLoadingRequest(
            requestedOffset: lowRange.lowerBound,
            currentOffset: lowRange.lowerBound,
            requestedLength: Int(lowRange.count),
            requestsAllDataToEndOfResource: false
        )
        let high = RecordingResourceLoadingRequest(
            requestedOffset: highRange.lowerBound,
            currentOffset: highRange.lowerBound,
            requestedLength: Int(highRange.count),
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(low, requestID: UUID())
        await transport.waitUntilMediaRequestCount(1)
        handle.loader.startLoading(high, requestID: UUID())
        await transport.waitUntilMediaRequestCount(2)
        await transport.release(range: highRange)
        await high.waitUntilTerminal()
        await transport.release(range: lowRange)
        await low.waitUntilTerminal()

        let settledPair = await transport.observation()
        XCTAssertEqual(settledPair.generationValidationCount, 1)
        XCTAssertEqual(settledPair.mediaRequestedRanges, [lowRange, highRange])
        XCTAssertEqual(settledPair.releaseOrder, [highRange, lowRange])
        XCTAssertEqual(settledPair.maximumCumulativeBodyBytes, 33)
        XCTAssertEqual(settledPair.mediaRequestCount, 2)
        XCTAssertEqual(low.observation().respondedData, data.subdata(in: 0..<16))
        XCTAssertEqual(high.observation().respondedData, data.subdata(in: 16..<32))
        XCTAssertEqual(low.observation().finishCount, 1)
        XCTAssertEqual(high.observation().finishCount, 1)
        XCTAssertEqual(low.observation().errorFinishCount, 0)
        XCTAssertEqual(high.observation().errorFinishCount, 0)

        let followUp = RecordingResourceLoadingRequest(
            requestedOffset: followUpRange.lowerBound,
            currentOffset: followUpRange.lowerBound,
            requestedLength: Int(followUpRange.count),
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(followUp, requestID: UUID())
        await transport.waitUntilMediaRequestCount(3)
        let heldFollowUp = await transport.observation()
        let attemptBudget = RangeDemandController(
            bitrate: descriptor.bitrate,
            initializationRange: descriptor.initializationRange,
            indexRange: descriptor.indexRange,
            authorizedKillSwitchEpoch: authorizedEpoch
        ).activeTrackByteBudget(
            playedSeconds: 0,
            network: .wifi(expensive: false, constrained: false)
        )
        XCTAssertEqual(
            try XCTUnwrap(heldFollowUp.mediaByteCeilings.last),
            attemptBudget - 33
        )
        await transport.release(range: followUpRange)
        await followUp.waitUntilTerminal()
        XCTAssertEqual(
            followUp.observation().respondedData,
            data.subdata(in: 32..<48)
        )
        XCTAssertEqual(followUp.observation().finishCount, 1)
        XCTAssertEqual(followUp.observation().errorFinishCount, 0)
    }

    func testDescendingChunkWakesBudgetWaiterBeforeCandidateWriteReturns()
        async throws
    {
        let attemptBudget: Int64 = 40
        let data = payload(count: 48)
        let descriptor = makeDescriptor(
            contentLength: Int64(data.count),
            initializationRange: nil,
            indexRange: nil,
            bitrate: 19
        )
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let transport = RangeReverseDeliveryTransport(payload: data)
        let candidates = RangeCandidateSpy(heldWriteRange: 0..<16)
        let exitProbe = RangeRequestExitProbe()
        let driver = makeDriver(
            transport: transport,
            candidateReader: candidates,
            tokens: tokens,
            requestDidExit: { callbackTokens, requestID in
                await exitProbe.record(tokens: callbackTokens, requestID: requestID)
            }
        )
        let handle = try driver.makeRangeAsset(
            descriptor: descriptor,
            attempt: tokens.currentSourceAttempt
        )
        XCTAssertEqual(
            RangeDemandController(
                bitrate: descriptor.bitrate,
                initializationRange: descriptor.initializationRange,
                indexRange: descriptor.indexRange,
                authorizedKillSwitchEpoch: authorizedEpoch
            ).activeTrackByteBudget(
                playedSeconds: 0,
                network: .wifi(expensive: false, constrained: false)
            ),
            attemptBudget
        )
        let lowRange: Range<Int64> = 0..<16
        let highRange: Range<Int64> = 16..<32
        let expectedThirdRange: Range<Int64> = 32..<39
        let lowID = UUID()
        let highID = UUID()
        let thirdID = UUID()
        let low = RecordingResourceLoadingRequest(
            requestedOffset: lowRange.lowerBound,
            currentOffset: lowRange.lowerBound,
            requestedLength: Int(lowRange.count),
            requestsAllDataToEndOfResource: false
        )
        let high = RecordingResourceLoadingRequest(
            requestedOffset: highRange.lowerBound,
            currentOffset: highRange.lowerBound,
            requestedLength: Int(highRange.count),
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(low, requestID: lowID)
        await transport.waitUntilMediaRequestCount(1)
        handle.loader.startLoading(high, requestID: highID)
        await transport.waitUntilMediaRequestCount(2)
        await transport.release(range: highRange)
        await high.waitUntilTerminal()

        let third = RecordingResourceLoadingRequest(
            requestedOffset: 32,
            currentOffset: 32,
            requestedLength: 16,
            requestsAllDataToEndOfResource: false
        )
        handle.loader.startLoading(third, requestID: thirdID)
        let thirdSuspended = await handle.loader.waitUntilDemandSuspended(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: thirdID,
            timeoutNanoseconds: 5_000_000_000
        )
        let beforeLowCallback = await transport.observation()
        XCTAssertTrue(thirdSuspended)
        XCTAssertEqual(beforeLowCallback.mediaRequestCount, 2)
        XCTAssertEqual(
            beforeLowCallback.mediaRequestedRanges,
            [lowRange, highRange]
        )
        XCTAssertTrue(third.observation().respondedData.isEmpty)
        XCTAssertEqual(third.observation().finishCount, 0)

        await transport.release(range: lowRange)
        await candidates.waitUntilWriteIsHeld()
        await transport.waitUntilMediaRequestCount(3)

        let whileWriteHeld = await transport.observation()
        let candidateWhileHeld = await candidates.observation()
        XCTAssertEqual(
            whileWriteHeld.mediaRequestedRanges,
            [lowRange, highRange, expectedThirdRange]
        )
        XCTAssertEqual(whileWriteHeld.mediaByteCeilings, [39, 23, 7])
        XCTAssertEqual(candidateWhileHeld.writeCount, 2)
        XCTAssertTrue(low.observation().respondedData.isEmpty)
        XCTAssertEqual(low.observation().finishCount, 0)
        XCTAssertEqual(low.observation().errorFinishCount, 0)

        handle.loader.didCancel(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: thirdID
        )
        await candidates.releaseWrite()
        await low.waitUntilTerminal()
        if let cleanupRange = whileWriteHeld.mediaRequestedRanges.dropFirst(2).first {
            await transport.release(range: cleanupRange)
        }
        await exitProbe.waitUntilRecorded(3)

        XCTAssertEqual(low.observation().respondedData, data.subdata(in: 0..<16))
        XCTAssertEqual(high.observation().respondedData, data.subdata(in: 16..<32))
        XCTAssertEqual(low.observation().finishCount, 1)
        XCTAssertEqual(high.observation().finishCount, 1)
        XCTAssertEqual(third.observation().finishCount, 0)
        XCTAssertEqual(third.observation().errorFinishCount, 0)
        XCTAssertEqual(handle.loader.activeRequestCount, 0)
    }

    func testWeakOrMissingValidatorRemainsAttemptOnlyAndNeverUsesPersistentStore()
        async throws
    {
        for behavior in [RangeFixtureBehavior.weakETag, .noValidator] {
            let data = payload(count: 16)
            let descriptor = makeDescriptor(contentLength: Int64(data.count))
            let candidates = RangeCandidateSpy(fullPayload: data)
            let fixture = RangeFixtureServer(payload: data, behavior: behavior)
            let firstTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let scope = try await fixture.validateGeneration(
                for: descriptor,
                tokens: firstTokens
            )
            guard case .attemptOnly(
                let sessionID,
                let sourceAttemptID,
                let totalLength
            ) = scope else {
                return XCTFail("weak or absent validator must be attempt-only")
            }
            XCTAssertEqual(sessionID, firstTokens.sessionID)
            XCTAssertEqual(sourceAttemptID, firstTokens.currentSourceAttempt.id)
            XCTAssertEqual(totalLength, Int64(data.count))

            let firstDriver = makeDriver(
                transport: fixture,
                candidateReader: candidates,
                tokens: firstTokens
            )
            let firstHandle = try firstDriver.makeRangeAsset(
                descriptor: descriptor,
                attempt: firstTokens.currentSourceAttempt
            )
            let firstRequest = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )
            firstHandle.loader.startLoading(firstRequest, requestID: UUID())
            await firstRequest.waitUntilTerminal()

            let secondTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            let secondDriver = makeDriver(
                transport: fixture,
                candidateReader: candidates,
                tokens: secondTokens
            )
            let secondHandle = try secondDriver.makeRangeAsset(
                descriptor: descriptor,
                attempt: secondTokens.currentSourceAttempt
            )
            let secondRequest = RecordingResourceLoadingRequest(
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: data.count,
                requestsAllDataToEndOfResource: false
            )
            secondHandle.loader.startLoading(secondRequest, requestID: UUID())
            await secondRequest.waitUntilTerminal()

            let candidateObservation = await candidates.observation()
            let fixtureObservation = await fixture.observation()
            XCTAssertEqual(candidateObservation.readCount, 0)
            XCTAssertEqual(candidateObservation.writeCount, 0)
            XCTAssertEqual(fixtureObservation.byteRequestCount, 2)
            XCTAssertEqual(firstRequest.observation().respondedData, data)
            XCTAssertEqual(secondRequest.observation().respondedData, data)
        }
    }

    func testKnownValidatedEOFFinishesWithoutUnnecessary416Request() async throws {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .unsatisfied416(totalLength: Int64(data.count))
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: Int64(data.count),
            currentOffset: Int64(data.count),
            requestedLength: 8,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(request.observation().finishCount, 1)
        XCTAssertEqual(request.observation().errorFinishCount, 0)
        let fixtureObservation = await fixture.observation()
        XCTAssertEqual(fixtureObservation.byteRequestCount, 0)
    }

    func testFixtureErrorAccountingIsAttemptCumulativeRatherThanGlobal()
        async throws
    {
        let descriptor = makeDescriptor(contentLength: 16)
        let fixture = RangeFixtureServer(
            payload: payload(count: 16),
            behavior: .unsatisfied416(totalLength: 16)
        )
        let firstTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let secondTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        var cumulativeErrors: [Int64] = []

        for tokens in [firstTokens, secondTokens] {
            _ = try await fixture.validateGeneration(
                for: descriptor,
                tokens: tokens
            )
            let request = MediaByteRequest(
                descriptor: descriptor,
                range: 15..<16,
                ifRangeValidator: nil,
                purpose: .media,
                byteCeiling: 1,
                tokens: tokens
            )
            let error = await collectError(from: fixture.bytes(for: request))
            let transportError = try XCTUnwrap(error as? MediaTransportError)
            XCTAssertEqual(
                transportError.reason,
                .endOfResource(totalLength: 16)
            )
            cumulativeErrors.append(transportError.cumulativeResponseBodyBytes)
        }

        XCTAssertEqual(cumulativeErrors, [1, 1])
        let fixtureObservation = await fixture.observation()
        XCTAssertEqual(fixtureObservation.generationProbeBodyBytes, 2)
    }

    func testSatisfiableRangeReceiving416IsInconsistentAndNeverSucceeds()
        async throws
    {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .unsatisfied416(totalLength: Int64(data.count))
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: 15,
            currentOffset: 15,
            requestedLength: 1,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        let loading = request.observation()
        let fixtureObservation = await fixture.observation()
        XCTAssertTrue(loading.respondedData.isEmpty)
        XCTAssertEqual(loading.finishCount, 0)
        XCTAssertEqual(loading.errorFinishCount, 1)
        XCTAssertEqual(
            loading.error as? RangeLoaderError,
            .inconsistentEndOfResource
        )
        XCTAssertEqual(fixtureObservation.byteRequestCount, 1)
        XCTAssertEqual(fixtureObservation.mediaResponseBodyBytes, 0)
    }

    func testInconsistentUnsatisfied416IsStructuralFailure() async throws {
        let data = payload(count: 16)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let fixture = RangeFixtureServer(
            payload: data,
            behavior: .unsatisfied416(totalLength: Int64(data.count - 1))
        )
        let driver = makeDriver(transport: fixture, tokens: tokens)
        let handle = try driver.makeRangeAsset(
            descriptor: makeDescriptor(contentLength: Int64(data.count)),
            attempt: tokens.currentSourceAttempt
        )
        let request = RecordingResourceLoadingRequest(
            requestedOffset: Int64(data.count - 1),
            currentOffset: Int64(data.count - 1),
            requestedLength: 1,
            requestsAllDataToEndOfResource: false
        )

        handle.loader.startLoading(request, requestID: UUID())
        await request.waitUntilTerminal()

        XCTAssertTrue(request.observation().respondedData.isEmpty)
        XCTAssertEqual(request.observation().finishCount, 0)
        XCTAssertEqual(request.observation().errorFinishCount, 1)
        XCTAssertEqual(
            request.observation().error as? RangeLoaderError,
            .inconsistentEndOfResource
        )
        let fixtureObservation = await fixture.observation()
        XCTAssertEqual(fixtureObservation.byteRequestCount, 1)
    }
}

private extension RangePlaybackDriverTests {
    func makeDriver(
        transport: any MediaByteTransport,
        candidateReader: any RangeCandidateReading = RangeCandidateSpy(),
        tokens: ActivePlaybackTokens,
        featureBox: RangeFeatureSnapshotBox? = nil,
        network: NetworkSnapshot = .wifi(expensive: false, constrained: false),
        resourceLoaderDelegateInstaller: @escaping @Sendable (
            AVAssetResourceLoader,
            RangeResourceLoaderDelegate,
            DispatchQueue
        ) -> Void = { resourceLoader, delegate, queue in
            resourceLoader.setDelegate(delegate, queue: queue)
        },
        validatedChunkWillRespond: @escaping @Sendable (
            ActivePlaybackTokens,
            UUID
        ) async -> Void = { _, _ in },
        validatedChunkDidAttemptRespond: @escaping @Sendable (
            ActivePlaybackTokens,
            UUID
        ) async -> Void = { _, _ in },
        requestDidExit: @escaping @Sendable (
            ActivePlaybackTokens,
            UUID
        ) async -> Void = { _, _ in },
        lifecycleHook: @escaping RangeLoaderLifecycleHook = { _ in }
    ) -> RangePlaybackDriver {
        let featureBox = featureBox
            ?? RangeFeatureSnapshotBox(enabledSnapshot(epoch: authorizedEpoch))
        return RangePlaybackDriver(
            transport: transport,
            candidateReader: candidateReader,
            tokens: tokens,
            authorizedKillSwitchEpoch: authorizedEpoch,
            featureSnapshot: { featureBox.snapshot() },
            networkSnapshot: { network },
            resourceLoaderDelegateInstaller: resourceLoaderDelegateInstaller,
            validatedChunkWillRespond: validatedChunkWillRespond,
            validatedChunkDidAttemptRespond: validatedChunkDidAttemptRespond,
            requestDidExit: requestDidExit,
            lifecycleHook: lifecycleHook
        )
    }

    func makeDemandController() -> RangeDemandController {
        RangeDemandController(
            bitrate: 128_000,
            initializationRange: 0..<4_096,
            indexRange: 2_048..<8_192,
            authorizedKillSwitchEpoch: authorizedEpoch
        )
    }

    func makeDescriptor(
        contentLength: Int64? = 16,
        initializationRange: Range<Int64>? = 0..<4,
        indexRange: Range<Int64>? = 4..<8,
        mimeType: String = "audio/mp4",
        bitrate: Int = 128_000
    ) -> StreamDescriptor {
        StreamDescriptor(
            videoID: "task9-private-video-id",
            remoteURL: signedURL,
            itag: 140,
            mimeType: mimeType,
            codec: "mp4a.40.2",
            bitrate: bitrate,
            contentLength: contentLength,
            duration: .seconds(8),
            initializationRange: initializationRange,
            indexRange: indexRange,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            requestHeaders: [
                "Cookie": "SID=task9-secret-cookie",
                "Origin": "https://task9-secret-origin.example",
                "Referer": "https://task9-secret-referer.example/path",
                "Authorization": "Bearer task9-secret-authorization",
            ],
            provisionalResourceKey: ProvisionalResourceKey(
                videoID: "task9-private-video-id",
                itag: 140,
                codec: "mp4a.40.2",
                declaredTotalLength: contentLength
            )
        )
    }

    func secretValues() -> [String] {
        [
            signedURL.absoluteString,
            "task9-secret-query",
            "task9-secret-token",
            "task9-secret-cookie",
            "task9-secret-origin.example",
            "task9-secret-referer.example",
            "task9-secret-authorization",
        ]
    }

    func payload(count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    func enabledSnapshot(epoch: UInt64) -> PlaybackFeatureSnapshot {
        PlaybackFeatureSnapshot(
            rangeStreamingV1: true,
            cohortPercent: 100,
            boundedPreloadV1: false,
            killSwitch: false,
            killSwitchEpoch: epoch,
            loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
            headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
        )
    }

    func collectError(
        from stream: AsyncThrowingStream<ValidatedMediaChunk, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Error? {
        let recorder = RangeCollectedErrorRecorder()
        let task = Task {
            do {
                for try await _ in stream {}
                recorder.record(nil)
            } catch {
                recorder.record(error)
            }
        }
        await recorder.waitUntilCompleted(file: file, line: line)
        let observation = recorder.observation()
        guard observation.isComplete else {
            task.cancel()
            await task.value
            return RangeFixtureCollectionTimeout()
        }
        return observation.error
    }
}

private struct RangeFixtureCollectionTimeout: Error {}

private struct RangeCollectedErrorObservation {
    let isComplete: Bool
    let error: Error?
}

private final class RangeCollectedErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let completionMilestone = RangeAsyncCountMilestone()
    private var isComplete = false
    private var error: Error?

    func record(_ error: Error?) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        self.error = error
        lock.unlock()
        completionMilestone.reach(1)
    }

    func waitUntilCompleted(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await completionMilestone.wait(
            until: 1,
            label: "fixture error collection",
            file: file,
            line: line
        )
    }

    func observation() -> RangeCollectedErrorObservation {
        lock.lock()
        defer { lock.unlock() }
        return RangeCollectedErrorObservation(
            isComplete: isComplete,
            error: error
        )
    }
}

private enum RangeTestEvent: Equatable, Sendable {
    case candidateManifestLocated
    case generationValidationStarted
    case generationValidationCompleted
    case candidatePayloadRead
    case candidatePayloadWrite
    case contentInformationSet
    case responseDelivered
}

private final class RangeTestEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RangeTestEvent] = []

    func recordFixtureEvent(_ event: RangeFixtureEvent) {
        switch event {
        case .generationValidationStarted:
            record(.generationValidationStarted)
        case .generationValidationCompleted:
            record(.generationValidationCompleted)
        case .byteRequestStarted:
            break
        }
    }

    func record(_ event: RangeTestEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [RangeTestEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private struct RangeCandidateObservation: Sendable {
    let locateCount: Int
    let readCount: Int
    let writeCount: Int
}

private actor RangeCandidateSpy: RangeCandidateReading {
    private let fullPayload: Data?
    private let events: RangeTestEventRecorder?
    private let holdsPayloadReads: Bool
    private let heldWriteRange: Range<Int64>?
    private let payloadReadHeldMilestone = RangeAsyncCountMilestone()
    private let writeHeldMilestone = RangeAsyncCountMilestone()
    private var locateCount = 0
    private var readCount = 0
    private var writeCount = 0
    private var payloadReadsReleased = false
    private var payloadReadContinuation: CheckedContinuation<Void, Never>?
    private var writesReleased = false
    private var writeContinuation: CheckedContinuation<Void, Never>?

    init(
        fullPayload: Data? = nil,
        events: RangeTestEventRecorder? = nil,
        holdsPayloadReads: Bool = false,
        heldWriteRange: Range<Int64>? = nil
    ) {
        self.fullPayload = fullPayload
        self.events = events
        self.holdsPayloadReads = holdsPayloadReads
        self.heldWriteRange = heldWriteRange
    }

    func locateCandidate(for _: ProvisionalResourceKey) async -> Bool {
        locateCount += 1
        events?.record(.candidateManifestLocated)
        return fullPayload != nil
    }

    func readCommittedBytes(
        for _: ValidatedContentGeneration,
        permit: RangeFetchPermit
    ) async throws -> Data? {
        readCount += 1
        events?.record(.candidatePayloadRead)
        if holdsPayloadReads {
            payloadReadHeldMilestone.reach(1)
            if !payloadReadsReleased {
                await withCheckedContinuation { continuation in
                    if payloadReadsReleased {
                        continuation.resume()
                    } else {
                        payloadReadContinuation = continuation
                    }
                }
            }
        }
        let range = permit.range
        guard let fullPayload,
            range.lowerBound >= 0,
            range.upperBound <= Int64(fullPayload.count)
        else {
            return nil
        }
        return fullPayload.subdata(
            in: Int(range.lowerBound)..<Int(range.upperBound)
        )
    }

    func writeCommittedBytes(
        _: Data,
        for _: ValidatedContentGeneration,
        permit: RangeFetchPermit
    ) async throws {
        writeCount += 1
        events?.record(.candidatePayloadWrite)
        if permit.range == heldWriteRange {
            writeHeldMilestone.reach(1)
            if !writesReleased {
                await withCheckedContinuation { continuation in
                    if writesReleased {
                        continuation.resume()
                    } else {
                        writeContinuation = continuation
                    }
                }
            }
        }
    }

    func observation() -> RangeCandidateObservation {
        RangeCandidateObservation(
            locateCount: locateCount,
            readCount: readCount,
            writeCount: writeCount
        )
    }

    func waitUntilPayloadReadIsHeld() async {
        await payloadReadHeldMilestone.wait(
            until: 1,
            label: "candidate payload read hold"
        )
    }

    func releasePayloadRead() {
        payloadReadsReleased = true
        let continuation = payloadReadContinuation
        payloadReadContinuation = nil
        continuation?.resume()
    }

    func waitUntilWriteIsHeld() async {
        await writeHeldMilestone.wait(
            until: 1,
            label: "candidate committed-byte write hold"
        )
    }

    func releaseWrite() {
        writesReleased = true
        let continuation = writeContinuation
        writeContinuation = nil
        continuation?.resume()
    }
}

private struct RecordingLoadingRequestObservation {
    let contentInformation: ResourceContentInformation?
    let respondedData: Data
    let finishCount: Int
    let errorFinishCount: Int
    let error: Error?
}

private final class RecordingResourceLoadingRequest: ResourceLoadingRequest,
    @unchecked Sendable
{
    let dataDemand: ResourceLoadingDataDemand?

    private let lock = NSLock()
    private let respondedMilestone = RangeAsyncCountMilestone()
    private let contentInformationMilestone = RangeAsyncCountMilestone()
    private let terminalMilestone = RangeAsyncCountMilestone()
    private let events: RangeTestEventRecorder?
    private var contentInformation: ResourceContentInformation?
    private var respondedData = Data()
    private var finishCount = 0
    private var errorFinishCount = 0
    private var error: Error?

    init(
        requestedOffset: Int64,
        currentOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool,
        events: RangeTestEventRecorder? = nil
    ) {
        dataDemand = ResourceLoadingDataDemand(
            requestedOffset: requestedOffset,
            currentOffset: currentOffset,
            requestedLength: requestedLength,
            requestsAllDataToEndOfResource: requestsAllDataToEndOfResource
        )
        self.events = events
    }

    init(
        dataDemand: ResourceLoadingDataDemand?,
        events: RangeTestEventRecorder? = nil
    ) {
        self.dataDemand = dataDemand
        self.events = events
    }

    func setContentInformation(_ information: ResourceContentInformation) {
        lock.lock()
        contentInformation = information
        lock.unlock()
        events?.record(.contentInformationSet)
        contentInformationMilestone.reach(1)
    }

    func respond(with data: Data) {
        lock.lock()
        respondedData.append(data)
        let byteCount = respondedData.count
        lock.unlock()
        events?.record(.responseDelivered)
        respondedMilestone.reach(byteCount)
    }

    func finish() {
        lock.lock()
        finishCount += 1
        let terminalCount = finishCount + errorFinishCount
        lock.unlock()
        terminalMilestone.reach(terminalCount)
    }

    func finish(with error: Error) {
        lock.lock()
        self.error = error
        errorFinishCount += 1
        let terminalCount = finishCount + errorFinishCount
        lock.unlock()
        terminalMilestone.reach(terminalCount)
    }

    func waitUntilRespondedByteCount(_ expectedCount: Int) async {
        await respondedMilestone.wait(
            until: expectedCount,
            label: "resource response bytes"
        )
    }

    func waitUntilContentInformation() async {
        await contentInformationMilestone.wait(
            until: 1,
            label: "resource content information"
        )
    }

    func waitUntilTerminal() async {
        await terminalMilestone.wait(until: 1, label: "resource terminal")
    }

    func waitUntilTerminalResult() async -> Bool {
        await terminalMilestone.waitResult(until: 1)
    }

    func observation() -> RecordingLoadingRequestObservation {
        lock.lock()
        defer { lock.unlock() }
        return RecordingLoadingRequestObservation(
            contentInformation: contentInformation,
            respondedData: respondedData,
            finishCount: finishCount,
            errorFinishCount: errorFinishCount,
            error: error
        )
    }
}

private final class RangeAsyncCountMilestone: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let expectedCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var count = 0
    private var waiters: [Waiter] = []

    func reach(_ newCount: Int) {
        lock.lock()
        count = max(count, newCount)
        let ready = waiters.filter { count >= $0.expectedCount }
        waiters.removeAll { count >= $0.expectedCount }
        lock.unlock()
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    func wait(
        until expectedCount: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reached = await waitResult(until: expectedCount)
        if !reached {
            XCTFail("timed out waiting for \(label)", file: file, line: line)
        }
    }

    func waitResult(
        until expectedCount: Int,
        timeout: DispatchTimeInterval = .seconds(5)
    ) async -> Bool {
        if lock.withLock({ count >= expectedCount }) { return true }
        let waiterID = UUID()
        let reached = await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if count >= expectedCount { return true }
                waiters.append(
                    Waiter(
                        id: waiterID,
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                )
                return false
            }
            if shouldResume {
                continuation.resume(returning: true)
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    self.expire(waiterID)
                }
            }
        }
        return reached
    }

    private func expire(_ waiterID: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(returning: false)
    }
}

private enum RangeLifecycleHoldTarget: Sendable {
    case requestTaskEntry(UUID)
    case permitResolution(UUID)
    case candidateRead(UUID)
    case staleDetach(UUID)
    case generationConsumerCount(Int)
    case generationConsumerDetach(UUID)
    case generationRunReconcile(UUID)
    case upstreamTaskStart(UUID, Range<Int64>?)
    case fetchTerminalReservation(UUID, Range<Int64>)
    case transportChunkAccounting(UUID, Range<Int64>, Int64)
}

private struct RangeLifecycleGateObservation: Sendable {
    let matchCount: Int
    let tokens: ActivePlaybackTokens?
    let requestID: UUID?
    let range: Range<Int64>?
    let consumerCount: Int?
}

private actor RangeLifecycleGate {
    private let target: RangeLifecycleHoldTarget
    private let heldMilestone = RangeAsyncCountMilestone()
    private let drainedMilestone = RangeAsyncCountMilestone()
    private var matchCount = 0
    private var matchedTokens: ActivePlaybackTokens?
    private var matchedRequestID: UUID?
    private var matchedRange: Range<Int64>?
    private var matchedConsumerCount: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(target: RangeLifecycleHoldTarget) {
        self.target = target
    }

    func handle(_ event: RangeLoaderLifecycleEvent) async {
        guard matchCount == 0 else { return }
        let match: (
            tokens: ActivePlaybackTokens,
            requestID: UUID,
            range: Range<Int64>?,
            consumerCount: Int?
        )?
        switch (target, event) {
        case (
            .requestTaskEntry(let expectedID),
            .requestTaskWillEnter(let tokens, let requestID)
        ) where requestID == expectedID:
            match = (tokens, requestID, nil, nil)
        case (
            .upstreamTaskStart(let expectedID, let expectedRange),
            .upstreamTaskWillStartTransport(
                let tokens,
                let requestID,
                let range
            )
        ) where requestID == expectedID && range == expectedRange:
            match = (tokens, requestID, range, nil)
        case (
            .generationRunReconcile(let expectedID),
            .generationRunDidReconcile(let tokens, let requestID)
        ) where requestID == expectedID:
            match = (tokens, requestID, nil, nil)
        case (
            .permitResolution(let expectedID),
            .permitWillResolve(let tokens, let requestID)
        ) where requestID == expectedID:
            match = (tokens, requestID, nil, nil)
        case (
            .candidateRead(let expectedID),
            .candidateReadWillAuthorize(let tokens, let requestID, let range)
        ) where requestID == expectedID:
            match = (tokens, requestID, range, nil)
        case (
            .staleDetach(let expectedID),
            .staleLeaseWillDetach(let tokens, let requestID)
        ) where requestID == expectedID:
            match = (tokens, requestID, nil, nil)
        case (
            .generationConsumerCount(let expectedCount),
            .generationConsumerAttached(
                let tokens,
                let requestID,
                let consumerCount
            )
        ) where consumerCount == expectedCount:
            match = (tokens, requestID, nil, consumerCount)
        case (
            .generationConsumerDetach(let expectedID),
            .generationConsumerWillDetach(let tokens, let requestID)
        ) where requestID == expectedID:
            match = (tokens, requestID, nil, nil)
        case (
            .fetchTerminalReservation(let expectedID, let expectedRange),
            .fetchTerminalWillReleaseReservation(
                let tokens,
                let requestID,
                let range
            )
        ) where requestID == expectedID && range == expectedRange:
            match = (tokens, requestID, range, nil)
        case (
            .transportChunkAccounting(
                let expectedID,
                let expectedRange,
                let expectedCumulativeBytes
            ),
            .validatedTransportChunkWillAccount(
                let tokens,
                let requestID,
                let range,
                let cumulativeBytes
            )
        ) where requestID == expectedID && range == expectedRange
            && cumulativeBytes == expectedCumulativeBytes:
            match = (tokens, requestID, range, nil)
        default:
            match = nil
        }
        guard let match else { return }
        matchCount = 1
        matchedTokens = match.tokens
        matchedRequestID = match.requestID
        matchedRange = match.range
        matchedConsumerCount = match.consumerCount
        heldMilestone.reach(1)
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        drainedMilestone.reach(1)
    }

    func waitUntilHeld() async {
        await heldMilestone.wait(until: 1, label: "range lifecycle hold")
    }

    func release() {
        released = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    func waitUntilDrained() async {
        await drainedMilestone.wait(until: 1, label: "range lifecycle drain")
    }

    func observation() -> RangeLifecycleGateObservation {
        RangeLifecycleGateObservation(
            matchCount: matchCount,
            tokens: matchedTokens,
            requestID: matchedRequestID,
            range: matchedRange,
            consumerCount: matchedConsumerCount
        )
    }
}

private struct RangeCancellationResponseObservation: Sendable {
    let cancellationEntered: Bool
    let cancellationReturned: Bool
    let cancellationReturnedBeforeResponseReturned: Bool
    let leaseWasAbsentWhenCancellationReturned: Bool
    let finishCount: Int
    let errorFinishCount: Int
}

private final class RangeCancellationDuringResponseRequest: ResourceLoadingRequest,
    @unchecked Sendable
{
    let dataDemand: ResourceLoadingDataDemand?

    private let delegateQueue: DispatchQueue
    private let cancelAndCheckLease: @Sendable () -> Bool
    private let enteredSemaphore = DispatchSemaphore(value: 0)
    private let returnedSemaphore = DispatchSemaphore(value: 0)
    private let enteredMilestone = RangeAsyncCountMilestone()
    private let returnedMilestone = RangeAsyncCountMilestone()
    private let lock = NSLock()
    private var cancellationEntered = false
    private var cancellationReturned = false
    private var cancellationReturnedBeforeResponseReturned = false
    private var leaseWasAbsentWhenCancellationReturned = false
    private var finishCount = 0
    private var errorFinishCount = 0

    init(
        dataDemand: ResourceLoadingDataDemand,
        delegateQueue: DispatchQueue,
        cancelAndCheckLease: @escaping @Sendable () -> Bool
    ) {
        self.dataDemand = dataDemand
        self.delegateQueue = delegateQueue
        self.cancelAndCheckLease = cancelAndCheckLease
    }

    func setContentInformation(_: ResourceContentInformation) {}

    func respond(with _: Data) {
        delegateQueue.async { [self] in
            lock.lock()
            cancellationEntered = true
            lock.unlock()
            enteredMilestone.reach(1)
            enteredSemaphore.signal()

            let leaseIsAbsent = cancelAndCheckLease()
            lock.lock()
            cancellationReturned = true
            leaseWasAbsentWhenCancellationReturned = leaseIsAbsent
            lock.unlock()
            returnedMilestone.reach(1)
            returnedSemaphore.signal()
        }
        let entered = enteredSemaphore.wait(timeout: .now() + 5) == .success
        let returned = entered
            && returnedSemaphore.wait(timeout: .now() + 1) == .success
        lock.lock()
        cancellationReturnedBeforeResponseReturned = returned
        lock.unlock()
    }

    func finish() {
        lock.withLock { finishCount += 1 }
    }

    func finish(with _: Error) {
        lock.withLock { errorFinishCount += 1 }
    }

    func waitUntilCancellationEntered() async {
        await enteredMilestone.wait(
            until: 1,
            label: "delegate-queue cancellation entry"
        )
    }

    func waitUntilCancellationReturned() async {
        await returnedMilestone.wait(
            until: 1,
            label: "delegate-queue cancellation return"
        )
    }

    func observation() -> RangeCancellationResponseObservation {
        lock.withLock {
            RangeCancellationResponseObservation(
                cancellationEntered: cancellationEntered,
                cancellationReturned: cancellationReturned,
                cancellationReturnedBeforeResponseReturned:
                    cancellationReturnedBeforeResponseReturned,
                leaseWasAbsentWhenCancellationReturned:
                    leaseWasAbsentWhenCancellationReturned,
                finishCount: finishCount,
                errorFinishCount: errorFinishCount
            )
        }
    }
}

private struct RangeHeldGenerationObservation: Sendable {
    let validationCount: Int
    let cancellationCount: Int
    let matchingValidationTokenCount: Int
    let mismatchingValidationTokenCount: Int
    let matchingCancellationTokenCount: Int
    let mismatchingCancellationTokenCount: Int
}

private actor RangeHeldGenerationTransport: MediaByteTransport {
    private struct PendingValidation {
        let scope: ContentGenerationScope
        let continuation: CheckedContinuation<ContentGenerationScope, Error>
    }

    private let payloadLength: Int64
    private let expectedValidationTokens: [ActivePlaybackTokens]
    private let expectedCancellationTokens: [ActivePlaybackTokens]
    private let startedMilestone = RangeAsyncCountMilestone()
    private let cancelledMilestone = RangeAsyncCountMilestone()
    private var validationCount = 0
    private var cancellationCount = 0
    private var matchingValidationTokenCount = 0
    private var mismatchingValidationTokenCount = 0
    private var matchingCancellationTokenCount = 0
    private var mismatchingCancellationTokenCount = 0
    private var pendingValidations: [PendingValidation] = []
    private var released = false

    init(
        payloadLength: Int64,
        expectedValidationTokens: [ActivePlaybackTokens] = [],
        expectedCancellationTokens: [ActivePlaybackTokens] = []
    ) {
        self.payloadLength = payloadLength
        self.expectedValidationTokens = expectedValidationTokens
        self.expectedCancellationTokens = expectedCancellationTokens
    }

    func validateGeneration(
        for descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> ContentGenerationScope {
        validationCount += 1
        if let expected = expectedValidationTokens.dropFirst(
            validationCount - 1
        ).first {
            if expected == tokens {
                matchingValidationTokenCount += 1
            } else {
                mismatchingValidationTokenCount += 1
            }
        }
        startedMilestone.reach(validationCount)
        let scope = ContentGenerationScope.persistent(
            ValidatedContentGeneration(
                provisionalKey: descriptor.provisionalResourceKey,
                totalLength: payloadLength,
                strongValidator: "\"task9-held-generation\""
            )
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if released {
                    continuation.resume(returning: scope)
                } else {
                    pendingValidations.append(
                        PendingValidation(
                            scope: scope,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.recordCancellation(tokens: tokens) }
        }
    }

    nonisolated func bytes(
        for _: MediaByteRequest
    ) -> AsyncThrowingStream<ValidatedMediaChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MediaTransportError.invalidRequest)
        }
    }

    func waitUntilValidationCount(_ expectedCount: Int) async {
        await startedMilestone.wait(
            until: expectedCount,
            label: "held generation validation"
        )
    }

    func waitUntilCancellationCount(_ expectedCount: Int) async {
        await cancelledMilestone.wait(
            until: expectedCount,
            label: "held generation cancellation"
        )
    }

    func release() {
        released = true
        let pending = pendingValidations
        pendingValidations.removeAll()
        pending.forEach { validation in
            validation.continuation.resume(throwing: CancellationError())
        }
    }

    func releaseSuccessfully() {
        released = true
        let pending = pendingValidations
        pendingValidations.removeAll()
        pending.forEach { validation in
            validation.continuation.resume(returning: validation.scope)
        }
    }

    func observation() -> RangeHeldGenerationObservation {
        RangeHeldGenerationObservation(
            validationCount: validationCount,
            cancellationCount: cancellationCount,
            matchingValidationTokenCount: matchingValidationTokenCount,
            mismatchingValidationTokenCount: mismatchingValidationTokenCount,
            matchingCancellationTokenCount: matchingCancellationTokenCount,
            mismatchingCancellationTokenCount: mismatchingCancellationTokenCount
        )
    }

    private func recordCancellation(tokens: ActivePlaybackTokens) {
        cancellationCount += 1
        if let expected = expectedCancellationTokens.dropFirst(
            cancellationCount - 1
        ).first {
            if expected == tokens {
                matchingCancellationTokenCount += 1
            } else {
                mismatchingCancellationTokenCount += 1
            }
        }
        cancelledMilestone.reach(cancellationCount)
    }
}

private struct RangeReverseDeliveryObservation: Sendable {
    let generationValidationCount: Int
    let mediaRequestCount: Int
    let mediaRequestedRanges: [Range<Int64>]
    let mediaByteCeilings: [Int64?]
    let releaseOrder: [Range<Int64>]
    let maximumCumulativeBodyBytes: Int64
}

private actor RangeReverseDeliveryTransport: MediaByteTransport {
    private struct PendingResponse {
        let request: MediaByteRequest
        let continuation:
            AsyncThrowingStream<ValidatedMediaChunk, Error>.Continuation
    }

    private let payload: Data
    private let requestMilestone = RangeAsyncCountMilestone()
    private var generationValidationCount = 0
    private var mediaRequestedRanges: [Range<Int64>] = []
    private var mediaByteCeilings: [Int64?] = []
    private var pendingByLowerBound: [Int64: PendingResponse] = [:]
    private var releaseOrder: [Range<Int64>] = []
    private var maximumCumulativeBodyBytes: Int64 = 0

    init(payload: Data) {
        self.payload = payload
    }

    func validateGeneration(
        for descriptor: StreamDescriptor,
        tokens _: ActivePlaybackTokens
    ) async throws -> ContentGenerationScope {
        generationValidationCount += 1
        return .persistent(
            ValidatedContentGeneration(
                provisionalKey: descriptor.provisionalResourceKey,
                totalLength: Int64(payload.count),
                strongValidator: "\"task9-reverse-delivery\""
            )
        )
    }

    nonisolated func bytes(
        for request: MediaByteRequest
    ) -> AsyncThrowingStream<ValidatedMediaChunk, Error> {
        let pair = AsyncThrowingStream.makeStream(
            of: ValidatedMediaChunk.self,
            throwing: Error.self
        )
        Task {
            await self.register(request, continuation: pair.continuation)
        }
        return pair.stream
    }

    func waitUntilMediaRequestCount(_ expectedCount: Int) async {
        await requestMilestone.wait(
            until: expectedCount,
            label: "reverse-delivery media request"
        )
    }

    func release(range: Range<Int64>) {
        guard let pending = pendingByLowerBound.removeValue(
            forKey: range.lowerBound
        ), pending.request.range == range else {
            XCTFail("missing privacy-safe reverse-delivery range")
            return
        }
        let data = payload.subdata(
            in: Int(range.lowerBound)..<Int(range.upperBound)
        )
        let cumulativeBodyBytes = range.upperBound + 1
        maximumCumulativeBodyBytes = max(
            maximumCumulativeBodyBytes,
            cumulativeBodyBytes
        )
        releaseOrder.append(range)
        _ = pending.continuation.yield(
            ValidatedMediaChunk(
                absoluteRange: range,
                payload: data,
                generationScope: .persistent(
                    ValidatedContentGeneration(
                        provisionalKey: pending.request.descriptor.provisionalResourceKey,
                        totalLength: Int64(payload.count),
                        strongValidator: "\"task9-reverse-delivery\""
                    )
                ),
                cumulativeResponseBodyBytes: cumulativeBodyBytes
            )
        )
        pending.continuation.finish()
    }

    func observation() -> RangeReverseDeliveryObservation {
        RangeReverseDeliveryObservation(
            generationValidationCount: generationValidationCount,
            mediaRequestCount: mediaRequestedRanges.count,
            mediaRequestedRanges: mediaRequestedRanges,
            mediaByteCeilings: mediaByteCeilings,
            releaseOrder: releaseOrder,
            maximumCumulativeBodyBytes: maximumCumulativeBodyBytes
        )
    }

    private func register(
        _ request: MediaByteRequest,
        continuation: AsyncThrowingStream<ValidatedMediaChunk, Error>.Continuation
    ) {
        guard let range = request.range,
            range.lowerBound >= 0,
            range.upperBound <= Int64(payload.count),
            pendingByLowerBound[range.lowerBound] == nil
        else {
            continuation.finish(throwing: MediaTransportError.invalidRequest)
            return
        }
        mediaRequestedRanges.append(range)
        mediaByteCeilings.append(request.byteCeiling)
        pendingByLowerBound[range.lowerBound] = PendingResponse(
            request: request,
            continuation: continuation
        )
        requestMilestone.reach(mediaRequestedRanges.count)
    }
}

private actor RangeValidatedChunkResponseGate {
    private let heldMilestone = RangeAsyncCountMilestone()
    private let drainedMilestone = RangeAsyncCountMilestone()
    private let respondAttemptedMilestone = RangeAsyncCountMilestone()
    private var heldIdentity: (tokens: ActivePlaybackTokens, requestID: UUID)?
    private var attemptedIdentity: (tokens: ActivePlaybackTokens, requestID: UUID)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func hold(tokens: ActivePlaybackTokens, requestID: UUID) async {
        heldIdentity = (tokens, requestID)
        heldMilestone.reach(1)
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        drainedMilestone.reach(1)
    }

    func waitUntilHeld() async {
        await heldMilestone.wait(
            until: 1,
            label: "validated range chunk queued before respond"
        )
    }

    func identity() -> (tokens: ActivePlaybackTokens, requestID: UUID)? {
        heldIdentity
    }

    func release() {
        isReleased = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    func waitUntilDrained() async {
        await drainedMilestone.wait(
            until: 1,
            label: "revoked validated range callback drain"
        )
    }

    func recordRespondAttempt(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    ) {
        attemptedIdentity = (tokens, requestID)
        respondAttemptedMilestone.reach(1)
    }

    func waitUntilRespondAttempted() async {
        await respondAttemptedMilestone.wait(
            until: 1,
            label: "validated range respond attempt"
        )
    }

    func respondAttemptIdentity() -> (
        tokens: ActivePlaybackTokens,
        requestID: UUID
    )? {
        attemptedIdentity
    }
}

private actor RangeRequestExitProbe {
    private let recordedMilestone = RangeAsyncCountMilestone()
    private var recordedIdentities: [(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    )] = []

    func record(tokens: ActivePlaybackTokens, requestID: UUID) {
        recordedIdentities.append((tokens, requestID))
        recordedMilestone.reach(recordedIdentities.count)
    }

    func waitUntilRecorded(_ expectedCount: Int = 1) async {
        await recordedMilestone.wait(
            until: expectedCount,
            label: "range request task exit"
        )
    }

    func identity() -> (tokens: ActivePlaybackTokens, requestID: UUID)? {
        recordedIdentities.last
    }

    func identities() -> [(tokens: ActivePlaybackTokens, requestID: UUID)] {
        recordedIdentities
    }
}

private enum RangeDelegateQueueExecutionEvent: Equatable {
    case firstEntered
    case firstExited
    case secondEntered
    case secondExited
}

private struct RangeDelegateQueueExecutionObservation {
    let events: [RangeDelegateQueueExecutionEvent]
    let maximumConcurrentExecutions: Int
    let allExecutionsMatchedQueueIdentity: Bool
    let executedOnMainThread: Bool
    let firstExecutionTimedOut: Bool
}

private struct RangeResourceLoaderDelegateInstallationObservation {
    let callCount: Int
    let delegateIdentity: ObjectIdentifier
    let queueIdentity: ObjectIdentifier
}

private final class RangeResourceLoaderDelegateInstallerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var delegateIdentity: ObjectIdentifier?
    private var queueIdentity: ObjectIdentifier?

    func install(
        resourceLoader: AVAssetResourceLoader,
        delegate: RangeResourceLoaderDelegate,
        queue: DispatchQueue
    ) {
        lock.lock()
        callCount += 1
        delegateIdentity = ObjectIdentifier(delegate)
        queueIdentity = ObjectIdentifier(queue)
        lock.unlock()
        resourceLoader.setDelegate(delegate, queue: queue)
    }

    func observation() -> RangeResourceLoaderDelegateInstallationObservation? {
        lock.lock()
        defer { lock.unlock() }
        guard let delegateIdentity, let queueIdentity else { return nil }
        return RangeResourceLoaderDelegateInstallationObservation(
            callCount: callCount,
            delegateIdentity: delegateIdentity,
            queueIdentity: queueIdentity
        )
    }
}

private final class RangeDelegateQueueExecutionProbe: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueSpecificKey = DispatchSpecificKey<UUID>()
    private let queueIdentity = UUID()
    private let firstRelease = DispatchSemaphore(value: 0)
    private let firstEnteredMilestone = RangeAsyncCountMilestone()
    private let completedMilestone = RangeAsyncCountMilestone()
    private let lock = NSLock()
    private var events: [RangeDelegateQueueExecutionEvent] = []
    private var activeExecutions = 0
    private var maximumConcurrentExecutions = 0
    private var allExecutionsMatchedQueueIdentity = true
    private var executedOnMainThread = false
    private var firstExecutionTimedOut = false
    private var completedExecutions = 0

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: queueSpecificKey, value: queueIdentity)
    }

    func begin() {
        queue.async { [self] in
            enter(.firstEntered)
            firstEnteredMilestone.reach(1)
            let waitResult = firstRelease.wait(timeout: .now() + 5)
            if waitResult == .timedOut {
                lock.lock()
                firstExecutionTimedOut = true
                lock.unlock()
            }
            exit(.firstExited)
        }
        queue.async { [self] in
            enter(.secondEntered)
            exit(.secondExited)
        }
    }

    func waitUntilFirstExecutionEntered() async {
        await firstEnteredMilestone.wait(
            until: 1,
            label: "first delegate queue execution"
        )
    }

    func releaseFirstExecution() {
        firstRelease.signal()
    }

    func waitUntilCompleted() async {
        await completedMilestone.wait(
            until: 2,
            label: "serial delegate queue execution"
        )
    }

    func observation() -> RangeDelegateQueueExecutionObservation {
        lock.lock()
        defer { lock.unlock() }
        return RangeDelegateQueueExecutionObservation(
            events: events,
            maximumConcurrentExecutions: maximumConcurrentExecutions,
            allExecutionsMatchedQueueIdentity: allExecutionsMatchedQueueIdentity,
            executedOnMainThread: executedOnMainThread,
            firstExecutionTimedOut: firstExecutionTimedOut
        )
    }

    private func enter(_ event: RangeDelegateQueueExecutionEvent) {
        let matchesIdentity = DispatchQueue.getSpecific(key: queueSpecificKey)
            == queueIdentity
        lock.lock()
        events.append(event)
        activeExecutions += 1
        maximumConcurrentExecutions = max(
            maximumConcurrentExecutions,
            activeExecutions
        )
        allExecutionsMatchedQueueIdentity =
            allExecutionsMatchedQueueIdentity && matchesIdentity
        executedOnMainThread = executedOnMainThread || Thread.isMainThread
        lock.unlock()
    }

    private func exit(_ event: RangeDelegateQueueExecutionEvent) {
        lock.lock()
        events.append(event)
        activeExecutions -= 1
        completedExecutions += 1
        let completed = completedExecutions
        lock.unlock()
        completedMilestone.reach(completed)
    }
}

private final class RangeFeatureSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlaybackFeatureSnapshot
    private var scriptedValues: [PlaybackFeatureSnapshot] = []
    private var snapshotInvocationCount = 0

    init(_ value: PlaybackFeatureSnapshot) {
        self.value = value
    }

    init?(scriptedSnapshots: [PlaybackFeatureSnapshot]) {
        guard let fallback = scriptedSnapshots.last else { return nil }
        value = fallback
        scriptedValues = scriptedSnapshots
    }

    func snapshot() -> PlaybackFeatureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        snapshotInvocationCount += 1
        if !scriptedValues.isEmpty {
            return scriptedValues.removeFirst()
        }
        return value
    }

    func update(_ value: PlaybackFeatureSnapshot) {
        lock.lock()
        self.value = value
        scriptedValues.removeAll()
        lock.unlock()
    }

    func invocationCount() -> Int {
        lock.withLock { snapshotInvocationCount }
    }
}
