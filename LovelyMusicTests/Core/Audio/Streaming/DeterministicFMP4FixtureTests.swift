import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation
import XCTest
@testable import LovelyMusic

final class DeterministicFMP4FixtureTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let nominalBitrate = 128_000.0
    private let packetDuration = 1_024.0 / 48_000.0
    private let expectedPeakDecibels = -12.0
    private let expectedSineRMSDecibels = -12.0 - 10 * log10(2)
    private let aacAmplitudeToleranceDecibels = 3.0

    func testTwentySecondFixtureMatchesIndependentMediaContainerAndToneOracles()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-20.mp4")
            let generated = try await DeterministicFMP4Fixture.generate(
                configuration: .twentySeconds,
                outputURL: outputURL,
                timeout: .seconds(30)
            )
            let inspection = try await IndependentFixtureInspector.inspect(
                url: outputURL,
                expectedPresentationDurationSeconds: 20,
                expectedToneRegions: Self.twentySecondToneRegions
            )

            XCTAssertEqual(generated.url.standardizedFileURL, outputURL.standardizedFileURL)
            assertIndependentFixture(
                inspection,
                expectedDuration: 20,
                expectedToneRegions: Self.twentySecondToneRegions
            )
            assertManifest(
                generated.manifest,
                matches: inspection,
                expectedDuration: 20,
                expectedToneRegions: Self.twentySecondToneRegions
            )
        }
    }

    func testEncodingProfileLocksConstantAACParameters() {
        let profile: DeterministicFMP4Fixture.EncodingProfile =
            DeterministicFMP4Fixture.encodingProfile
        requireSendable(profile)
        XCTAssertEqual(profile.codec, .aac)
        XCTAssertEqual(profile.sampleRate, 48_000)
        XCTAssertEqual(profile.channelCount, 1)
        XCTAssertEqual(profile.nominalBitrateBitsPerSecond, 128_000)
        XCTAssertEqual(profile.bitrateMode, .constant)
    }

    func testSuccessfulGenerationPublishesCompleteOrderedLifecycle() async throws {
        await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-lifecycle.mp4")
            let recorder = SuccessfulFixtureLifecycleRecorder()
            let payloadCapture = SegmentPayloadDiagnosticCapture()
            var capturedError: Error?
            do {
                _ = try await DeterministicFMP4Fixture.generate(
                    configuration: .twentySeconds,
                    outputURL: outputURL,
                    timeout: .seconds(30),
                    segmentPayloadTransform: { kind, ordinal, payload in
                        payloadCapture.record(
                            kind: kind,
                            ordinal: ordinal,
                            payload: payload
                        )
                        return payload
                    },
                    lifecycleHook: { event in await recorder.record(event) }
                )
            } catch {
                capturedError = error
            }

            let recordedEvents = await recorder.events()
            XCTAssertNil(
                capturedError,
                "events=\(recordedEvents), payloads=\(payloadCapture.summary()), "
                    + "timeline=\(payloadCapture.timelineSummary()), "
                    + "atoms=\(payloadCapture.structuralAtomSummary())"
            )
            XCTAssertEqual(
                recordedEvents,
                [
                    .writerDidStart,
                    .finishWritingDidStart,
                    .writerDidFinish,
                    .outputDidCommitBeforeTerminalClaim,
                    .completed,
                ]
            )
        }
    }

    func testRealWriterReportsPrivacySafeSegmentsBeforeCompletedAssembly() async throws {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-segment-report.mp4")
            let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let recorder = SegmentLifecycleRecorder()
            let generated = try await DeterministicFMP4Fixture.generate(
                configuration: .twentySeconds,
                outputURL: outputURL,
                timeout: .seconds(30),
                segmentAssemblyGate: assemblyGate,
                lifecycleHook: { event in await recorder.handle(event) }
            )
            let inspectorStages = InspectorStageRecorder()
            let inspection: IndependentFixtureInspection
            do {
                inspection = try await IndependentFixtureInspector.inspect(
                    url: outputURL,
                    expectedPresentationDurationSeconds: 20,
                    expectedToneRegions: Self.twentySecondToneRegions,
                    stageObserver: { inspectorStages.record($0) }
                )
            } catch {
                XCTFail(
                    "Real-writer inspection failed: "
                        + "\(inspectorStages.failureContext()), error=\(error)"
                )
                throw error
            }
            XCTAssertEqual(
                inspectorStages.stages(),
                [
                    .iso,
                    .assetTracks,
                    .audioTracks,
                    .formatDescriptions,
                    .esdsASC,
                    .duration,
                    .readerCreateStart,
                    .readerDecodeDrain,
                ]
            )
            assertIndependentFixture(
                inspection,
                expectedDuration: 20,
                expectedToneRegions: Self.twentySecondToneRegions
            )
            assertManifest(
                generated.manifest,
                matches: inspection,
                expectedDuration: 20,
                expectedToneRegions: Self.twentySecondToneRegions
            )

            let orderedEvents = await recorder.events()
            let segments: [DeterministicFMP4Fixture.SegmentCallbackObservation] =
                orderedEvents.compactMap { event in
                guard case let .segment(observation) = event else { return nil }
                return observation
            }
            let initializationSegments = segments.filter { $0.kind == .initialization }
            let mediaSegments = segments.filter { $0.kind == .media }
            XCTAssertEqual(segments.first?.kind, .initialization)
            XCTAssertTrue(segments.dropFirst().allSatisfy { $0.kind == .media })
            XCTAssertEqual(initializationSegments.count, 1)
            XCTAssertEqual(initializationSegments.first?.ordinal, 0)
            XCTAssertEqual(initializationSegments.first?.rawStartFrame, 0)
            XCTAssertEqual(initializationSegments.first?.rawEndFrame, 0)
            XCTAssertEqual(
                initializationSegments.first?.coveredPresentationStartFrame,
                0
            )
            XCTAssertEqual(
                initializationSegments.first?.coveredPresentationEndFrame,
                0
            )
            let presentationMediaStartFrame = inspection.presentationMediaStartFrame
            XCTAssertEqual(presentationMediaStartFrame, 2_112)
            XCTAssertEqual(
                initializationSegments.first?.presentationMediaStartFrame,
                presentationMediaStartFrame
            )
            XCTAssertGreaterThanOrEqual(mediaSegments.count, 20)
            XCTAssertLessThanOrEqual(mediaSegments.count, 21)
            XCTAssertLessThanOrEqual(segments.count, 22)
            XCTAssertEqual(
                mediaSegments.map(\.ordinal),
                Array(1..<(mediaSegments.count + 1))
            )
            let targetEndFrame: Int64 = 960_000
            let expectedRawPresentationEnd = presentationMediaStartFrame
                + targetEndFrame
            let terminalPadding = mediaSegments.last.flatMap { observation in
                observation.rawStartFrame == expectedRawPresentationEnd
                    && observation.rawEndFrame > observation.rawStartFrame
                    && observation.rawEndFrame
                        <= expectedRawPresentationEnd + 1_024
                    && observation.coveredPresentationStartFrame == targetEndFrame
                    && observation.coveredPresentationEndFrame == targetEndFrame
                    ? observation
                    : nil
            }
            let positivelyCoveredMedia = terminalPadding == nil
                ? mediaSegments
                : Array(mediaSegments.dropLast())
            XCTAssertTrue(positivelyCoveredMedia.allSatisfy {
                $0.rawStartFrame >= 0
                    && $0.rawEndFrame > $0.rawStartFrame
                    && $0.presentationMediaStartFrame
                        == presentationMediaStartFrame
                    && $0.coveredPresentationStartFrame >= 0
                    && $0.coveredPresentationEndFrame
                        > $0.coveredPresentationStartFrame
                    && $0.coveredPresentationEndFrame <= targetEndFrame
            })
            XCTAssertEqual(
                mediaSegments.filter {
                    $0.coveredPresentationStartFrame
                        == $0.coveredPresentationEndFrame
                },
                terminalPadding.map { [$0] } ?? []
            )
            XCTAssertEqual(
                mediaSegments.last?.coveredPresentationEndFrame,
                targetEndFrame
            )
            XCTAssertGreaterThanOrEqual(
                mediaSegments.last?.rawEndFrame ?? .min,
                expectedRawPresentationEnd
            )
            XCTAssertLessThanOrEqual(
                mediaSegments.last?.rawEndFrame ?? .max,
                expectedRawPresentationEnd + 1_024
            )
            XCTAssertEqual(mediaSegments.count, inspection.fragments.count)
            for (observation, fragment) in zip(mediaSegments, inspection.fragments) {
                let expectedRawStart = Int64(
                    (fragment.startSeconds * 48_000).rounded()
                )
                let expectedRawEnd = Int64(
                    (fragment.endSeconds * 48_000).rounded()
                )
                XCTAssertLessThanOrEqual(
                    abs(observation.rawStartFrame - expectedRawStart),
                    1
                )
                XCTAssertLessThanOrEqual(
                    abs(observation.rawEndFrame - expectedRawEnd),
                    1
                )
                XCTAssertEqual(
                    observation.coveredPresentationStartFrame,
                    min(
                        targetEndFrame,
                        max(
                            0,
                            observation.rawStartFrame
                                - presentationMediaStartFrame
                        )
                    )
                )
                XCTAssertEqual(
                    observation.coveredPresentationEndFrame,
                    min(
                        targetEndFrame,
                        max(
                            0,
                            observation.rawEndFrame
                                - presentationMediaStartFrame
                        )
                    )
                )
                XCTAssertEqual(
                    observation.presentationMediaStartFrame,
                    presentationMediaStartFrame
                )
            }
            XCTAssertTrue(assemblyGate.writerFinished)
            XCTAssertEqual(
                assemblyGate.presentationMediaStartFrame,
                presentationMediaStartFrame
            )
            XCTAssertEqual(assemblyGate.activeDeliveryCount, 0)
            XCTAssertEqual(
                assemblyGate.contiguousCoveredPresentationEndFrame,
                960_000
            )
            XCTAssertEqual(assemblyGate.successfulSealClaimCount, 1)
            let claimedSnapshot = try XCTUnwrap(assemblyGate.claimedSnapshot)
            XCTAssertEqual(
                claimedSnapshot.orderedEntries.map(\.observation),
                segments
            )
            let claimedBytes = claimedSnapshot.orderedEntries.reduce(into: Data()) {
                output, entry in
                output.append(entry.payload)
            }
            let publishedBytes = try Data(
                contentsOf: outputURL,
                options: .mappedIfSafe
            )
            XCTAssertEqual(claimedBytes, publishedBytes)
            XCTAssertEqual(sha256Hex(claimedBytes), generated.manifest.payloadSHA256)

            let writerFinishIndices = orderedEvents.indices.filter {
                orderedEvents[$0] == .writerDidFinish
            }
            let segmentEventIndices = orderedEvents.indices.filter { index in
                if case .segment = orderedEvents[index] { return true }
                return false
            }
            let sealClaimIndex = try XCTUnwrap(
                orderedEvents.firstIndex(of: .segmentAssemblySealDidClaim)
            )
            let outputCommitIndex = try XCTUnwrap(
                orderedEvents.firstIndex(of: .outputDidCommitBeforeTerminalClaim)
            )
            let terminalIndex = try XCTUnwrap(
                orderedEvents.firstIndex(of: .terminal(.completed))
            )
            let finalCoveredSegmentIndex = try XCTUnwrap(
                orderedEvents.firstIndex(where: { event in
                    guard case let .segment(observation) = event else { return false }
                    return observation.kind == .media
                        && observation.coveredPresentationEndFrame == 960_000
                })
            )
            XCTAssertEqual(writerFinishIndices.count, 1)
            XCTAssertEqual(segmentEventIndices.count, segments.count)
            XCTAssertTrue(segmentEventIndices.allSatisfy { $0 < sealClaimIndex })
            XCTAssertEqual(
                orderedEvents.filter { $0 == .segmentAssemblySealDidClaim }.count,
                1
            )
            XCTAssertEqual(
                orderedEvents.filter { $0 == .outputDidCommitBeforeTerminalClaim }.count,
                1
            )
            XCTAssertEqual(
                orderedEvents.filter { $0 == .terminal(.completed) }.count,
                1
            )
            XCTAssertLessThan(finalCoveredSegmentIndex, sealClaimIndex)
            XCTAssertLessThan(sealClaimIndex, outputCommitIndex)
            XCTAssertLessThan(outputCommitIndex, terminalIndex)
            XCTAssertEqual(generated.url.standardizedFileURL, outputURL.standardizedFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(
                try recursiveRelativeContents(in: directory),
                [outputURL.lastPathComponent]
            )
        }
    }

    func testPostSuccessDelegateIngressPoisonsClaimedAssemblyBeforeCommit()
        async throws
    {
        for ingressKind in PostSuccessSegmentIngressKind.allCases {
            try await withUniqueTemporaryDirectory { directory in
                let outputURL = directory.appendingPathComponent(
                    "post-success-ingress-\(ingressKind.name).mp4"
                )
                let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                    targetPresentationEndFrame: 960_000,
                    nominalFragmentFrameCount: 48_000,
                    packetFrameTolerance: 1_024
                )
                let sealClaimed = expectation(
                    description: "\(ingressKind.name) seal claimed"
                )
                let workerCloseRequested = expectation(
                    description: "\(ingressKind.name) worker close requested"
                )
                let generationCompleted = expectation(
                    description: "\(ingressKind.name) generation completed"
                )
                let completionProbe = GenerationCompletionProbe()
                let lifecycleGate = SealClaimLifecycleGate(
                    sealClaimed: sealClaimed,
                    workerCloseRequested: workerCloseRequested
                )
                defer { lifecycleGate.releaseSealClaim() }
                let finishStarter = CapturingFinishWritingStarter()
                defer { finishStarter.releaseCapturedObjects() }
                let generation = Task {
                    do {
                        let generated = try await DeterministicFMP4Fixture.generate(
                            configuration: .twentySeconds,
                            outputURL: outputURL,
                            timeout: .seconds(60),
                            finishWritingStarter: { writer, completion in
                                finishStarter.start(
                                    writer: writer,
                                    completion: completion
                                )
                            },
                            segmentAssemblyGate: assemblyGate,
                            lifecycleHook: { event in
                                await lifecycleGate.handle(event)
                            }
                        )
                        await completionProbe.markComplete()
                        generationCompleted.fulfill()
                        return generated
                    } catch {
                        await completionProbe.markComplete()
                        generationCompleted.fulfill()
                        throw error
                    }
                }

                await fulfillment(of: [sealClaimed], timeout: 30)
                guard lifecycleGate.hasSeenSealClaim(),
                    let writer = finishStarter.capturedWriter(),
                    finishStarter.hasCapturedDelegate(),
                    let claimedSnapshot = assemblyGate.claimedSnapshot,
                    let mediaEntry = claimedSnapshot.orderedEntries.last(where: {
                        $0.observation.kind == .media
                    })
                else {
                    generation.cancel()
                    lifecycleGate.releaseSealClaim()
                    await fulfillment(of: [generationCompleted], timeout: 30)
                    _ = await generation.result
                    XCTFail("Could not establish claimed real-writer ingress seam")
                    return
                }

                try ingressKind.invoke(
                    writer: writer,
                    payload: mediaEntry.payload
                )
                await fulfillment(of: [workerCloseRequested], timeout: 2)
                let closeSnapshots = lifecycleGate.workerCloseSnapshots()
                guard let closeSnapshot = closeSnapshots.first else {
                    generation.cancel()
                    lifecycleGate.releaseSealClaim()
                    await fulfillment(of: [generationCompleted], timeout: 30)
                    _ = await generation.result
                    XCTFail("Post-success ingress did not close the segment worker")
                    return
                }

                XCTAssertEqual(closeSnapshots.count, 1, ingressKind.name)
                XCTAssertEqual(
                    closeSnapshot.reason,
                    .validationFailed,
                    ingressKind.name
                )
                XCTAssertEqual(
                    closeSnapshot.activeCallbackCount,
                    1,
                    ingressKind.name
                )
                let completedWhileSealHeld = await completionProbe.isComplete()
                XCTAssertFalse(completedWhileSealHeld, ingressKind.name)
                XCTAssertTrue(assemblyGate.hasActiveGenerationLease, ingressKind.name)
                XCTAssertTrue(assemblyGate.isInvalid, ingressKind.name)
                XCTAssertTrue(
                    assemblyGate.writerCancellationRequested,
                    ingressKind.name
                )
                XCTAssertFalse(assemblyGate.isReadyForAssembly, ingressKind.name)
                XCTAssertEqual(lifecycleGate.outputCommitCount(), 0, ingressKind.name)
                XCTAssertTrue(
                    lifecycleGate.terminalOutcomes().isEmpty,
                    ingressKind.name
                )
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: outputURL.path),
                    ingressKind.name
                )
                XCTAssertEqual(
                    try recursiveRelativeContents(in: directory),
                    [],
                    ingressKind.name
                )

                lifecycleGate.releaseSealClaim()
                await fulfillment(of: [generationCompleted], timeout: 30)
                guard await completionProbe.isComplete() else {
                    generation.cancel()
                    lifecycleGate.releaseSealClaim()
                    _ = await generation.result
                    XCTFail("Post-success ingress generation did not drain")
                    return
                }
                do {
                    _ = try await generation.value
                    XCTFail("Post-success delegate ingress must prevent publication")
                } catch {
                    XCTAssertEqual(
                        error as? DeterministicFMP4Fixture.GenerationError,
                        .writerFailed,
                        ingressKind.name
                    )
                }
                XCTAssertFalse(assemblyGate.hasActiveGenerationLease)
                XCTAssertEqual(assemblyGate.activeDeliveryCount, 0)
                XCTAssertEqual(assemblyGate.retainedPayloadByteCount, 0)
                XCTAssertEqual(assemblyGate.claimedPayloadByteCount, 0)
                XCTAssertTrue(assemblyGate.isInvalid)
                XCTAssertTrue(assemblyGate.writerCancellationRequested)
                XCTAssertFalse(assemblyGate.isReadyForAssembly)
                XCTAssertEqual(lifecycleGate.outputCommitCount(), 0)
                XCTAssertEqual(lifecycleGate.terminalOutcomes(), [.failed])
                XCTAssertFalse(
                    lifecycleGate.terminalOutcomes().contains(.completed)
                )
                XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
                XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
            }
        }
    }

    func testNilLifecycleWorkerCloseObserverSeesPoisonedGateBeforeFailure()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent(
                "nil-lifecycle-worker-close.mp4"
            )
            let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let closeObserved = expectation(
                description: "synchronous nil-lifecycle worker close observed"
            )
            let generationCompleted = expectation(
                description: "nil-lifecycle failure completed"
            )
            let completionProbe = GenerationCompletionProbe()
            let transformer = ImmediateSecondMediaSegmentTruncator()
            let observer = SynchronousWorkerCloseObserver(
                observed: closeObserved
            )
            defer { observer.release() }
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(60),
                        segmentPayloadTransform: { kind, ordinal, payload in
                            transformer.transform(
                                kind: kind,
                                ordinal: ordinal,
                                payload: payload
                            )
                        },
                        segmentWorkerCloseObserver: { snapshot in
                            observer.observe(
                                snapshot,
                                gate: assemblyGate
                            )
                        },
                        segmentAssemblyGate: assemblyGate
                    )
                    await completionProbe.markComplete()
                    generationCompleted.fulfill()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    generationCompleted.fulfill()
                    throw error
                }
            }

            await fulfillment(of: [closeObserved], timeout: 30)
            let observations = observer.observations()
            guard let observed = observations.first else {
                observer.release()
                generation.cancel()
                await fulfillment(of: [generationCompleted], timeout: 30)
                _ = await generation.result
                XCTFail("Nil-lifecycle close observer was not called")
                return
            }
            XCTAssertEqual(observations.count, 1)
            XCTAssertEqual(observed.snapshot.reason, .validationFailed)
            XCTAssertEqual(observed.snapshot.preprocessingAdmissionCount, 2)
            XCTAssertEqual(observed.snapshot.activePreprocessingCount, 0)
            XCTAssertEqual(observed.snapshot.activeCallbackCount, 1)
            XCTAssertEqual(
                observed.gateIdentifier,
                ObjectIdentifier(assemblyGate)
            )
            XCTAssertTrue(observed.gateWasInvalid)
            XCTAssertTrue(observed.writerCancellationWasRequested)
            XCTAssertFalse(observed.gateWasReady)
            XCTAssertTrue(observed.generationLeaseWasActive)
            XCTAssertTrue(assemblyGate.isInvalid)
            XCTAssertTrue(assemblyGate.writerCancellationRequested)
            XCTAssertFalse(assemblyGate.isReadyForAssembly)
            XCTAssertEqual(transformer.mediaTransformCount(), 2)
            let completedWhileObserverHeld = await completionProbe.isComplete()
            XCTAssertFalse(completedWhileObserverHeld)

            observer.release()

            await fulfillment(of: [generationCompleted], timeout: 30)
            guard await completionProbe.isComplete() else {
                generation.cancel()
                _ = await generation.result
                XCTFail("Nil-lifecycle worker failure did not drain")
                return
            }
            do {
                _ = try await generation.value
                XCTFail("Truncated payload must fail without a lifecycle hook")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .writerFailed
                )
            }
            XCTAssertFalse(assemblyGate.hasActiveGenerationLease)
            XCTAssertEqual(assemblyGate.activeDeliveryCount, 0)
            XCTAssertEqual(assemblyGate.retainedPayloadByteCount, 0)
            XCTAssertEqual(assemblyGate.claimedPayloadByteCount, 0)
            XCTAssertTrue(assemblyGate.isInvalid)
            XCTAssertTrue(assemblyGate.writerCancellationRequested)
            XCTAssertFalse(assemblyGate.isReadyForAssembly)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testParentCancellationClosesSegmentWorkerBeforeHeldHookDrains()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("worker-cancelled.mp4")
            let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let firstMediaHeld = expectation(description: "first media hook held")
            let writerDidFinish = expectation(description: "writer finished with hook held")
            let workerCloseRequested = expectation(
                description: "cancel requested segment worker close"
            )
            let heldHookAcknowledged = expectation(
                description: "cancelled held media hook acknowledged"
            )
            let completionOnMissingStart = expectation(
                description: "cancel worker missing-start drain"
            )
            let completionOnMissingClose = expectation(
                description: "cancel worker missing-close drain"
            )
            let completionAfterRelease = expectation(
                description: "cancel worker completed after hook release"
            )
            let completionProbe = GenerationCompletionProbe()
            let firstMediaHookEntered = FirstMediaHookEnteredLatch()
            defer { firstMediaHookEntered.release() }
            let workerGate = HeldFirstMediaWorkerGate(
                firstMediaHookEntered: firstMediaHookEntered,
                firstMediaHeld: firstMediaHeld,
                writerDidFinish: writerDidFinish,
                workerCloseRequested: workerCloseRequested,
                heldHookAcknowledged: heldHookAcknowledged
            )
            defer { workerGate.releaseHeldMediaHook() }
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(60),
                        segmentAssemblyGate: assemblyGate,
                        lifecycleHook: { event in
                            await workerGate.handle(event)
                            workerGate.acknowledge(event)
                        }
                    )
                    await completionProbe.markComplete()
                    completionOnMissingStart.fulfill()
                    completionOnMissingClose.fulfill()
                    completionAfterRelease.fulfill()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    completionOnMissingStart.fulfill()
                    completionOnMissingClose.fulfill()
                    completionAfterRelease.fulfill()
                    throw error
                }
            }

            await fulfillment(of: [firstMediaHeld, writerDidFinish], timeout: 30)
            guard workerGate.firstMediaWasHeld(), workerGate.writerFinishWasSeen() else {
                generation.cancel()
                workerGate.releaseHeldMediaHook()
                await fulfillment(
                    of: [
                        completionOnMissingStart,
                        completionOnMissingClose,
                        completionAfterRelease,
                    ],
                    timeout: 2
                )
                _ = await generation.result
                XCTFail("Worker test did not establish held media + writer finish")
                return
            }

            generation.cancel()
            await fulfillment(of: [workerCloseRequested], timeout: 2)
            guard workerGate.workerCloseWasSeen() else {
                workerGate.releaseHeldMediaHook()
                await fulfillment(
                    of: [
                        completionOnMissingStart,
                        completionOnMissingClose,
                        completionAfterRelease,
                    ],
                    timeout: 2
                )
                _ = await generation.result
                XCTFail("Cancellation did not request segment worker close")
                return
            }

            let retainedAtClose = assemblyGate.retainedPayloadByteCount
            XCTAssertGreaterThan(retainedAtClose, 0)
            let completedWhileHeld = await completionProbe.isComplete()
            let closeSnapshot = try XCTUnwrap(workerGate.closeSnapshots().first)
            XCTAssertEqual(workerGate.closeSnapshots().count, 1)
            XCTAssertEqual(closeSnapshot.reason, .parentCancelled)
            XCTAssertFalse(completedWhileHeld)
            XCTAssertTrue(assemblyGate.hasActiveGenerationLease)
            XCTAssertGreaterThan(assemblyGate.activeDeliveryCount, 0)
            XCTAssertTrue(assemblyGate.isInvalid)
            XCTAssertTrue(assemblyGate.writerCancellationRequested)
            XCTAssertFalse(assemblyGate.isReadyForAssembly)
            XCTAssertEqual(workerGate.outputCommitCount(), 0)
            XCTAssertTrue(workerGate.terminalOutcomes().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            assertDirectoryIsEmptyWithoutThrowing(directory)

            workerGate.releaseHeldMediaHook()
            await fulfillment(of: [heldHookAcknowledged], timeout: 2)
            await fulfillment(
                of: [
                    completionOnMissingStart,
                    completionOnMissingClose,
                    completionAfterRelease,
                ],
                timeout: 30
            )
            guard await completionProbe.isComplete() else {
                generation.cancel()
                workerGate.releaseHeldMediaHook()
                _ = await generation.result
                XCTFail("Cancelled segment worker did not drain after hook ACK")
                return
            }
            do {
                _ = try await generation.value
                XCTFail("Cancelled segment worker must not publish")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .cancelled
                )
            }
            XCTAssertFalse(assemblyGate.hasActiveGenerationLease)
            XCTAssertEqual(assemblyGate.activeDeliveryCount, 0)
            XCTAssertEqual(assemblyGate.retainedPayloadByteCount, 0)
            XCTAssertEqual(assemblyGate.claimedPayloadByteCount, 0)
            XCTAssertTrue(assemblyGate.isInvalid)
            XCTAssertTrue(assemblyGate.writerCancellationRequested)
            XCTAssertFalse(assemblyGate.isReadyForAssembly)
            XCTAssertThrowsError(try assemblyGate.claimAssembly()) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .gateInvalid
                )
            }
            XCTAssertEqual(assemblyGate.successfulSealClaimCount, 0)
            XCTAssertNil(assemblyGate.claimedSnapshot)
            XCTAssertEqual(workerGate.terminalOutcomes(), [.cancelled])
            XCTAssertTrue(workerGate.terminalIsLastEvent())
            XCTAssertEqual(
                workerGate.segmentEventCount(),
                workerGate.segmentEventCountAtClose()
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testParserFailureClosesSegmentWorkerBeforeHeldHookDrains()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("worker-validation-failed.mp4")
            let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let firstMediaHeld = expectation(description: "validation first media hook held")
            let workerCloseRequested = expectation(
                description: "validation requested segment worker close"
            )
            let heldHookAcknowledged = expectation(
                description: "validation held media hook acknowledged"
            )
            let completionOnMissingMilestone = expectation(
                description: "validation missing-milestone drain"
            )
            let completionAfterRelease = expectation(
                description: "validation worker completed after release"
            )
            let completionProbe = GenerationCompletionProbe()
            let firstMediaHookEntered = FirstMediaHookEnteredLatch()
            defer { firstMediaHookEntered.release() }
            let payloadTransformer = TruncateSecondMediaSegmentPayload(
                firstMediaHookEntered: firstMediaHookEntered
            )
            let workerGate = HeldFirstMediaWorkerGate(
                firstMediaHookEntered: firstMediaHookEntered,
                firstMediaHeld: firstMediaHeld,
                workerCloseRequested: workerCloseRequested,
                heldHookAcknowledged: heldHookAcknowledged
            )
            defer { workerGate.releaseHeldMediaHook() }
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(60),
                        segmentPayloadTransform: { kind, ordinal, payload in
                            try payloadTransformer.transform(
                                kind: kind,
                                ordinal: ordinal,
                                payload: payload
                            )
                        },
                        segmentAssemblyGate: assemblyGate,
                        lifecycleHook: { event in
                            await workerGate.handle(event)
                            workerGate.acknowledge(event)
                        }
                    )
                    await completionProbe.markComplete()
                    completionOnMissingMilestone.fulfill()
                    completionAfterRelease.fulfill()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    completionOnMissingMilestone.fulfill()
                    completionAfterRelease.fulfill()
                    throw error
                }
            }

            await fulfillment(
                of: [firstMediaHeld, workerCloseRequested],
                timeout: 30
            )
            guard workerGate.firstMediaWasHeld(),
                workerGate.workerCloseWasSeen()
            else {
                generation.cancel()
                workerGate.releaseHeldMediaHook()
                await fulfillment(
                    of: [
                        completionOnMissingMilestone,
                        completionAfterRelease,
                    ],
                    timeout: 2
                )
                _ = await generation.result
                XCTFail("Validation worker milestones were incomplete")
                return
            }

            let retainedAtClose = assemblyGate.retainedPayloadByteCount
            XCTAssertGreaterThan(retainedAtClose, 0)
            let completedWhileHeld = await completionProbe.isComplete()
            XCTAssertGreaterThanOrEqual(payloadTransformer.mediaTransformCount(), 2)
            XCTAssertTrue(payloadTransformer.didTruncateSecondMediaPayload())
            let closeSnapshot = try XCTUnwrap(workerGate.closeSnapshots().first)
            XCTAssertEqual(workerGate.closeSnapshots().count, 1)
            XCTAssertEqual(closeSnapshot.reason, .validationFailed)
            XCTAssertEqual(closeSnapshot.preprocessingAdmissionCount, 2)
            XCTAssertEqual(closeSnapshot.activePreprocessingCount, 0)
            XCTAssertFalse(completedWhileHeld)
            XCTAssertTrue(assemblyGate.hasActiveGenerationLease)
            XCTAssertGreaterThan(assemblyGate.activeDeliveryCount, 0)
            XCTAssertTrue(assemblyGate.isInvalid)
            XCTAssertTrue(assemblyGate.writerCancellationRequested)
            XCTAssertFalse(assemblyGate.isReadyForAssembly)
            XCTAssertEqual(workerGate.outputCommitCount(), 0)
            XCTAssertTrue(workerGate.terminalOutcomes().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            assertDirectoryIsEmptyWithoutThrowing(directory)

            workerGate.releaseHeldMediaHook()
            await fulfillment(of: [heldHookAcknowledged], timeout: 2)
            await fulfillment(
                of: [
                    completionOnMissingMilestone,
                    completionAfterRelease,
                ],
                timeout: 30
            )
            guard await completionProbe.isComplete() else {
                generation.cancel()
                workerGate.releaseHeldMediaHook()
                _ = await generation.result
                XCTFail("Validation-failed worker did not drain after hook ACK")
                return
            }
            do {
                _ = try await generation.value
                XCTFail("Validation failure must terminate generation")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .writerFailed
                )
            }
            XCTAssertFalse(assemblyGate.hasActiveGenerationLease)
            XCTAssertEqual(assemblyGate.activeDeliveryCount, 0)
            XCTAssertEqual(assemblyGate.retainedPayloadByteCount, 0)
            XCTAssertEqual(assemblyGate.claimedPayloadByteCount, 0)
            XCTAssertTrue(assemblyGate.isInvalid)
            XCTAssertTrue(assemblyGate.writerCancellationRequested)
            XCTAssertFalse(assemblyGate.isReadyForAssembly)
            XCTAssertThrowsError(try assemblyGate.claimAssembly()) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .gateInvalid
                )
            }
            XCTAssertEqual(assemblyGate.successfulSealClaimCount, 0)
            XCTAssertNil(assemblyGate.claimedSnapshot)
            XCTAssertEqual(workerGate.terminalOutcomes(), [.failed])
            XCTAssertTrue(workerGate.terminalIsLastEvent())
            XCTAssertEqual(
                workerGate.segmentEventCount(),
                workerGate.segmentEventCountAtClose()
            )
            XCTAssertEqual(
                payloadTransformer.mediaTransformCount(),
                closeSnapshot.preprocessingAdmissionCount
            )
            XCTAssertEqual(closeSnapshot.activePreprocessingCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testProductionInitRejectsInconsistentEditProfileMutations() async throws {
        for mutation in InitializationEditMutation.allCases {
            try await withUniqueTemporaryDirectory { directory in
                let outputURL = directory.appendingPathComponent(
                    "mutated-init-\(mutation.name).mp4"
                )
                let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                    targetPresentationEndFrame: 960_000,
                    nominalFragmentFrameCount: 48_000,
                    packetFrameTolerance: 1_024
                )
                let workerCloseRequested = expectation(
                    description: "\(mutation.name) closed worker"
                )
                let generationCompleted = expectation(
                    description: "\(mutation.name) generation completed"
                )
                let completionProbe = GenerationCompletionProbe()
                let mutator = InitializationEditProfileMutator(
                    mutation: mutation
                )
                let recorder = InitMutationLifecycleRecorder(
                    workerCloseRequested: workerCloseRequested
                )
                let generation = Task {
                    do {
                        let generated = try await DeterministicFMP4Fixture.generate(
                            configuration: .twentySeconds,
                            outputURL: outputURL,
                            timeout: .seconds(60),
                            segmentPayloadTransform: { kind, ordinal, payload in
                                try mutator.transform(
                                    kind: kind,
                                    ordinal: ordinal,
                                    payload: payload
                                )
                            },
                            segmentAssemblyGate: assemblyGate,
                            lifecycleHook: { event in recorder.handle(event) }
                        )
                        await completionProbe.markComplete()
                        generationCompleted.fulfill()
                        return generated
                    } catch {
                        await completionProbe.markComplete()
                        generationCompleted.fulfill()
                        throw error
                    }
                }

                await fulfillment(
                    of: [workerCloseRequested, generationCompleted],
                    timeout: 30
                )
                let didComplete = await completionProbe.isComplete()
                guard recorder.closeSnapshots().count == 1, didComplete else {
                    generation.cancel()
                    _ = await generation.result
                    XCTFail(
                        "\(mutation.name) initialization did not close and drain once"
                    )
                    return
                }
                do {
                    _ = try await generation.value
                    XCTFail("\(mutation.name) initialization must fail generation")
                } catch {
                    XCTAssertEqual(
                        error as? DeterministicFMP4Fixture.GenerationError,
                        .writerFailed
                    )
                }
                XCTAssertTrue(mutator.didApplyMutation(), mutation.name)
                XCTAssertEqual(
                    recorder.closeSnapshots().first?.reason,
                    .validationFailed,
                    mutation.name
                )
                XCTAssertEqual(recorder.outputCommitCount(), 0, mutation.name)
                XCTAssertEqual(recorder.terminalOutcomes(), [.failed], mutation.name)
                XCTAssertTrue(assemblyGate.isInvalid, mutation.name)
                XCTAssertTrue(
                    assemblyGate.writerCancellationRequested,
                    mutation.name
                )
                XCTAssertFalse(
                    assemblyGate.hasActiveGenerationLease,
                    mutation.name
                )
                XCTAssertEqual(assemblyGate.activeDeliveryCount, 0, mutation.name)
                XCTAssertEqual(
                    assemblyGate.retainedPayloadByteCount,
                    0,
                    mutation.name
                )
                XCTAssertEqual(
                    assemblyGate.claimedPayloadByteCount,
                    0,
                    mutation.name
                )
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: outputURL.path),
                    mutation.name
                )
                XCTAssertEqual(
                    try recursiveRelativeContents(in: directory),
                    [],
                    mutation.name
                )
            }
        }
    }

    func testGateInvalidationDuringSealClaimPreventsOutputCommit() async throws {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-seal-invalidated.mp4")
            let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let sealClaimed = expectation(description: "assembly seal claimed and held")
            let generationCompletedOnMissingSeal = expectation(
                description: "missing-seal generation drained"
            )
            let generationCompletedAfterSealRelease = expectation(
                description: "seal-invalidated generation completed after release"
            )
            let completionProbe = GenerationCompletionProbe()
            let lifecycleGate = SealClaimLifecycleGate(sealClaimed: sealClaimed)
            defer { lifecycleGate.releaseSealClaim() }
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(60),
                        segmentAssemblyGate: assemblyGate,
                        lifecycleHook: { event in await lifecycleGate.handle(event) }
                    )
                    await completionProbe.markComplete()
                    generationCompletedOnMissingSeal.fulfill()
                    generationCompletedAfterSealRelease.fulfill()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    generationCompletedOnMissingSeal.fulfill()
                    generationCompletedAfterSealRelease.fulfill()
                    throw error
                }
            }

            await fulfillment(of: [sealClaimed], timeout: 30)
            guard lifecycleGate.hasSeenSealClaim() else {
                generation.cancel()
                lifecycleGate.releaseSealClaim()
                await fulfillment(
                    of: [
                        generationCompletedOnMissingSeal,
                        generationCompletedAfterSealRelease,
                    ],
                    timeout: 2
                )
                _ = await generation.result
                XCTFail("Generation never reached the seal-claim hook")
                return
            }

            var unexpectedToken: DeterministicFMP4Fixture.SegmentDeliveryToken?
            do {
                unexpectedToken = try beginSegmentDelivery(
                    on: assemblyGate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: assemblyGate.maximumMediaSegmentCount + 1,
                        rawStartFrame: 959_999,
                        rawEndFrame: 961_024,
                        coveredStartFrame: 959_999,
                        coveredEndFrame: 960_000
                    ),
                    ownedPayload: Data("late-after-seal".utf8)
                )
                XCTFail("Delivery after seal claim must fail")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .deliveryAfterAssemblyClaim
                )
            }
            if let unexpectedToken {
                _ = try? assemblyGate.completeDelivery(unexpectedToken)
            }
            XCTAssertTrue(assemblyGate.writerCancellationRequested)
            let completedWhileSealHeld = await completionProbe.isComplete()
            let commitsWhileHeld = lifecycleGate.outputCommitCount()
            let outcomesWhileHeld = lifecycleGate.terminalOutcomes()
            XCTAssertFalse(completedWhileSealHeld)
            XCTAssertEqual(commitsWhileHeld, 0)
            XCTAssertTrue(outcomesWhileHeld.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            let heldContents: [String]
            do {
                heldContents = try recursiveRelativeContents(in: directory)
            } catch {
                XCTFail("Could not inspect seal-held directory: \(error)")
                heldContents = []
            }
            XCTAssertEqual(heldContents, [])

            lifecycleGate.releaseSealClaim()
            await fulfillment(
                of: [
                    generationCompletedOnMissingSeal,
                    generationCompletedAfterSealRelease,
                ],
                timeout: 30
            )
            let completedAfterRelease = await completionProbe.isComplete()
            guard completedAfterRelease else {
                generation.cancel()
                lifecycleGate.releaseSealClaim()
                _ = await generation.result
                XCTFail("Seal-invalidated generation did not drain after release")
                return
            }
            do {
                _ = try await generation.value
                XCTFail("Gate invalidation before commit must fail generation")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .writerFailed
                )
            }
            let finalOutcomes = lifecycleGate.terminalOutcomes()
            let finalCommitCount = lifecycleGate.outputCommitCount()
            XCTAssertEqual(finalOutcomes, [.failed])
            XCTAssertFalse(finalOutcomes.contains(.completed))
            XCTAssertEqual(finalCommitCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testGenerateRejectsMismatchedInjectedGateBeforeWriterActivity() async throws {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-mismatched-gate.mp4")
            let twentySecondGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let recorder = EarlyWriterActivityRecorder()
            do {
                _ = try await DeterministicFMP4Fixture.generate(
                    configuration: .sixtySeconds,
                    outputURL: outputURL,
                    timeout: .seconds(30),
                    segmentAssemblyGate: twentySecondGate,
                    lifecycleHook: { event in await recorder.handle(event) }
                )
                XCTFail("A 20-second gate must not be reused for 60-second generation")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .writerFailed
                )
            }

            let activities = await recorder.activities()
            XCTAssertEqual(activities, [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testGenerateRejectsClaimedAndInvalidGateReuseBeforeWriterActivity()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let claimedGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: claimedGate)
            let completeMedia = try beginSegmentDelivery(
                on: claimedGate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 961_024,
                    coveredStartFrame: 0,
                    coveredEndFrame: 960_000
                )
            )
            try claimedGate.completeDelivery(completeMedia)
            claimedGate.markWriterFinished()
            _ = try claimedGate.claimAssembly()

            let invalidGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: invalidGate)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: invalidGate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 1,
                        rawStartFrame: 0,
                        rawEndFrame: 961_025,
                        coveredStartFrame: 0,
                        coveredEndFrame: 960_000
                    )
                )
            )

            for (index, gate) in [claimedGate, invalidGate].enumerated() {
                let outputURL = directory.appendingPathComponent(
                    "fixture-reused-gate-\(index).mp4"
                )
                let recorder = EarlyWriterActivityRecorder()
                do {
                    _ = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(30),
                        segmentAssemblyGate: gate,
                        lifecycleHook: { event in await recorder.handle(event) }
                    )
                    XCTFail("Claimed or invalid gate reuse must fail")
                } catch {
                    XCTAssertEqual(
                        error as? DeterministicFMP4Fixture.GenerationError,
                        .writerFailed
                    )
                }
                let activities = await recorder.activities()
                XCTAssertEqual(activities, [])
                XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
                XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
            }
        }
    }

    func testGenerateRejectsStructurallyDirtyGatePreflightBeforeTimeoutOrWriter()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let wrongNominalGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 47_999,
                packetFrameTolerance: 1_024
            )
            let wrongToleranceGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_023
            )
            let dirtyActiveGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let heldInitialization = try beginSegmentDelivery(
                on: dirtyActiveGate,
                observation: makeSegmentObservation(
                    kind: .initialization,
                    ordinal: 0,
                    rawStartFrame: 0,
                    rawEndFrame: 0,
                    coveredStartFrame: 0,
                    coveredEndFrame: 0
                )
            )
            defer { try? dirtyActiveGate.completeDelivery(heldInitialization) }

            let completedPartialGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: completedPartialGate)
            let partialMedia = try beginSegmentDelivery(
                on: completedPartialGate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 400_000,
                    coveredStartFrame: 0,
                    coveredEndFrame: 400_000
                )
            )
            try completedPartialGate.completeDelivery(partialMedia)
            XCTAssertEqual(completedPartialGate.activeDeliveryCount, 0)
            XCTAssertFalse(completedPartialGate.writerFinished)

            let writerFinishedUnclaimedGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: writerFinishedUnclaimedGate)
            let completedMedia = try beginSegmentDelivery(
                on: writerFinishedUnclaimedGate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 961_024,
                    coveredStartFrame: 0,
                    coveredEndFrame: 960_000
                )
            )
            try writerFinishedUnclaimedGate.completeDelivery(completedMedia)
            writerFinishedUnclaimedGate.markWriterFinished()
            XCTAssertTrue(writerFinishedUnclaimedGate.isReadyForAssembly)
            XCTAssertEqual(writerFinishedUnclaimedGate.successfulSealClaimCount, 0)

            let rows = [
                ("wrong-nominal", wrongNominalGate),
                ("wrong-tolerance", wrongToleranceGate),
                ("dirty-active", dirtyActiveGate),
                ("dirty-completed-partial", completedPartialGate),
                ("dirty-writer-finished-unclaimed", writerFinishedUnclaimedGate),
            ]
            for (name, gate) in rows {
                let outputURL = directory.appendingPathComponent("\(name).mp4")
                let timeoutProbe = TimeoutWaiterInvocationProbe()
                let recorder = EarlyWriterActivityRecorder()
                do {
                    _ = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(30),
                        timeoutWaiter: { _ in timeoutProbe.recordInvocation() },
                        segmentAssemblyGate: gate,
                        lifecycleHook: { event in await recorder.handle(event) }
                    )
                    XCTFail("Dirty gate preflight must fail: \(name)")
                } catch {
                    XCTAssertEqual(
                        error as? DeterministicFMP4Fixture.GenerationError,
                        .writerFailed,
                        name
                    )
                }
                let activities = await recorder.activities()
                XCTAssertEqual(timeoutProbe.invocationCount(), 0, name)
                XCTAssertEqual(activities, [], name)
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: outputURL.path),
                    name
                )
                XCTAssertEqual(try recursiveRelativeContents(in: directory), [], name)
            }
        }
    }

    func testInjectedGateLeaseRejectsConcurrentGenerationBeforeWriterActivity()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let firstOutput = directory.appendingPathComponent("lease-first.mp4")
            let secondOutput = directory.appendingPathComponent("lease-second.mp4")
            let assemblyGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let firstWriterStarted = expectation(description: "leased writer started")
            let firstGenerationCompletedOnMissingStart = expectation(
                description: "missing-lease generation drained"
            )
            let firstGenerationCompletedAfterCancel = expectation(
                description: "leased generation completed after cancellation"
            )
            let firstCompletionProbe = GenerationCompletionProbe()
            let holder = FixtureWriterLifecycleGate(
                writerDidStart: firstWriterStarted,
                holdWriter: true
            )
            let firstGeneration = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: firstOutput,
                        timeout: .seconds(60),
                        segmentAssemblyGate: assemblyGate,
                        lifecycleHook: { event in await holder.handle(event) }
                    )
                    await firstCompletionProbe.markComplete()
                    firstGenerationCompletedOnMissingStart.fulfill()
                    firstGenerationCompletedAfterCancel.fulfill()
                    return generated
                } catch {
                    await firstCompletionProbe.markComplete()
                    firstGenerationCompletedOnMissingStart.fulfill()
                    firstGenerationCompletedAfterCancel.fulfill()
                    throw error
                }
            }

            await fulfillment(of: [firstWriterStarted], timeout: 2)
            let writerStartSeen = await holder.writerDidStartWasObserved()
            guard writerStartSeen else {
                firstGeneration.cancel()
                await holder.releaseWriter()
                await fulfillment(
                    of: [
                        firstGenerationCompletedOnMissingStart,
                        firstGenerationCompletedAfterCancel,
                    ],
                    timeout: 2
                )
                _ = await firstGeneration.result
                XCTFail("First generation did not acquire the gate lease")
                return
            }
            XCTAssertEqual(assemblyGate.generationLeaseAcquisitionCount, 1)
            XCTAssertTrue(assemblyGate.hasActiveGenerationLease)

            let timeoutProbe = TimeoutWaiterInvocationProbe()
            let secondRecorder = EarlyWriterActivityRecorder()
            do {
                _ = try await DeterministicFMP4Fixture.generate(
                    configuration: .twentySeconds,
                    outputURL: secondOutput,
                    timeout: .seconds(30),
                    timeoutWaiter: { _ in timeoutProbe.recordInvocation() },
                    segmentAssemblyGate: assemblyGate,
                    lifecycleHook: { event in await secondRecorder.handle(event) }
                )
                XCTFail("A leased gate must reject concurrent generation")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .writerFailed
                )
            }
            let secondActivities = await secondRecorder.activities()
            XCTAssertEqual(timeoutProbe.invocationCount(), 0)
            XCTAssertEqual(secondActivities, [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: secondOutput.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstOutput.path))

            firstGeneration.cancel()
            await holder.releaseWriter()
            await fulfillment(
                of: [
                    firstGenerationCompletedOnMissingStart,
                    firstGenerationCompletedAfterCancel,
                ],
                timeout: 2
            )
            let firstDrained = await firstCompletionProbe.isComplete()
            guard firstDrained else {
                firstGeneration.cancel()
                await holder.releaseWriter()
                _ = await firstGeneration.result
                XCTFail("Cancelled lease holder did not drain")
                return
            }
            do {
                _ = try await firstGeneration.value
                XCTFail("Cancelled lease holder must not publish")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .cancelled
                )
            }
            let firstOutcomes = await holder.terminalOutcomes()
            XCTAssertEqual(firstOutcomes, [.cancelled])
            XCTAssertFalse(assemblyGate.hasActiveGenerationLease)
            XCTAssertEqual(assemblyGate.generationLeaseAcquisitionCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstOutput.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: secondOutput.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testSegmentAssemblyGateGenerationLeaseAcquisitionIsAtomic() async throws {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        let barrier = TwoPartyStickyBarrier()
        let first = Task {
            await barrier.arriveAndWait()
            do {
                return DirectGenerationLeaseAttempt.acquired(
                    try gate.acquireGenerationLease()
                )
            } catch let error as DeterministicFMP4Fixture.SegmentAssemblyError {
                return .rejected(error)
            } catch {
                return .unexpected(String(describing: error))
            }
        }
        let second = Task {
            await barrier.arriveAndWait()
            do {
                return DirectGenerationLeaseAttempt.acquired(
                    try gate.acquireGenerationLease()
                )
            } catch let error as DeterministicFMP4Fixture.SegmentAssemblyError {
                return .rejected(error)
            } catch {
                return .unexpected(String(describing: error))
            }
        }

        let attempts: [DirectGenerationLeaseAttempt] = [
            await first.value,
            await second.value,
        ]
        let acquiredTokens: [DeterministicFMP4Fixture.GenerationLeaseToken] =
            attempts.compactMap { attempt in
            guard case let .acquired(token) = attempt else { return nil }
            return token
        }
        let rejectedErrors: [DeterministicFMP4Fixture.SegmentAssemblyError] =
            attempts.compactMap { attempt in
            guard case let .rejected(error) = attempt else { return nil }
            return error
        }
        let unexpected: [String] = attempts.compactMap { attempt in
            guard case let .unexpected(description) = attempt else { return nil }
            return description
        }
        XCTAssertEqual(acquiredTokens.count, 1)
        XCTAssertEqual(rejectedErrors, [.generationLeaseUnavailable])
        XCTAssertTrue(unexpected.isEmpty)
        XCTAssertEqual(gate.generationLeaseAcquisitionCount, 1)
        XCTAssertTrue(gate.hasActiveGenerationLease)

        let token = try XCTUnwrap(acquiredTokens.first)
        try gate.releaseGenerationLease(token)
        XCTAssertFalse(gate.hasActiveGenerationLease)
        XCTAssertEqual(gate.generationLeaseAcquisitionCount, 1)
    }

    func testSegmentAssemblyGateWaitsForHeldFinalDeliveryAfterWriterFinish()
        throws
    {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        try completeInitializationDelivery(on: gate)
        let finalDelivery = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: 961_024,
                coveredStartFrame: 0,
                coveredEndFrame: 960_000
            )
        )

        gate.markWriterFinished()

        XCTAssertEqual(gate.activeDeliveryCount, 1)
        XCTAssertFalse(gate.isReadyForAssembly)
        try gate.completeDelivery(finalDelivery)
        XCTAssertEqual(gate.activeDeliveryCount, 0)
        XCTAssertTrue(gate.isReadyForAssembly)
    }

    func testSegmentAssemblyGateUsesReportedCoverageAfterWriterFinish() throws {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        try completeInitializationDelivery(on: gate)
        let incomplete = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: 900_000,
                coveredStartFrame: 0,
                coveredEndFrame: 900_000
            )
        )
        try gate.completeDelivery(incomplete)
        gate.markWriterFinished()

        XCTAssertEqual(gate.activeDeliveryCount, 0)
        XCTAssertFalse(gate.isReadyForAssembly)

        let final = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 2,
                rawStartFrame: 900_000,
                rawEndFrame: 961_024,
                coveredStartFrame: 900_000,
                coveredEndFrame: 960_000
            )
        )
        XCTAssertFalse(gate.isReadyForAssembly)
        try gate.completeDelivery(final)
        XCTAssertTrue(gate.isReadyForAssembly)
    }

    func testSegmentAssemblyGateProjectsPrimedRawTimelineAndAllowsPacketTail()
        throws
    {
        let targetEndFrame: Int64 = 960_000
        let presentationMediaStartFrame: Int64 = 2_112
        for trailingPadding in [Int64(0), Int64(1_024)] {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            XCTAssertEqual(
                gate.presentationMediaStartFrame,
                presentationMediaStartFrame
            )
            let observation = makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: presentationMediaStartFrame
                    + targetEndFrame
                    + trailingPadding,
                coveredStartFrame: 0,
                coveredEndFrame: targetEndFrame,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let delivery = try beginSegmentDelivery(
                on: gate,
                observation: observation
            )
            try gate.completeDelivery(delivery)
            gate.markWriterFinished()

            XCTAssertTrue(gate.isReadyForAssembly)
            let snapshot = try gate.claimAssembly()
            XCTAssertEqual(
                snapshot.orderedEntries.last?.observation,
                observation
            )
            XCTAssertEqual(
                snapshot.contiguousCoveredPresentationEndFrame,
                targetEndFrame
            )
        }
    }

    func testSegmentAssemblyGateRejectsProjectionErrorHiddenByRawOverlap()
        throws
    {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 100,
            nominalFragmentFrameCount: 100,
            packetFrameTolerance: 10
        )
        try completeInitializationDelivery(
            on: gate,
            presentationMediaStartFrame: 10
        )
        let exactSuffix = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 59,
                rawEndFrame: 110,
                coveredStartFrame: 49,
                coveredEndFrame: 100,
                presentationMediaStartFrame: 10
            )
        )
        XCTAssertEqual(gate.activeDeliveryCount, 1)

        XCTAssertThrowsError(
            try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: 0,
                    rawEndFrame: 60,
                    coveredStartFrame: 0,
                    coveredEndFrame: 49,
                    presentationMediaStartFrame: 10
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .coveredPresentationMappingMismatch
            )
        }
        XCTAssertEqual(gate.activeDeliveryCount, 1)
        XCTAssertTrue(gate.isInvalid)
        XCTAssertTrue(gate.writerCancellationRequested)
        XCTAssertFalse(gate.isReadyForAssembly)
        _ = try? gate.completeDelivery(exactSuffix)
        gate.markWriterFinished()
        XCTAssertThrowsError(try gate.claimAssembly()) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .gateInvalid
            )
        }
        XCTAssertNil(gate.claimedSnapshot)
    }

    func testSegmentAssemblyGateRejectsSeparatePaddingAfterEmbeddedPacketTail()
        throws
    {
        let targetEndFrame: Int64 = 960_000
        let presentationMediaStartFrame: Int64 = 2_112
        let rawPresentationEndFrame = presentationMediaStartFrame
            + targetEndFrame
        for row in [
            (name: "embedded-active", completeEmbeddedTail: false),
            (name: "embedded-completed", completeEmbeddedTail: true),
        ] {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let embeddedTail = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: rawPresentationEndFrame + 448,
                    coveredStartFrame: 0,
                    coveredEndFrame: targetEndFrame,
                    presentationMediaStartFrame: presentationMediaStartFrame
                )
            )
            if row.completeEmbeddedTail {
                try gate.completeDelivery(embeddedTail)
            }
            let activeAtBoundary = row.completeEmbeddedTail ? 0 : 1
            XCTAssertEqual(gate.activeDeliveryCount, activeAtBoundary, row.name)

            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 2,
                        rawStartFrame: rawPresentationEndFrame,
                        rawEndFrame: rawPresentationEndFrame + 256,
                        coveredStartFrame: targetEndFrame,
                        coveredEndFrame: targetEndFrame,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    )
                ),
                row.name
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .duplicateTerminalPadding,
                    row.name
                )
            }
            XCTAssertEqual(gate.activeDeliveryCount, activeAtBoundary, row.name)
            XCTAssertTrue(gate.isInvalid, row.name)
            XCTAssertTrue(gate.writerCancellationRequested, row.name)
            XCTAssertFalse(gate.isReadyForAssembly, row.name)
            if !row.completeEmbeddedTail {
                _ = try? gate.completeDelivery(embeddedTail)
            }
            XCTAssertEqual(gate.activeDeliveryCount, 0, row.name)
            gate.markWriterFinished()
            XCTAssertFalse(gate.isReadyForAssembly, row.name)
            XCTAssertThrowsError(try gate.claimAssembly(), row.name) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .gateInvalid,
                    row.name
                )
            }
            XCTAssertNil(gate.claimedSnapshot, row.name)
        }
    }

    func testSegmentAssemblyGateClaimsSingleTerminalAACPaddingObservation()
        throws
    {
        let targetEndFrame: Int64 = 960_000
        let presentationMediaStartFrame: Int64 = 2_112
        let rawPresentationEndFrame = presentationMediaStartFrame
            + targetEndFrame
        for row in [
            (name: "covered-first", completesPaddingFirst: false),
            (name: "padding-first", completesPaddingFirst: true),
        ] {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let coveredObservation = makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: rawPresentationEndFrame,
                coveredStartFrame: 0,
                coveredEndFrame: targetEndFrame,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let terminalPaddingObservation = makeSegmentObservation(
                kind: .media,
                ordinal: 2,
                rawStartFrame: rawPresentationEndFrame,
                rawEndFrame: rawPresentationEndFrame + 512,
                coveredStartFrame: targetEndFrame,
                coveredEndFrame: targetEndFrame,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let covered = try beginSegmentDelivery(
                on: gate,
                observation: coveredObservation,
                ownedPayload: Data("covered-media".utf8)
            )
            let padding = try beginSegmentDelivery(
                on: gate,
                observation: terminalPaddingObservation,
                ownedPayload: Data("terminal-padding".utf8)
            )

            XCTAssertEqual(gate.activeDeliveryCount, 2, row.name)
            XCTAssertFalse(gate.isReadyForAssembly, row.name)
            if row.completesPaddingFirst {
                try gate.completeDelivery(padding)
                XCTAssertEqual(gate.activeDeliveryCount, 1, row.name)
                XCTAssertFalse(gate.isReadyForAssembly, row.name)
                try gate.completeDelivery(covered)
            } else {
                try gate.completeDelivery(covered)
                XCTAssertEqual(gate.activeDeliveryCount, 1, row.name)
                XCTAssertFalse(gate.isReadyForAssembly, row.name)
                try gate.completeDelivery(padding)
            }
            XCTAssertEqual(gate.activeDeliveryCount, 0, row.name)
            XCTAssertEqual(
                gate.contiguousCoveredPresentationEndFrame,
                targetEndFrame,
                row.name
            )
            XCTAssertFalse(gate.isReadyForAssembly, row.name)

            gate.markWriterFinished()
            XCTAssertTrue(gate.isReadyForAssembly, row.name)
            let snapshot = try gate.claimAssembly()
            XCTAssertEqual(
                snapshot.orderedEntries.map(\.observation),
                [
                    makeSegmentObservation(
                        kind: .initialization,
                        ordinal: 0,
                        rawStartFrame: 0,
                        rawEndFrame: 0,
                        coveredStartFrame: 0,
                        coveredEndFrame: 0,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    ),
                    coveredObservation,
                    terminalPaddingObservation,
                ],
                row.name
            )
            XCTAssertEqual(
                snapshot.orderedEntries.map(\.payload),
                [
                    Data("initialization".utf8),
                    Data("covered-media".utf8),
                    Data("terminal-padding".utf8),
                ],
                row.name
            )
        }
    }

    func testSegmentAssemblyGateRejectsInvalidTerminalAACPaddingVariants()
        throws
    {
        let targetEndFrame: Int64 = 960_000
        let presentationMediaStartFrame: Int64 = 2_112
        let rawPresentationEndFrame = presentationMediaStartFrame
            + targetEndFrame

        func gateWithCoverage(
            through coveredEndFrame: Int64
        ) throws -> DeterministicFMP4Fixture.SegmentAssemblyGate {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let coverage = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: presentationMediaStartFrame + coveredEndFrame,
                    coveredStartFrame: 0,
                    coveredEndFrame: coveredEndFrame,
                    presentationMediaStartFrame: presentationMediaStartFrame
                )
            )
            try gate.completeDelivery(coverage)
            return gate
        }

        func assertFailedClosed(
            _ gate: DeterministicFMP4Fixture.SegmentAssemblyGate,
            _ name: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(gate.isInvalid, name, file: file, line: line)
            XCTAssertTrue(
                gate.writerCancellationRequested,
                name,
                file: file,
                line: line
            )
            XCTAssertEqual(gate.activeDeliveryCount, 0, name, file: file, line: line)
            gate.markWriterFinished()
            XCTAssertFalse(gate.isReadyForAssembly, name, file: file, line: line)
            XCTAssertThrowsError(
                try gate.claimAssembly(),
                name,
                file: file,
                line: line
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .gateInvalid,
                    name,
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(
                gate.successfulSealClaimCount,
                0,
                name,
                file: file,
                line: line
            )
            XCTAssertNil(gate.claimedSnapshot, name, file: file, line: line)
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            XCTAssertThrowsError(
                try completeInitializationDelivery(
                    on: gate,
                    presentationMediaStartFrame: -1
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .invalidPresentationMediaStart
                )
            }
            assertFailedClosed(gate, "negative-presentation-media-start")
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            XCTAssertThrowsError(
                try completeInitializationDelivery(
                    on: gate,
                    presentationMediaStartFrame: Int64.max - targetEndFrame + 1
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .presentationMappingOverflow
                )
            }
            assertFailedClosed(gate, "presentation-origin-target-overflow")
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 1,
                        rawStartFrame: 0,
                        rawEndFrame: presentationMediaStartFrame + 48_000,
                        coveredStartFrame: 0,
                        coveredEndFrame: 48_001,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .coveredPresentationMappingMismatch
                )
            }
            assertFailedClosed(gate, "covered-projection-mismatch")
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 1,
                        rawStartFrame: 0,
                        rawEndFrame: targetEndFrame,
                        coveredStartFrame: 0,
                        coveredEndFrame: targetEndFrame,
                        presentationMediaStartFrame: 0
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .presentationMediaStartMismatch
                )
            }
            assertFailedClosed(gate, "presentation-media-start-mismatch")
        }

        do {
            let gate = try gateWithCoverage(through: targetEndFrame)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 2,
                        rawStartFrame: rawPresentationEndFrame + 1,
                        rawEndFrame: rawPresentationEndFrame + 512,
                        coveredStartFrame: targetEndFrame,
                        coveredEndFrame: targetEndFrame,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .terminalPaddingStartMismatch
                )
            }
            assertFailedClosed(gate, "padding-start-after-target")
        }

        do {
            let gate = try gateWithCoverage(through: targetEndFrame)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 2,
                        rawStartFrame: rawPresentationEndFrame,
                        rawEndFrame: rawPresentationEndFrame + 1_025,
                        coveredStartFrame: targetEndFrame,
                        coveredEndFrame: targetEndFrame,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .rawTailExceedsPacketTolerance
                )
            }
            assertFailedClosed(gate, "terminal-padding-over-packet")
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let completedPrefix = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: presentationMediaStartFrame + 400_000,
                    coveredStartFrame: 0,
                    coveredEndFrame: 400_000,
                    presentationMediaStartFrame: presentationMediaStartFrame
                )
            )
            try gate.completeDelivery(completedPrefix)
            let activeSuffix = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: presentationMediaStartFrame + 400_000,
                    rawEndFrame: presentationMediaStartFrame + 900_000,
                    coveredStartFrame: 400_000,
                    coveredEndFrame: 900_000,
                    presentationMediaStartFrame: presentationMediaStartFrame
                )
            )
            XCTAssertEqual(gate.activeDeliveryCount, 1)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 3,
                        rawStartFrame: rawPresentationEndFrame,
                        rawEndFrame: rawPresentationEndFrame + 512,
                        coveredStartFrame: targetEndFrame,
                        coveredEndFrame: targetEndFrame,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .terminalPaddingBeforeCompleteCoverage
                )
            }
            XCTAssertEqual(gate.activeDeliveryCount, 1)
            XCTAssertTrue(gate.isInvalid)
            XCTAssertTrue(gate.writerCancellationRequested)
            XCTAssertFalse(gate.isReadyForAssembly)
            _ = try? gate.completeDelivery(activeSuffix)
            assertFailedClosed(gate, "padding-before-complete-coverage")
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(
                on: gate,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
            let completedPrefix = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: presentationMediaStartFrame + 400_000,
                    coveredStartFrame: 0,
                    coveredEndFrame: 400_000,
                    presentationMediaStartFrame: presentationMediaStartFrame
                )
            )
            try gate.completeDelivery(completedPrefix)
            let activeSuffixAfterGap = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: presentationMediaStartFrame + 500_000,
                    rawEndFrame: rawPresentationEndFrame,
                    coveredStartFrame: 500_000,
                    coveredEndFrame: targetEndFrame,
                    presentationMediaStartFrame: presentationMediaStartFrame
                )
            )
            XCTAssertEqual(gate.activeDeliveryCount, 1)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 3,
                        rawStartFrame: rawPresentationEndFrame,
                        rawEndFrame: rawPresentationEndFrame + 512,
                        coveredStartFrame: targetEndFrame,
                        coveredEndFrame: targetEndFrame,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .terminalPaddingBeforeCompleteCoverage
                )
            }
            XCTAssertEqual(gate.activeDeliveryCount, 1)
            XCTAssertTrue(gate.isInvalid)
            XCTAssertTrue(gate.writerCancellationRequested)
            XCTAssertFalse(gate.isReadyForAssembly)
            _ = try? gate.completeDelivery(activeSuffixAfterGap)
            assertFailedClosed(
                gate,
                "padding-after-noncontiguous-reserved-coverage"
            )
        }

        do {
            let gate = try gateWithCoverage(through: targetEndFrame)
            let firstPadding = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: rawPresentationEndFrame,
                    rawEndFrame: rawPresentationEndFrame + 512,
                    coveredStartFrame: targetEndFrame,
                    coveredEndFrame: targetEndFrame,
                    presentationMediaStartFrame: presentationMediaStartFrame
                )
            )
            XCTAssertEqual(gate.activeDeliveryCount, 1)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 3,
                        rawStartFrame: rawPresentationEndFrame,
                        rawEndFrame: rawPresentationEndFrame + 256,
                        coveredStartFrame: targetEndFrame,
                        coveredEndFrame: targetEndFrame,
                        presentationMediaStartFrame: presentationMediaStartFrame
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .duplicateTerminalPadding
                )
            }
            XCTAssertEqual(gate.activeDeliveryCount, 1)
            XCTAssertTrue(gate.isInvalid)
            XCTAssertTrue(gate.writerCancellationRequested)
            XCTAssertFalse(gate.isReadyForAssembly)
            _ = try? gate.completeDelivery(firstPadding)
            assertFailedClosed(gate, "duplicate-terminal-padding")
        }
    }

    func testSegmentAssemblyGateRequiresContiguousCoverageBeforeReadiness() throws {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        try completeInitializationDelivery(on: gate)
        let prefix = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: 400_000,
                coveredStartFrame: 0,
                coveredEndFrame: 400_000
            ),
            ownedPayload: Data("prefix".utf8)
        )
        let gap = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 2,
                rawStartFrame: 400_000,
                rawEndFrame: 500_000,
                coveredStartFrame: 400_000,
                coveredEndFrame: 500_000
            ),
            ownedPayload: Data("gap".utf8)
        )
        let suffix = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 3,
                rawStartFrame: 500_000,
                rawEndFrame: 961_024,
                coveredStartFrame: 500_000,
                coveredEndFrame: 960_000
            ),
            ownedPayload: Data("suffix".utf8)
        )
        gate.markWriterFinished()
        try gate.completeDelivery(prefix)
        try gate.completeDelivery(suffix)

        XCTAssertEqual(gate.activeDeliveryCount, 1)
        XCTAssertEqual(gate.contiguousCoveredPresentationEndFrame, 400_000)
        XCTAssertFalse(gate.isReadyForAssembly)

        try gate.completeDelivery(gap)
        XCTAssertEqual(gate.activeDeliveryCount, 0)
        XCTAssertEqual(gate.contiguousCoveredPresentationEndFrame, 960_000)
        XCTAssertTrue(gate.isReadyForAssembly)
        let snapshot = try gate.claimAssembly()
        XCTAssertEqual(
            snapshot.orderedEntries.map(\.observation.ordinal),
            [0, 1, 2, 3]
        )
        XCTAssertEqual(
            snapshot.orderedEntries.dropFirst().map(\.payload),
            [Data("prefix".utf8), Data("gap".utf8), Data("suffix".utf8)]
        )
    }

    func testSegmentAssemblyGateRejectsCoverageOverlapAndRegression() throws {
        for row in [
            (
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: 350_000,
                    rawEndFrame: 500_000,
                    coveredStartFrame: 350_000,
                    coveredEndFrame: 500_000
                ),
                expected: DeterministicFMP4Fixture.SegmentAssemblyError
                    .coveredPresentationOverlap
            ),
            (
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: 100_000,
                    rawEndFrame: 200_000,
                    coveredStartFrame: 100_000,
                    coveredEndFrame: 200_000
                ),
                expected: DeterministicFMP4Fixture.SegmentAssemblyError
                    .coveredPresentationRegression
            ),
        ] {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: gate)
            let prefix = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 400_000,
                    coveredStartFrame: 0,
                    coveredEndFrame: 400_000
                )
            )
            try gate.completeDelivery(prefix)

            XCTAssertThrowsError(
                try beginSegmentDelivery(on: gate, observation: row.observation)
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    row.expected
                )
            }
            XCTAssertTrue(gate.writerCancellationRequested)
            XCTAssertFalse(gate.isReadyForAssembly)
        }
    }

    func testSegmentAssemblyGateDrainsTwoActiveDeliveriesAndClaimsOnce() throws {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        try completeInitializationDelivery(on: gate)
        let first = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: 480_000,
                coveredStartFrame: 0,
                coveredEndFrame: 480_000
            )
        )
        let second = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 2,
                rawStartFrame: 480_000,
                rawEndFrame: 961_024,
                coveredStartFrame: 480_000,
                coveredEndFrame: 960_000
            )
        )
        gate.markWriterFinished()
        XCTAssertEqual(gate.activeDeliveryCount, 2)
        XCTAssertFalse(gate.isReadyForAssembly)

        try gate.completeDelivery(first)
        XCTAssertEqual(gate.activeDeliveryCount, 1)
        XCTAssertFalse(gate.isReadyForAssembly)
        XCTAssertThrowsError(try gate.completeDelivery(first)) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .deliveryAlreadyCompleted
            )
        }
        XCTAssertEqual(gate.activeDeliveryCount, 1)
        XCTAssertFalse(gate.isReadyForAssembly)

        let foreignGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        let foreignToken = try beginSegmentDelivery(
            on: foreignGate,
            observation: makeSegmentObservation(
                kind: .initialization,
                ordinal: 0,
                rawStartFrame: 0,
                rawEndFrame: 0,
                coveredStartFrame: 0,
                coveredEndFrame: 0
            )
        )
        XCTAssertThrowsError(try gate.completeDelivery(foreignToken)) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .staleDeliveryToken
            )
        }
        XCTAssertEqual(gate.activeDeliveryCount, 1)
        XCTAssertFalse(gate.isReadyForAssembly)

        try gate.completeDelivery(second)
        XCTAssertEqual(gate.activeDeliveryCount, 0)
        XCTAssertTrue(gate.isReadyForAssembly)

        let snapshot = try gate.claimAssembly()
        XCTAssertTrue(snapshot.writerFinished)
        XCTAssertEqual(snapshot.contiguousCoveredPresentationEndFrame, 960_000)
        XCTAssertEqual(
            snapshot.orderedEntries.map(\.observation.ordinal),
            [0, 1, 2]
        )
        XCTAssertEqual(
            snapshot.orderedEntries.map(\.payload),
            [
                Data("initialization".utf8),
                Data("segment-1".utf8),
                Data("segment-2".utf8),
            ]
        )
        XCTAssertEqual(gate.successfulSealClaimCount, 1)
        XCTAssertThrowsError(try gate.claimAssembly()) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .assemblyAlreadyClaimed
            )
        }
        XCTAssertThrowsError(
            try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 3,
                    rawStartFrame: 959_000,
                    rawEndFrame: 961_024,
                    coveredStartFrame: 959_000,
                    coveredEndFrame: 960_000
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .deliveryAfterAssemblyClaim
            )
        }
        XCTAssertTrue(gate.writerCancellationRequested)
        XCTAssertFalse(gate.isReadyForAssembly)
        XCTAssertThrowsError(try gate.claimAssembly()) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .assemblyAlreadyClaimed
            )
        }
        XCTAssertEqual(gate.activeDeliveryCount, 0)
        XCTAssertEqual(gate.successfulSealClaimCount, 1)
    }

    func testSegmentAssemblyGateRejectsInvalidRawAndCoveredRanges() throws {
        let rows: [(
            observation: DeterministicFMP4Fixture.SegmentCallbackObservation,
            expected: DeterministicFMP4Fixture.SegmentAssemblyError
        )] = [
            (
                makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 961_025,
                    coveredStartFrame: 0,
                    coveredEndFrame: 960_000
                ),
                .rawTailExceedsPacketTolerance
            ),
            (
                makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 899_999,
                    coveredStartFrame: 0,
                    coveredEndFrame: 900_000
                ),
                .coveredPresentationOutsideRawRange
            ),
            (
                makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 1,
                    rawEndFrame: 900_000,
                    coveredStartFrame: 0,
                    coveredEndFrame: 900_000
                ),
                .coveredPresentationOutsideRawRange
            ),
            (
                makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 961_024,
                    coveredStartFrame: 0,
                    coveredEndFrame: 960_001
                ),
                .coveredPresentationOutsideTarget
            ),
            (
                makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 500_000,
                    rawEndFrame: 500_512,
                    coveredStartFrame: 500_000,
                    coveredEndFrame: 500_000
                ),
                .nonpositiveSegmentRange
            ),
            (
                makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 100,
                    rawEndFrame: 100,
                    coveredStartFrame: 100,
                    coveredEndFrame: 100
                ),
                .nonpositiveSegmentRange
            ),
        ]

        for row in rows {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: gate)
            XCTAssertThrowsError(
                try beginSegmentDelivery(on: gate, observation: row.observation)
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    row.expected
                )
            }
            XCTAssertTrue(gate.writerCancellationRequested)
            XCTAssertFalse(gate.isReadyForAssembly)
        }
    }

    func testSegmentAssemblyGateRejectsAuthoritativeAdmissionViolations() throws {
        func assertCancelledAndUnready(
            _ gate: DeterministicFMP4Fixture.SegmentAssemblyGate
        ) {
            XCTAssertTrue(gate.writerCancellationRequested)
            XCTAssertFalse(gate.isReadyForAssembly)
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .initialization,
                        ordinal: 0,
                        rawStartFrame: 0,
                        rawEndFrame: 0,
                        coveredStartFrame: 0,
                        coveredEndFrame: 0
                    ),
                    ownedPayload: Data()
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .emptyPayload
                )
            }
            assertCancelledAndUnready(gate)
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 1,
                        rawStartFrame: 0,
                        rawEndFrame: 480_000,
                        coveredStartFrame: 0,
                        coveredEndFrame: 480_000
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .mediaBeforeInitialization
                )
            }
            assertCancelledAndUnready(gate)
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: gate)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .initialization,
                        ordinal: 0,
                        rawStartFrame: 0,
                        rawEndFrame: 0,
                        coveredStartFrame: 0,
                        coveredEndFrame: 0
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .duplicateInitialization
                )
            }
            assertCancelledAndUnready(gate)
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: gate)
            let firstMedia = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 400_000,
                    coveredStartFrame: 0,
                    coveredEndFrame: 400_000
                )
            )
            try gate.completeDelivery(firstMedia)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: 1,
                        rawStartFrame: 400_000,
                        rawEndFrame: 961_024,
                        coveredStartFrame: 400_000,
                        coveredEndFrame: 960_000
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .duplicateSegmentOrdinal(ordinal: 1)
                )
            }
            assertCancelledAndUnready(gate)
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: gate)
            let firstMedia = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 1,
                    rawStartFrame: 0,
                    rawEndFrame: 961_024,
                    coveredStartFrame: 0,
                    coveredEndFrame: 960_000
                )
            )
            try gate.completeDelivery(firstMedia)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .initialization,
                        ordinal: 2,
                        rawStartFrame: 0,
                        rawEndFrame: 0,
                        coveredStartFrame: 0,
                        coveredEndFrame: 0
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .initializationAfterMedia
                )
            }
            assertCancelledAndUnready(gate)
        }
    }

    func testSegmentAssemblyGateDerivesTwentyAndSixtySecondCountCaps() throws {
        for targetFrame in [Int64(960_000), 2_880_000] {
            let expectedMaximum = Int(
                (targetFrame + 48_000 - 1) / 48_000
            ) + 1

            let successGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            XCTAssertEqual(successGate.maximumMediaSegmentCount, expectedMaximum)
            try completeInitializationDelivery(on: successGate)

            var successTokens: [
                DeterministicFMP4Fixture.SegmentDeliveryToken
            ] = []
            for index in 0..<expectedMaximum {
                let lower = targetFrame * Int64(index) / Int64(expectedMaximum)
                let upper = targetFrame * Int64(index + 1) / Int64(expectedMaximum)
                let token = try beginSegmentDelivery(
                    on: successGate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: index + 1,
                        rawStartFrame: lower,
                        rawEndFrame: upper,
                        coveredStartFrame: lower,
                        coveredEndFrame: upper
                    )
                )
                successTokens.append(token)
            }
            XCTAssertEqual(successGate.activeDeliveryCount, expectedMaximum)
            successGate.markWriterFinished()
            for token in successTokens.reversed() {
                try successGate.completeDelivery(token)
            }
            XCTAssertEqual(successGate.activeDeliveryCount, 0)
            XCTAssertTrue(successGate.isReadyForAssembly)
            let successSnapshot = try successGate.claimAssembly()
            XCTAssertEqual(
                successSnapshot.orderedEntries.map(\.observation.ordinal),
                Array(0...expectedMaximum)
            )
            XCTAssertEqual(successGate.successfulSealClaimCount, 1)

            let failureGate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: targetFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            try completeInitializationDelivery(on: failureGate)
            var failureTokens: [
                DeterministicFMP4Fixture.SegmentDeliveryToken
            ] = []
            for index in 0..<expectedMaximum {
                let lower = targetFrame * Int64(index) / Int64(expectedMaximum)
                let upper = targetFrame * Int64(index + 1) / Int64(expectedMaximum)
                failureTokens.append(
                    try beginSegmentDelivery(
                        on: failureGate,
                        observation: makeSegmentObservation(
                            kind: .media,
                            ordinal: index + 1,
                            rawStartFrame: lower,
                            rawEndFrame: upper,
                            coveredStartFrame: lower,
                            coveredEndFrame: upper
                        )
                    )
                )
            }
            let activeBeforeOverflow = failureGate.activeDeliveryCount
            let retainedBeforeOverflow = failureGate.retainedPayloadByteCount
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: failureGate,
                    observation: makeSegmentObservation(
                        kind: .media,
                        ordinal: expectedMaximum + 1,
                        rawStartFrame: targetFrame - 1,
                        rawEndFrame: targetFrame + 1_024,
                        coveredStartFrame: targetFrame - 1,
                        coveredEndFrame: targetFrame
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .mediaSegmentCountExceeded(maximum: expectedMaximum)
                )
            }
            XCTAssertEqual(failureGate.activeDeliveryCount, activeBeforeOverflow)
            XCTAssertEqual(failureGate.retainedPayloadByteCount, retainedBeforeOverflow)
            XCTAssertTrue(failureGate.writerCancellationRequested)
            XCTAssertTrue(failureGate.isInvalid)
            XCTAssertFalse(failureGate.isReadyForAssembly)

            for token in failureTokens.reversed() {
                _ = try? failureGate.completeDelivery(token)
            }
            failureGate.markWriterFinished()
            XCTAssertFalse(failureGate.isReadyForAssembly)
            XCTAssertThrowsError(try failureGate.claimAssembly()) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .gateInvalid
                )
            }
            XCTAssertEqual(failureGate.successfulSealClaimCount, 0)
        }
    }

    func testSegmentAssemblyGateEnforcesFourMiBPayloadLimitBeforeRetention() throws {
        let expectedLimit = 4 * 1_024 * 1_024
        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            XCTAssertEqual(gate.maximumCollectedByteCount, expectedLimit)
            let exactLimitPayload = Data(repeating: 0xA5, count: expectedLimit)
            let token = try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .initialization,
                    ordinal: 0,
                    rawStartFrame: 0,
                    rawEndFrame: 0,
                    coveredStartFrame: 0,
                    coveredEndFrame: 0
                ),
                ownedPayload: exactLimitPayload
            )
            try gate.completeDelivery(token)
            XCTAssertFalse(gate.writerCancellationRequested)
        }

        do {
            let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
                targetPresentationEndFrame: 960_000,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            )
            let oversizedPayload = Data(repeating: 0x5A, count: expectedLimit + 1)
            XCTAssertThrowsError(
                try beginSegmentDelivery(
                    on: gate,
                    observation: makeSegmentObservation(
                        kind: .initialization,
                        ordinal: 0,
                        rawStartFrame: 0,
                        rawEndFrame: 0,
                        coveredStartFrame: 0,
                        coveredEndFrame: 0
                    ),
                    ownedPayload: oversizedPayload
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                    .payloadByteLimitExceeded(maximum: expectedLimit)
                )
            }
            XCTAssertEqual(gate.activeDeliveryCount, 0)
            XCTAssertTrue(gate.writerCancellationRequested)
            XCTAssertFalse(gate.isReadyForAssembly)
        }
    }

    func testSegmentAssemblyGateEnforcesCumulativeFourMiBPayloadLimit() throws {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        let twoMiB = 2 * 1_024 * 1_024
        let initialization = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .initialization,
                ordinal: 0,
                rawStartFrame: 0,
                rawEndFrame: 0,
                coveredStartFrame: 0,
                coveredEndFrame: 0
            ),
            ownedPayload: Data(repeating: 0x11, count: twoMiB)
        )
        try gate.completeDelivery(initialization)
        XCTAssertEqual(gate.retainedPayloadByteCount, twoMiB)

        let exactMedia = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: 961_024,
                coveredStartFrame: 0,
                coveredEndFrame: 960_000
            ),
            ownedPayload: Data(repeating: 0x22, count: twoMiB)
        )
        try gate.completeDelivery(exactMedia)
        XCTAssertEqual(gate.retainedPayloadByteCount, 4 * 1_024 * 1_024)

        XCTAssertThrowsError(
            try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: 959_999,
                    rawEndFrame: 961_024,
                    coveredStartFrame: 959_999,
                    coveredEndFrame: 960_000
                ),
                ownedPayload: Data([0x33])
            )
        ) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .payloadByteLimitExceeded(maximum: 4 * 1_024 * 1_024)
            )
        }
        XCTAssertLessThanOrEqual(
            gate.retainedPayloadByteCount,
            gate.maximumCollectedByteCount
        )
        XCTAssertLessThanOrEqual(
            gate.claimedPayloadByteCount,
            gate.maximumCollectedByteCount
        )
        XCTAssertEqual(gate.claimedPayloadByteCount, 0)
        XCTAssertEqual(gate.activeDeliveryCount, 0)
        XCTAssertTrue(gate.writerCancellationRequested)
        XCTAssertFalse(gate.isReadyForAssembly)
    }

    func testSegmentAssemblyGateReservesPayloadBytesForActiveDeliveries() throws {
        let gate = DeterministicFMP4Fixture.SegmentAssemblyGate(
            targetPresentationEndFrame: 960_000,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        let initialization = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .initialization,
                ordinal: 0,
                rawStartFrame: 0,
                rawEndFrame: 0,
                coveredStartFrame: 0,
                coveredEndFrame: 0
            ),
            ownedPayload: Data([0x01])
        )
        try gate.completeDelivery(initialization)

        let threeMiB = 3 * 1_024 * 1_024
        let activeMedia = try beginSegmentDelivery(
            on: gate,
            observation: makeSegmentObservation(
                kind: .media,
                ordinal: 1,
                rawStartFrame: 0,
                rawEndFrame: 480_000,
                coveredStartFrame: 0,
                coveredEndFrame: 480_000
            ),
            ownedPayload: Data(repeating: 0x44, count: threeMiB)
        )
        let activeBeforeOverflow = gate.activeDeliveryCount
        let retainedBeforeOverflow = gate.retainedPayloadByteCount
        XCTAssertEqual(activeBeforeOverflow, 1)

        XCTAssertThrowsError(
            try beginSegmentDelivery(
                on: gate,
                observation: makeSegmentObservation(
                    kind: .media,
                    ordinal: 2,
                    rawStartFrame: 480_000,
                    rawEndFrame: 961_024,
                    coveredStartFrame: 480_000,
                    coveredEndFrame: 960_000
                ),
                ownedPayload: Data(repeating: 0x55, count: threeMiB)
            )
        ) { error in
            XCTAssertEqual(
                error as? DeterministicFMP4Fixture.SegmentAssemblyError,
                .payloadByteLimitExceeded(maximum: 4 * 1_024 * 1_024)
            )
        }
        XCTAssertEqual(gate.activeDeliveryCount, activeBeforeOverflow)
        XCTAssertEqual(gate.retainedPayloadByteCount, retainedBeforeOverflow)
        XCTAssertTrue(gate.writerCancellationRequested)
        XCTAssertFalse(gate.isReadyForAssembly)
        _ = try? gate.completeDelivery(activeMedia)
    }

    func testSixtySecondFixtureExceedsCanonicalTenSecondRangeBudgetWithoutToneAssumption()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-60.mp4")
            let generated = try await DeterministicFMP4Fixture.generate(
                configuration: .sixtySeconds,
                outputURL: outputURL,
                timeout: .seconds(60)
            )
            let inspection = try await IndependentFixtureInspector.inspect(
                url: outputURL,
                expectedPresentationDurationSeconds: 60,
                expectedToneRegions: []
            )
            let canonicalBudget = RangeDemandController(
                bitrate: Int(nominalBitrate),
                initializationRange: inspection.initializationRange,
                indexRange: inspection.indexRange,
                authorizedKillSwitchEpoch: 0
            ).activeTrackByteBudget(
                playedSeconds: 10,
                network: .wifi(expensive: false, constrained: false)
            )

            XCTAssertGreaterThan(inspection.contentLength, canonicalBudget)
            assertIndependentFixture(
                inspection,
                expectedDuration: 60,
                expectedToneRegions: []
            )
            assertManifest(
                generated.manifest,
                matches: inspection,
                expectedDuration: 60,
                expectedToneRegions: nil
            )
            XCTAssertFalse(generated.manifest.toneScheduleSHA256.isEmpty)
        }
    }

    func testCancellationAfterWriterStartWaitsForTerminalCleanupAndLeavesNoPartial()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-cancel.mp4")
            let writerDidStart = expectation(description: "writer did start")
            let gate = FixtureWriterLifecycleGate(
                writerDidStart: writerDidStart,
                holdWriter: true
            )
            let generation = Task {
                try await DeterministicFMP4Fixture.generate(
                    configuration: .twentySeconds,
                    outputURL: outputURL,
                    timeout: .seconds(10),
                    lifecycleHook: { event in await gate.handle(event) }
                )
            }

            await fulfillment(of: [writerDidStart], timeout: 2)
            generation.cancel()
            await gate.releaseWriter()

            do {
                _ = try await generation.value
                XCTFail("Cancellation must be terminal")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .cancelled
                )
            }
            let terminalOutcomes = await gate.terminalOutcomes()
            XCTAssertEqual(terminalOutcomes, [.cancelled])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testInjectedDeadlineWaitsForHeldTimedOutTerminalAndCleansActiveWriter()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-active-timeout.mp4")
            let writerDidStart = expectation(description: "active writer did start")
            let timeoutRequested = expectation(description: "timeout cancellation requested")
            let terminalEntered = expectation(description: "timed-out terminal hook entered")
            let timeoutSignal = InjectedFixtureTimeoutSignal()
            let completionProbe = GenerationCompletionProbe()
            let gate = FixtureWriterLifecycleGate(
                writerDidStart: writerDidStart,
                holdWriter: true,
                timeoutCancellationRequested: timeoutRequested,
                terminalEntered: terminalEntered,
                holdTimedOutTerminal: true
            )
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(30),
                        timeoutWaiter: { _ in await timeoutSignal.wait() },
                        lifecycleHook: { event in await gate.handle(event) }
                    )
                    await completionProbe.markComplete()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    throw error
                }
            }

            await fulfillment(of: [writerDidStart], timeout: 2)
            await timeoutSignal.trigger()
            await fulfillment(of: [timeoutRequested], timeout: 2)
            await gate.releaseWriter()
            await fulfillment(of: [terminalEntered], timeout: 2)
            let completedWhileTerminalHeld = await completionProbe.isComplete()
            let heldTerminalOutcomes = await gate.terminalOutcomes()
            XCTAssertFalse(completedWhileTerminalHeld)
            XCTAssertEqual(heldTerminalOutcomes, [.timedOut])

            await gate.releaseTimedOutTerminal()
            do {
                _ = try await generation.value
                XCTFail("Injected deadline must fail the active writer")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .timedOut
                )
            }
            let completedAfterTerminalRelease = await completionProbe.isComplete()
            let finalTerminalOutcomes = await gate.terminalOutcomes()
            XCTAssertTrue(completedAfterTerminalRelease)
            XCTAssertEqual(finalTerminalOutcomes, [.timedOut])
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testParentCancellationWinsWhileCommittedOutputWaitsForTerminalClaim()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-commit-cancel.mp4")
            let outputCommitted = expectation(description: "output committed before terminal")
            let gate = OutputCommitLifecycleGate(outputCommitted: outputCommitted)
            let generation = Task {
                try await DeterministicFMP4Fixture.generate(
                    configuration: .twentySeconds,
                    outputURL: outputURL,
                    timeout: .seconds(30),
                    lifecycleHook: { event in await gate.handle(event) }
                )
            }

            await fulfillment(of: [outputCommitted], timeout: 30)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            generation.cancel()
            await gate.releaseCommittedOutput()

            do {
                _ = try await generation.value
                XCTFail("Parent cancellation must beat completed terminal claim")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .cancelled
                )
            }
            let outcomes = await gate.terminalOutcomes()
            XCTAssertEqual(outcomes, [.cancelled])
            XCTAssertFalse(outcomes.contains(.completed))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testInjectedTimeoutWinsWhileCommittedOutputWaitsForTerminalClaim()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-commit-timeout.mp4")
            let outputCommitted = expectation(description: "output committed before timeout")
            let timeoutRequested = expectation(description: "commit timeout requested")
            let timeoutSignal = InjectedFixtureTimeoutSignal()
            let gate = OutputCommitLifecycleGate(
                outputCommitted: outputCommitted,
                timeoutCancellationRequested: timeoutRequested
            )
            let generation = Task {
                try await DeterministicFMP4Fixture.generate(
                    configuration: .twentySeconds,
                    outputURL: outputURL,
                    timeout: .seconds(30),
                    timeoutWaiter: { _ in await timeoutSignal.wait() },
                    lifecycleHook: { event in await gate.handle(event) }
                )
            }

            await fulfillment(of: [outputCommitted], timeout: 30)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            await timeoutSignal.trigger()
            await fulfillment(of: [timeoutRequested], timeout: 2)
            await gate.releaseCommittedOutput()

            do {
                _ = try await generation.value
                XCTFail("Injected timeout must beat completed terminal claim")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .timedOut
                )
            }
            let outcomes = await gate.terminalOutcomes()
            XCTAssertEqual(outcomes, [.timedOut])
            XCTAssertFalse(outcomes.contains(.completed))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testSuccessfulGenerationDrainsCancelledNoncooperativeTimeoutWaiter()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-waiter-drain.mp4")
            let waiterStarted = expectation(description: "noncooperative waiter started")
            let waiterCancellationObserved = expectation(
                description: "noncooperative waiter observed cancellation"
            )
            let waiter = StickyNoncooperativeTimeoutWaiter(
                started: waiterStarted,
                cancellationObserved: waiterCancellationObserved
            )
            let completionProbe = GenerationCompletionProbe()
            let recorder = TerminalLifecycleRecorder()
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(30),
                        timeoutWaiter: { _ in await waiter.wait() },
                        lifecycleHook: { event in await recorder.handle(event) }
                    )
                    await completionProbe.markComplete()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    throw error
                }
            }

            await fulfillment(of: [waiterStarted], timeout: 2)
            await fulfillment(of: [waiterCancellationObserved], timeout: 30)
            let completedBeforeWaiterRelease = await completionProbe.isComplete()
            let outcomesBeforeWaiterRelease = await recorder.terminalOutcomes()
            XCTAssertFalse(completedBeforeWaiterRelease)
            XCTAssertTrue(outcomesBeforeWaiterRelease.isEmpty)

            waiter.release()
            let generated = try await generation.value

            let completedAfterWaiterRelease = await completionProbe.isComplete()
            let finalOutcomes = await recorder.terminalOutcomes()
            XCTAssertTrue(completedAfterWaiterRelease)
            XCTAssertEqual(finalOutcomes, [.completed])
            XCTAssertEqual(generated.url.standardizedFileURL, outputURL.standardizedFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(
                try recursiveRelativeContents(in: directory),
                [outputURL.lastPathComponent]
            )
        }
    }

    func testTimeoutCancelsHeldFinishAndIgnoresLateNormalCompletion()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-late-finish.mp4")
            let finishDidStart = expectation(description: "finish writing did start")
            let timeoutRequested = expectation(description: "finish timeout requested")
            let writerCancellationRequested = expectation(
                description: "writer cancellation requested"
            )
            let normalFinishCaptured = expectation(description: "normal finish callback captured")
            let generationCompletedBeforeLate = expectation(
                description: "timed-out finish completed before late callback"
            )
            let generationDrainedAfterLate = expectation(
                description: "timed-out finish drained after late callback"
            )
            let timeoutSignal = InjectedFixtureTimeoutSignal()
            let completionProbe = GenerationCompletionProbe()
            let finishStarter = StickyFinishWritingStarter(
                normalFinishCaptured: normalFinishCaptured
            )
            defer { _ = finishStarter.invokeLateCompletion() }
            let gate = FinishWritingLifecycleGate(
                finishWritingDidStart: finishDidStart,
                timeoutCancellationRequested: timeoutRequested,
                writerCancellationRequested: writerCancellationRequested
            )
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(30),
                        timeoutWaiter: { _ in await timeoutSignal.wait() },
                        finishWritingStarter: { writer, completion in
                            finishStarter.start(writer: writer, completion: completion)
                        },
                        lifecycleHook: { event in await gate.handle(event) }
                    )
                    await completionProbe.markComplete()
                    generationCompletedBeforeLate.fulfill()
                    generationDrainedAfterLate.fulfill()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    generationCompletedBeforeLate.fulfill()
                    generationDrainedAfterLate.fulfill()
                    throw error
                }
            }

            await fulfillment(
                of: [finishDidStart, normalFinishCaptured],
                timeout: 30
            )
            await timeoutSignal.trigger()
            await fulfillment(
                of: [timeoutRequested, writerCancellationRequested],
                timeout: 2
            )
            await fulfillment(of: [generationCompletedBeforeLate], timeout: 2)
            let completedBeforeLateCompletion = await completionProbe.isComplete()
            let outcomesBeforeLateCompletion = await gate.terminalOutcomes()
            XCTAssertTrue(completedBeforeLateCompletion)
            XCTAssertEqual(outcomesBeforeLateCompletion, [.timedOut])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])

            XCTAssertEqual(finishStarter.invokeLateCompletion(), 1)
            await fulfillment(of: [generationDrainedAfterLate], timeout: 2)
            let completedAfterLateCompletion = await completionProbe.isComplete()
            guard completedAfterLateCompletion else {
                XCTFail("Generation remained blocked after late finish release")
                return
            }
            do {
                _ = try await generation.value
                XCTFail("Timeout must abort a held normal finish callback")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .timedOut
                )
            }

            let outcomesAfterLateCompletion = await gate.terminalOutcomes()
            XCTAssertEqual(outcomesAfterLateCompletion, [.timedOut])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testParentCancellationCancelsHeldFinishAndIgnoresLateNormalCompletion()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-cancelled-finish.mp4")
            let finishDidStart = expectation(description: "cancelled finish did start")
            let writerCancellationRequested = expectation(
                description: "cancelled finish requested writer cancellation"
            )
            let normalFinishCaptured = expectation(
                description: "cancelled finish normal callback captured"
            )
            let generationCompletedBeforeLate = expectation(
                description: "cancelled finish completed before late callback"
            )
            let generationDrainedAfterLate = expectation(
                description: "cancelled finish drained after late callback"
            )
            let completionProbe = GenerationCompletionProbe()
            let finishStarter = StickyFinishWritingStarter(
                normalFinishCaptured: normalFinishCaptured
            )
            defer { _ = finishStarter.invokeLateCompletion() }
            let gate = FinishWritingLifecycleGate(
                finishWritingDidStart: finishDidStart,
                writerCancellationRequested: writerCancellationRequested
            )
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(30),
                        finishWritingStarter: { writer, completion in
                            finishStarter.start(writer: writer, completion: completion)
                        },
                        lifecycleHook: { event in await gate.handle(event) }
                    )
                    await completionProbe.markComplete()
                    generationCompletedBeforeLate.fulfill()
                    generationDrainedAfterLate.fulfill()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    generationCompletedBeforeLate.fulfill()
                    generationDrainedAfterLate.fulfill()
                    throw error
                }
            }

            await fulfillment(
                of: [finishDidStart, normalFinishCaptured],
                timeout: 30
            )
            generation.cancel()
            await fulfillment(of: [writerCancellationRequested], timeout: 2)
            await fulfillment(of: [generationCompletedBeforeLate], timeout: 2)
            let completedBeforeLateCompletion = await completionProbe.isComplete()
            let outcomesBeforeLateCompletion = await gate.terminalOutcomes()
            XCTAssertTrue(completedBeforeLateCompletion)
            XCTAssertEqual(outcomesBeforeLateCompletion, [.cancelled])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])

            XCTAssertEqual(finishStarter.invokeLateCompletion(), 1)
            await fulfillment(of: [generationDrainedAfterLate], timeout: 2)
            let completedAfterLateCompletion = await completionProbe.isComplete()
            guard completedAfterLateCompletion else {
                XCTFail("Cancelled generation remained blocked after finish release")
                return
            }
            do {
                _ = try await generation.value
                XCTFail("Parent cancellation must abort a held normal finish callback")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .cancelled
                )
            }
            let outcomesAfterLateCompletion = await gate.terminalOutcomes()
            XCTAssertEqual(outcomesAfterLateCompletion, [.cancelled])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testParentCancellationDrainsHeldNoncooperativeTimeoutWaiter()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-cancelled-waiter.mp4")
            let writerDidStart = expectation(description: "cancelled waiter writer started")
            let waiterStarted = expectation(description: "cancelled waiter started")
            let waiterCancellationObserved = expectation(
                description: "cancelled waiter observed Task cancellation"
            )
            let generationCompleted = expectation(
                description: "cancelled waiter generation completed"
            )
            let prematureCompletion = expectation(
                description: "generation completed before waiter release"
            )
            prematureCompletion.isInverted = true
            let waiter = StickyNoncooperativeTimeoutWaiter(
                started: waiterStarted,
                cancellationObserved: waiterCancellationObserved
            )
            defer { waiter.release() }
            let completionProbe = GenerationCompletionProbe()
            let gate = FixtureWriterLifecycleGate(
                writerDidStart: writerDidStart,
                holdWriter: true
            )
            let generation = Task {
                do {
                    let generated = try await DeterministicFMP4Fixture.generate(
                        configuration: .twentySeconds,
                        outputURL: outputURL,
                        timeout: .seconds(30),
                        timeoutWaiter: { _ in await waiter.wait() },
                        lifecycleHook: { event in await gate.handle(event) }
                    )
                    await completionProbe.markComplete()
                    if !waiter.isReleased() { prematureCompletion.fulfill() }
                    generationCompleted.fulfill()
                    return generated
                } catch {
                    await completionProbe.markComplete()
                    if !waiter.isReleased() { prematureCompletion.fulfill() }
                    generationCompleted.fulfill()
                    throw error
                }
            }

            await fulfillment(of: [waiterStarted, writerDidStart], timeout: 2)
            generation.cancel()
            await gate.releaseWriter()
            await fulfillment(of: [waiterCancellationObserved], timeout: 2)
            await fulfillment(of: [prematureCompletion], timeout: 0.1)
            let completedWhileWaiterHeld = await completionProbe.isComplete()
            XCTAssertFalse(completedWhileWaiterHeld)

            waiter.release()
            await fulfillment(of: [generationCompleted], timeout: 2)
            let completedAfterWaiterRelease = await completionProbe.isComplete()
            guard completedAfterWaiterRelease else {
                XCTFail("Cancelled generation remained blocked after waiter release")
                return
            }
            do {
                _ = try await generation.value
                XCTFail("Parent cancellation must remain terminal after waiter drain")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .cancelled
                )
            }
            let outcomes = await gate.terminalOutcomes()
            XCTAssertEqual(outcomes, [.cancelled])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])
        }
    }

    func testImmediateTimeoutAndInvalidRootReturnOnlyAfterCleanup() async throws {
        try await withUniqueTemporaryDirectory { directory in
            let timeoutURL = directory.appendingPathComponent("fixture-timeout.mp4")
            do {
                _ = try await DeterministicFMP4Fixture.generate(
                    configuration: .twentySeconds,
                    outputURL: timeoutURL,
                    timeout: .zero
                )
                XCTFail("An immediate deadline must fail")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .timedOut
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: timeoutURL.path))
            XCTAssertEqual(try recursiveRelativeContents(in: directory), [])

            let invalidRoot = directory.appendingPathComponent("root-is-a-file")
            let rootSentinel = Data("do-not-replace".utf8)
            try rootSentinel.write(to: invalidRoot)
            let invalidOutput = invalidRoot.appendingPathComponent("fixture.mp4")
            do {
                _ = try await DeterministicFMP4Fixture.generate(
                    configuration: .twentySeconds,
                    outputURL: invalidOutput,
                    timeout: .seconds(5)
                )
                XCTFail("A non-directory root must fail")
            } catch {
                XCTAssertEqual(
                    error as? DeterministicFMP4Fixture.GenerationError,
                    .invalidOutputRoot
                )
            }
            XCTAssertEqual(try Data(contentsOf: invalidRoot), rootSentinel)
            XCTAssertFalse(FileManager.default.fileExists(atPath: invalidOutput.path))
            XCTAssertEqual(
                try recursiveRelativeContents(in: directory),
                ["root-is-a-file"]
            )
        }
    }

    func testManifestCompatibilityReturnsTypedMismatchForEveryCapabilityField()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-capability.mp4")
            let generated = try await DeterministicFMP4Fixture.generate(
                configuration: .twentySeconds,
                outputURL: outputURL,
                timeout: .seconds(30)
            )
            let manifest = generated.manifest
            let baseline = capabilityDescriptor(from: manifest)
            XCTAssertEqual(manifest.validateCompatibility(with: baseline), [])
            XCTAssertEqual(
                manifest.validateCompatibility(
                    with: capabilityDescriptor(
                        from: manifest,
                        fragmentCadence: manifest.fragmentCadenceSeconds
                            + 0.000_000_9
                    )
                ),
                []
            )
            XCTAssertEqual(
                manifest.validateCompatibility(
                    with: capabilityDescriptor(
                        from: manifest,
                        fragmentCadence: manifest.fragmentCadenceSeconds
                            + 0.000_001_1
                    )
                ),
                [.fragmentCadence]
            )

            let rows: [(DeterministicFMP4Fixture.CompatibilityMismatch,
                        DeterministicFMP4Fixture.CapabilityDescriptor)] = [
                (.mimeType, capabilityDescriptor(from: manifest, mimeType: "video/mp4")),
                (.codec, capabilityDescriptor(from: manifest, codec: "opus")),
                (.profile, capabilityDescriptor(from: manifest, profile: "aac-he")),
                (.containerLayout, capabilityDescriptor(from: manifest, layout: "flat-mp4")),
                (.nominalBitrate, capabilityDescriptor(from: manifest, nominalBitrate: 96_000)),
                (
                    .measuredBitrate,
                    capabilityDescriptor(
                        from: manifest,
                        measuredBitrate: manifest.measuredBitrateBitsPerSecond * 0.80
                    )
                ),
                (.sampleRate, capabilityDescriptor(from: manifest, sampleRate: 44_100)),
                (.channelCount, capabilityDescriptor(from: manifest, channelCount: 2)),
                (.quality, capabilityDescriptor(from: manifest, quality: "aac-96kbps")),
                (
                    .fragmentCadence,
                    capabilityDescriptor(from: manifest, fragmentCadence: 2)
                ),
            ]
            for (expectedMismatch, candidate) in rows {
                XCTAssertEqual(
                    manifest.validateCompatibility(with: candidate),
                    [expectedMismatch]
                )
            }
        }
    }

    func testManifestIsImmutableAndSharedReinspectionReturnsTypedTamperMismatch()
        async throws
    {
        try await withUniqueTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("fixture-tamper.mp4")
            let generated = try await DeterministicFMP4Fixture.generate(
                configuration: .twentySeconds,
                outputURL: outputURL,
                timeout: .seconds(30)
            )
            requireSendable(generated.manifest)
            let immutableSnapshot = generated.manifest
            let originalData = try Data(contentsOf: outputURL, options: .mappedIfSafe)
            XCTAssertEqual(immutableSnapshot.payloadSHA256, sha256Hex(originalData))
            let initialReinspection = try await immutableSnapshot
                .validateIntegrityAndReinspect(at: outputURL)
            XCTAssertEqual(initialReinspection, [])

            var tamperedData = originalData
            let mutationIndex = try XCTUnwrap(tamperedData.indices.dropFirst(32).first)
            tamperedData[mutationIndex] ^= 0x01
            try tamperedData.write(to: outputURL, options: .atomic)
            let independentlyTamperedHash = sha256Hex(
                try Data(contentsOf: outputURL, options: .mappedIfSafe)
            )
            let mismatches = try await immutableSnapshot
                .validateIntegrityAndReinspect(at: outputURL)

            XCTAssertEqual(generated.manifest, immutableSnapshot)
            XCTAssertNotEqual(independentlyTamperedHash, immutableSnapshot.payloadSHA256)
            XCTAssertTrue(mismatches.contains(.payloadSHA256))
        }
    }

    func testBroadToneEstimatorRejectsFiveHundredHertzAsA440FixtureTone() throws {
        let samples = syntheticSine(
            frequencyHz: 500,
            sampleRate: sampleRate,
            durationSeconds: 0.5,
            peakAmplitude: pow(10, expectedPeakDecibels / 20)
        )
        let observation = try IndependentToneEstimator.inspect(
            samples: samples,
            sampleRate: sampleRate,
            expectedFrequencyHz: 440,
            otherFixtureFrequenciesHz: [660, 880, 1_100]
        )

        XCTAssertEqual(observation.estimatedFrequencyHz, 500, accuracy: 1)
        XCTAssertGreaterThan(
            abs(observation.estimatedFrequencyHz - 440) / 440,
            0.03
        )
    }

    func testESDSParserExtractsUniqueDecoderSpecificInfoAndRejectsMalformedTrees()
        throws
    {
        let canonicalASC = Data([0x11, 0x88])
        let canonicalInitialization = syntheticAudioInitialization(
            audioSpecificConfig: canonicalASC
        )
        XCTAssertEqual(
            try IndependentAudioESDSParser.audioSpecificConfig(
                in: canonicalInitialization
            ),
            canonicalASC
        )
        XCTAssertEqual(
            try IndependentAudioESDSParser.decoderConfigObservation(
                in: canonicalInitialization
            ),
            DecoderConfigObservation(
                esFlags: 0,
                decoderPayloadByteCount: 17,
                objectTypeIndication: 0x40,
                packedStreamTypeByte: 0x15,
                streamType: 5,
                upstream: false,
                reserved: true,
                fixedHeaderHex: "40150000000000000000000000",
                decoderSpecificInfoByteCount: 2,
                decoderSpecificInfoHex: "1188"
            )
        )
        for mutation in SyntheticESDSMutation.allCases {
            XCTAssertThrowsError(
                try IndependentAudioESDSParser.audioSpecificConfig(
                    in: syntheticAudioInitialization(mutation: mutation)
                ),
                String(describing: mutation)
            ) { error in
                guard let oracleError = error as? IndependentFixtureOracleError,
                    case .invalidElementaryStreamDescriptor = oracleError
                else {
                    return XCTFail("Expected malformed esds rejection: \(error)")
                }
            }
        }
    }

    func testESDSStreamTypeCompatibilityAcceptsReservedVariantsAndRejectsUpstream()
        throws
    {
        let canonicalDSI = Data([0x11, 0x88])
        for packedByte in [UInt8(0x14), UInt8(0x15)] {
            let initialization = syntheticAudioInitialization(
                audioSpecificConfig: canonicalDSI,
                packedStreamTypeByte: packedByte
            )
            XCTAssertEqual(
                try IndependentAudioESDSParser.audioSpecificConfig(
                    in: initialization
                ),
                canonicalDSI,
                String(format: "packed=0x%02x", packedByte)
            )
            let observation = try IndependentAudioESDSParser
                .decoderConfigObservation(in: initialization)
            XCTAssertEqual(observation.packedStreamTypeByte, packedByte)
            XCTAssertEqual(observation.decoderSpecificInfoByteCount, 2)
            XCTAssertEqual(observation.decoderSpecificInfoHex, "1188")
        }

        for packedByte in [
            UInt8(0x16), UInt8(0x17), UInt8(0x10), UInt8(0x11),
        ] {
            XCTAssertThrowsError(
                try IndependentAudioESDSParser.audioSpecificConfig(
                    in: syntheticAudioInitialization(
                        packedStreamTypeByte: packedByte
                    )
                ),
                String(format: "packed=0x%02x", packedByte)
            ) { error in
                guard let oracleError = error as? IndependentFixtureOracleError,
                    case .invalidElementaryStreamDescriptor = oracleError
                else {
                    return XCTFail(
                        "Expected packed stream-byte rejection, got \(error)"
                    )
                }
            }
        }
    }

    func testAudioSpecificConfigParserExtractsAACLCAndRejectsMalformedBits()
        throws
    {
        let canonical = try IndependentAudioSpecificConfigParser.fixtureProfile(
            in: Data([0x11, 0x88])
        )
        XCTAssertEqual(
            canonical,
            IndependentAACFixtureProfile(
                audioObjectType: 2,
                sampleRate: 48_000,
                channelConfiguration: 1,
                frameLengthFlag: false,
                dependsOnCoreCoder: false,
                extensionFlag: false
            )
        )
        XCTAssertEqual(
            try IndependentAudioSpecificConfigParser.fixtureProfile(
                in: packedAudioSpecificConfigBits([
                    (2, 5), (15, 4), (48_000, 24), (1, 4),
                    (0, 1), (0, 1), (0, 1),
                ])
            ),
            canonical
        )
        let malformedRows: [(String, Data)] = [
            ("empty", Data()),
            ("short", Data([0x11])),
            ("zero-object-type", Data([0x00, 0x08])),
            ("truncated-escaped-object", Data([0xF8, 0x00])),
            ("truncated-explicit-frequency", Data([0x17, 0x80])),
            ("reserved-frequency-index", Data([0x16, 0x80])),
            ("reserved-channel-configuration", Data([0x11, 0xC0])),
            ("pce-required", Data([0x11, 0x80])),
            ("truncated-depends-on-core-coder", Data([0x11, 0x8A])),
            ("frame-length-flag", Data([0x11, 0x8C])),
            ("extension-flag", Data([0x11, 0x89])),
            ("sample-rate-mismatch", Data([0x12, 0x08])),
            ("channel-mismatch", Data([0x11, 0x90])),
            ("aac-main", Data([0x09, 0x88])),
            ("sbr-profile", Data([0x29, 0x88])),
            ("ps-profile", Data([0xE9, 0x88])),
            ("nonzero-trailing-extension", Data([0x11, 0x88, 0x01])),
            (
                "depends-on-core-coder",
                packedAudioSpecificConfigBits([
                    (2, 5), (3, 4), (1, 4), (0, 1), (1, 1),
                    (0, 14), (0, 1),
                ])
            ),
            (
                "explicit-sample-rate-mismatch",
                packedAudioSpecificConfigBits([
                    (2, 5), (15, 4), (44_100, 24), (1, 4),
                    (0, 1), (0, 1), (0, 1),
                ])
            ),
        ]
        for row in malformedRows {
            XCTAssertThrowsError(
                try IndependentAudioSpecificConfigParser.fixtureProfile(
                    in: row.1
                ),
                row.0
            ) { error in
                guard let oracleError = error as? IndependentFixtureOracleError,
                    case .invalidAudioSpecificConfig = oracleError
                else {
                    return XCTFail("Expected malformed ASC rejection: \(error)")
                }
            }
        }
    }

    func testISOParserRejectsTruncationMissingTimingOverflowAndNonprogress() {
        let malformedRows: [(String, Data)] = [
            ("truncated extended", truncatedExtendedBox()),
            ("truncated nested", containerWithTruncatedNestedBox()),
            ("missing timing/default", containerWithoutSampleDuration()),
            ("overflow", overflowingExtendedBox()),
            ("nonprogress", nonprogressBox()),
        ]

        for (name, data) in malformedRows {
            XCTAssertThrowsError(
                try IndependentISOParser.inspectFragmentedAudio(data),
                name
            )
        }
    }

    func testISOFieldReadersRejectShortPayloadsBeforeCraftedSiblingBytes() {
        for field in ["hdlr", "tkhd", "mdhd", "trex", "tfhd", "tfdt", "trun"] {
            XCTAssertThrowsError(
                try IndependentISOParser.inspectFragmentedAudio(
                    syntheticEditedContainer(shortField: field)
                ),
                field
            )
        }
        for field in ["hdlr", "tkhd", "mdhd", "mvhd", "elst", "trex", "tfhd", "tfdt", "trun"] {
            XCTAssertThrowsError(
                try IndependentISOParser.inspectFragmentedAudio(
                    syntheticEditedContainer(unsupportedVersionField: field)
                ),
                field
            )
        }
        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(
                    unsupportedVersionField: "mehd",
                    unknownDurationEncoding: .zero
                )
            )
        )
    }

    func testISOParserMapsZeroDurationPrimingEditAndDerivesByteRanges() throws {
        for row in [
            (name: "no-trailing-padding", trailingTicks: UInt32(0)),
            (name: "one-packet-trailing-padding", trailingTicks: UInt32(1_024)),
        ] {
            let finalDecodeEnd = UInt32(2_112 + 48_000) + row.trailingTicks
            let data = syntheticEditedContainer(
                includeTwoSIDXBoxes: true,
                mehdDurationMovieTicks: 1_000,
                knownMovieDuration: 1_000,
                knownMediaDuration: finalDecodeEnd,
                editSegmentDuration: 0,
                editMediaTime: 2_112,
                fragmentSampleCounts: [48_000, finalDecodeEnd - 48_000]
            )
            let inspection = try IndependentISOParser.inspectFragmentedAudio(data)

            XCTAssertEqual(inspection.mediaTimescale, 48_000, row.name)
            XCTAssertEqual(
                inspection.mediaDurationTicks,
                UInt64(finalDecodeEnd),
                row.name
            )
            XCTAssertEqual(inspection.resolvedMediaDurationSource, .mdhd, row.name)
            XCTAssertEqual(inspection.movieTimescale, 1_000, row.name)
            XCTAssertEqual(
                inspection.editListPresentationDurationSeconds,
                1,
                accuracy: 0.000_001,
                row.name
            )
            XCTAssertEqual(inspection.presentationMediaStartTicks, 2_112, row.name)
            XCTAssertEqual(
                inspection.trailingPaddingTicks,
                UInt64(row.trailingTicks),
                row.name
            )
            XCTAssertFalse(inspection.hasFinalZeroCoveredPadding, row.name)
            XCTAssertEqual(inspection.fragments.first?.startTicks, 0, row.name)
            XCTAssertEqual(
                inspection.fragments.last?.endTicks,
                UInt64(finalDecodeEnd),
                row.name
            )
            XCTAssertEqual(inspection.initializationRange.lowerBound, 0, row.name)
            XCTAssertGreaterThan(inspection.initializationRange.upperBound, 0, row.name)
            XCTAssertNotNil(inspection.indexRange, row.name)
        }

        let externallyBoundTarget = try IndependentISOParser.inspectFragmentedAudio(
            syntheticEditedContainer(
                unknownDurationEncoding: .zero,
                includeMEHDForUnknownDuration: false,
                editSegmentDuration: 0,
                editMediaTime: 2_112,
                fragmentSampleCounts: [48_000, 2_560]
            ),
            expectedPresentationDurationSeconds: 1
        )
        XCTAssertEqual(externallyBoundTarget.resolvedMediaDurationSource, .finalFragment)
        XCTAssertEqual(externallyBoundTarget.mediaDurationTicks, 50_560)
        XCTAssertEqual(externallyBoundTarget.presentationMediaStartTicks, 2_112)
        XCTAssertEqual(externallyBoundTarget.editListPresentationDurationSeconds, 1)
        XCTAssertEqual(externallyBoundTarget.trailingPaddingTicks, 448)
    }

    func testISOParserRejectsZeroDurationEditUnderflowAndExcessTrailingPadding() {
        for entryCount in [UInt32(0), UInt32(2)] {
            XCTAssertThrowsError(
                try IndependentISOParser.inspectFragmentedAudio(
                    syntheticEditedContainer(editEntryCount: entryCount)
                )
            ) { error in
                guard let oracleError = error as? IndependentFixtureOracleError,
                    case .unsupportedEditList = oracleError
                else {
                    return XCTFail("Expected exactly-one-edit rejection, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(duplicateEditListBox: true)
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .unsupportedEditList = oracleError
            else {
                return XCTFail("Expected duplicate elst rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(duplicateEditContainer: true)
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .unsupportedEditList = oracleError
            else {
                return XCTFail("Expected duplicate edts rejection, got \(error)")
            }
        }
        for mediaTime in [UInt32(50_112), UInt32(50_113)] {
            XCTAssertThrowsError(
                try IndependentISOParser.inspectFragmentedAudio(
                    syntheticEditedContainer(
                        knownMovieDuration: 1_000,
                        knownMediaDuration: 50_112,
                        editSegmentDuration: 0,
                        editMediaTime: mediaTime,
                        fragmentSampleCounts: [48_000, 2_112]
                    )
                )
            ) { error in
                guard let oracleError = error as? IndependentFixtureOracleError,
                    case .editListDurationMismatch = oracleError
                else {
                    return XCTFail("Expected zero-edit underflow rejection, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(
                    knownMovieDuration: 1_000,
                    knownMediaDuration: 51_137,
                    editSegmentDuration: 0,
                    editMediaTime: 2_112,
                    fragmentSampleCounts: [48_000, 3_137]
                )
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .editListDurationMismatch = oracleError
            else {
                return XCTFail("Expected >packet trailing-padding rejection, got \(error)")
            }
        }
    }

    func testISOParserTreatsOneTickMVHDAsZeroEditFragmentedPlaceholderOnly()
        throws
    {
        let runtimeShaped = syntheticEditedContainer(
            movieTimescale: 48_000,
            knownMovieDuration: 1,
            knownMediaDuration: 0,
            editSegmentDuration: 0,
            editMediaTime: 2_112,
            fragmentSampleCounts: [48_000, 2_560]
        )
        let inspection = try IndependentISOParser.inspectFragmentedAudio(
            runtimeShaped,
            expectedPresentationDurationSeconds: 1
        )

        XCTAssertEqual(inspection.movieTimescale, 48_000)
        XCTAssertEqual(inspection.resolvedMediaDurationSource, .finalFragment)
        XCTAssertEqual(inspection.mediaDurationTicks, 50_560)
        XCTAssertEqual(inspection.presentationMediaStartTicks, 2_112)
        XCTAssertEqual(inspection.editListPresentationDurationSeconds, 1)
        XCTAssertEqual(inspection.trailingPaddingTicks, 448)

        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(
                    knownMovieDuration: 2_000,
                    knownMediaDuration: 0,
                    editSegmentDuration: 0,
                    editMediaTime: 2_112,
                    fragmentSampleCounts: [48_000, 2_560]
                ),
                expectedPresentationDurationSeconds: 1
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .moviePresentationDurationMismatch = oracleError
            else {
                return XCTFail(
                    "Two-second mvhd must remain authoritative: \(error)"
                )
            }
        }

        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(
                    movieTimescale: 48_000,
                    knownMovieDuration: 1,
                    knownMediaDuration: 0,
                    editSegmentDuration: 48_000,
                    editMediaTime: 2_112,
                    fragmentSampleCounts: [48_000, 2_560]
                )
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .moviePresentationDurationMismatch = oracleError
            else {
                return XCTFail(
                    "Positive edit must not ignore one-tick mvhd: \(error)"
                )
            }
        }
    }

    func testISOParserAcceptsOneFinalZeroCoveredPaddingFragment() throws {
        let inspection = try IndependentISOParser.inspectFragmentedAudio(
            syntheticEditedContainer(
                knownMovieDuration: 1_000,
                knownMediaDuration: 50_560,
                editSegmentDuration: 0,
                editMediaTime: 2_112,
                fragmentSampleCounts: [48_000, 2_112, 448],
                fragmentStartTicks: [0, 48_000, 50_112]
            )
        )

        XCTAssertEqual(inspection.presentationMediaStartTicks, 2_112)
        XCTAssertEqual(inspection.editListPresentationDurationSeconds, 1)
        XCTAssertEqual(inspection.trailingPaddingTicks, 448)
        XCTAssertTrue(inspection.hasFinalZeroCoveredPadding)
        XCTAssertEqual(inspection.fragments.count, 3)
        XCTAssertEqual(inspection.fragments.last?.startTicks, 50_112)
        XCTAssertEqual(inspection.fragments.last?.endTicks, 50_560)
        XCTAssertEqual(
            measuredPresentationFragmentCadence(
                fragments: inspection.fragments,
                hasFinalZeroCoveredPadding:
                    inspection.hasFinalZeroCoveredPadding,
                mediaTimescale: inspection.mediaTimescale,
                fallbackPresentationDurationSeconds:
                    inspection.editListPresentationDurationSeconds
            ),
            1,
            accuracy: 0.000_001
        )
    }

    func testISOParserRejectsMisplacedDuplicateAndOversizedFinalPadding() {
        let rows: [(
            name: String,
            mediaDuration: UInt32,
            sampleCounts: [UInt32],
            starts: [UInt32],
            expected: IndependentFixtureOracleError
        )] = [
            (
                "padding-start-after-presentation-end",
                50_561,
                [48_000, 2_112, 448],
                [0, 48_000, 50_113],
                .fragmentCadenceMismatch
            ),
            (
                "duplicate-final-padding",
                50_624,
                [48_000, 2_112, 256, 256],
                [0, 48_000, 50_112, 50_368],
                .fragmentCadenceMismatch
            ),
            (
                "padding-over-one-packet",
                51_137,
                [48_000, 2_112, 1_025],
                [0, 48_000, 50_112],
                .fragmentDurationOutOfBounds
            ),
        ]

        for row in rows {
            XCTAssertThrowsError(
                try IndependentISOParser.inspectFragmentedAudio(
                    syntheticEditedContainer(
                        knownMovieDuration: 1_000,
                        knownMediaDuration: row.mediaDuration,
                        editSegmentDuration: 0,
                        editMediaTime: 2_112,
                        fragmentSampleCounts: row.sampleCounts,
                        fragmentStartTicks: row.starts
                    )
                ),
                row.name
            ) { error in
                guard let oracleError = error as? IndependentFixtureOracleError
                else {
                    return XCTFail("Expected ISO oracle error, got \(error)")
                }
                switch (oracleError, row.expected) {
                case (.fragmentCadenceMismatch, .fragmentCadenceMismatch),
                    (.fragmentDurationOutOfBounds, .fragmentDurationOutOfBounds):
                    break
                default:
                    XCTFail(
                        "Expected \(row.expected), got \(oracleError)",
                        file: #filePath,
                        line: #line
                    )
                }
            }
        }
    }

    func testISOParserKeepsMEHDOnPresentationTimelineWhenNativeDurationIsUnknown()
        throws
    {
        for (encoding, mehdVersion) in [
            (SyntheticUnknownDurationEncoding.zero, UInt8(0)),
            (.allOnes, UInt8(1)),
        ] {
            let inspection = try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(
                    unknownDurationEncoding: encoding,
                    mehdVersion: mehdVersion
                )
            )

            XCTAssertEqual(inspection.mediaDurationTicks, 49_152)
            XCTAssertEqual(inspection.resolvedMediaDurationSource, .finalFragment)
            XCTAssertEqual(
                inspection.editListPresentationDurationSeconds,
                1,
                accuracy: 0.000_001
            )
            XCTAssertEqual(inspection.fragments.last?.endTicks, 49_152)
        }
        let fragmentFallback = try IndependentISOParser.inspectFragmentedAudio(
            syntheticEditedContainer(
                unknownDurationEncoding: .zero,
                includeMEHDForUnknownDuration: false
            )
        )
        XCTAssertEqual(fragmentFallback.mediaDurationTicks, 49_152)
        XCTAssertEqual(fragmentFallback.resolvedMediaDurationSource, .finalFragment)
    }

    func testISOParserRejectsNativeAndPresentationTimelineContradictions() {
        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(knownMediaDuration: 48_000)
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .mediaDurationMismatch = oracleError
            else {
                return XCTFail("Expected mdhd/final conflict, got \(error)")
            }
        }
        for unknownNativeDuration in [false, true] {
            XCTAssertThrowsError(
                try IndependentISOParser.inspectFragmentedAudio(
                    syntheticEditedContainer(
                        unknownDurationEncoding: unknownNativeDuration ? .zero : nil,
                        mehdDurationMovieTicks: 2_000
                    )
                )
            ) { error in
                guard let oracleError = error as? IndependentFixtureOracleError,
                    case .mehdPresentationDurationMismatch = oracleError
                else {
                    return XCTFail("Expected mehd/edit conflict, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(knownMovieDuration: 2_000)
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .moviePresentationDurationMismatch = oracleError
            else {
                return XCTFail("Expected mvhd/edit conflict, got \(error)")
            }
        }
    }

    func testISOParserRejectsNineteenFragmentTimelineWithTwoSecondTail() {
        let sampleCounts = Array(repeating: UInt32(48), count: 18) + [UInt32(96)]
        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(
                    knownMovieDuration: 20_000,
                    knownMediaDuration: 960_000,
                    editSegmentDuration: 20_000,
                    editMediaTime: 0,
                    defaultSampleDuration: 1_000,
                    fragmentSampleCounts: sampleCounts
                )
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .fragmentDurationOutOfBounds = oracleError
            else {
                return XCTFail("Expected two-second final-fragment rejection, got \(error)")
            }
        }
    }

    func testISOParserRejectsFiftyNineDriftingFragmentsForSixtySeconds() {
        let totalFrames: Int64 = 60 * 48_000
        let boundaries = (0...59).map { index in
            UInt32(Int64(index) * totalFrames / 59)
        }
        let starts = Array(boundaries.dropLast())
        let sampleCounts = zip(boundaries, boundaries.dropFirst()).map { lower, upper in
            upper - lower
        }
        XCTAssertEqual(boundaries.last, UInt32(totalFrames))
        XCTAssertEqual(starts.count, 59)
        XCTAssertEqual(sampleCounts.count, 59)

        XCTAssertThrowsError(
            try IndependentISOParser.inspectFragmentedAudio(
                syntheticEditedContainer(
                    knownMovieDuration: 60_000,
                    knownMediaDuration: UInt32(totalFrames),
                    editSegmentDuration: 60_000,
                    editMediaTime: 0,
                    defaultSampleDuration: 1,
                    fragmentSampleCounts: sampleCounts,
                    fragmentStartTicks: starts
                )
            )
        ) { error in
            guard let oracleError = error as? IndependentFixtureOracleError,
                case .fragmentCadenceMismatch = oracleError
            else {
                return XCTFail("Expected 59-fragment cadence rejection, got \(error)")
            }
        }
    }

    private func assertDirectoryIsEmptyWithoutThrowing(
        _ directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            try recursiveRelativeContents(in: directory),
            [],
            file: file,
            line: line
        )
    }

    private func completeInitializationDelivery(
        on gate: DeterministicFMP4Fixture.SegmentAssemblyGate,
        presentationMediaStartFrame: Int64 = 0
    ) throws {
        let observation = makeSegmentObservation(
                kind: .initialization,
                ordinal: 0,
                rawStartFrame: 0,
                rawEndFrame: 0,
                coveredStartFrame: 0,
                coveredEndFrame: 0,
                presentationMediaStartFrame: presentationMediaStartFrame
            )
        let token = try beginSegmentDelivery(
            on: gate,
            observation: observation,
            ownedPayload: Data("initialization".utf8)
        )
        try gate.completeDelivery(token)
    }

    private func beginSegmentDelivery(
        on gate: DeterministicFMP4Fixture.SegmentAssemblyGate,
        observation: DeterministicFMP4Fixture.SegmentCallbackObservation,
        ownedPayload: Data? = nil
    ) throws -> DeterministicFMP4Fixture.SegmentDeliveryToken {
        try gate.beginDelivery(
            observation,
            ownedPayload: ownedPayload ?? Data("segment-\(observation.ordinal)".utf8)
        )
    }

    private func makeSegmentObservation(
        kind: DeterministicFMP4Fixture.SegmentKind,
        ordinal: Int,
        rawStartFrame: Int64,
        rawEndFrame: Int64,
        coveredStartFrame: Int64,
        coveredEndFrame: Int64,
        presentationMediaStartFrame: Int64 = 0
    ) -> DeterministicFMP4Fixture.SegmentCallbackObservation {
        DeterministicFMP4Fixture.SegmentCallbackObservation(
            kind: kind,
            ordinal: ordinal,
            rawStartFrame: rawStartFrame,
            rawEndFrame: rawEndFrame,
            presentationMediaStartFrame: presentationMediaStartFrame,
            coveredPresentationStartFrame: coveredStartFrame,
            coveredPresentationEndFrame: coveredEndFrame
        )
    }

    private func assertIndependentFixture(
        _ inspection: IndependentFixtureInspection,
        expectedDuration: Double,
        expectedToneRegions: [IndependentToneRegion],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(inspection.totalTrackCount, 1, file: file, line: line)
        XCTAssertEqual(inspection.audioTrackCount, 1, file: file, line: line)
        XCTAssertEqual(inspection.formatID, kAudioFormatMPEG4AAC, file: file, line: line)
        XCTAssertEqual(inspection.audioObjectType, 2, file: file, line: line)
        XCTAssertEqual(inspection.sampleRate, sampleRate, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(inspection.channelCount, 1, file: file, line: line)
        XCTAssertEqual(
            inspection.durationSeconds,
            expectedDuration,
            accuracy: packetDuration,
            file: file,
            line: line
        )
        XCTAssertEqual(
            inspection.durationSeconds,
            inspection.editListPresentationDurationSeconds,
            accuracy: packetDuration,
            file: file,
            line: line
        )
        XCTAssertTrue(inspection.strictlyIncreasingContinuousPTS, file: file, line: line)
        XCTAssertEqual(
            inspection.firstDecodedSampleStartSeconds,
            0,
            accuracy: packetDuration,
            file: file,
            line: line
        )
        XCTAssertEqual(
            inspection.lastDecodedSampleEndSeconds,
            inspection.durationSeconds,
            accuracy: packetDuration,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            inspection.presentationMediaStartFrame,
            0,
            file: file,
            line: line
        )
        let expectedRawPresentationEndSeconds = (
            Double(inspection.presentationMediaStartFrame)
                + expectedDuration * sampleRate
        ) / sampleRate
        XCTAssertGreaterThanOrEqual(
            inspection.fragments.last?.endSeconds ?? -.infinity,
            expectedRawPresentationEndSeconds,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            inspection.fragments.last?.endSeconds ?? .infinity,
            expectedRawPresentationEndSeconds + packetDuration,
            file: file,
            line: line
        )
        XCTAssertTrue(inspection.hasCanonicalTopLevelOrder, file: file, line: line)
        let presentationBearingFragments = inspection.hasFinalZeroCoveredPadding
            ? Array(inspection.fragments.dropLast())
            : inspection.fragments
        XCTAssertGreaterThanOrEqual(
            presentationBearingFragments.count,
            max(1, Int(expectedDuration.rounded(.down))),
            file: file,
            line: line
        )
        let presentationMediaStartSeconds = Double(
            inspection.presentationMediaStartFrame
        ) / sampleRate
        var previous: IndependentMediaFragment?
        for fragment in inspection.fragments {
            XCTAssertGreaterThan(fragment.durationSeconds, 0, file: file, line: line)
            if let previous {
                XCTAssertGreaterThan(
                    fragment.startSeconds,
                    previous.startSeconds,
                    file: file,
                    line: line
                )
                XCTAssertGreaterThanOrEqual(
                    fragment.startSeconds,
                    previous.endSeconds,
                    file: file,
                    line: line
                )
            } else {
                XCTAssertEqual(
                    fragment.startSeconds,
                    0,
                    accuracy: packetDuration,
                    file: file,
                    line: line
                )
            }
            previous = fragment
        }
        if inspection.hasFinalZeroCoveredPadding {
            guard let terminalPadding = inspection.fragments.last else {
                XCTFail(
                    "Missing terminal padding fragment",
                    file: file,
                    line: line
                )
                return
            }
            XCTAssertEqual(
                terminalPadding.startSeconds,
                expectedRawPresentationEndSeconds,
                accuracy: 1 / sampleRate,
                file: file,
                line: line
            )
            XCTAssertGreaterThan(
                terminalPadding.durationSeconds,
                0,
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                terminalPadding.durationSeconds,
                packetDuration,
                file: file,
                line: line
            )
            XCTAssertEqual(
                min(
                    expectedDuration,
                    max(
                        0,
                        terminalPadding.startSeconds
                            - presentationMediaStartSeconds
                    )
                ),
                expectedDuration,
                accuracy: 1 / sampleRate,
                file: file,
                line: line
            )
            XCTAssertEqual(
                min(
                    expectedDuration,
                    max(
                        0,
                        terminalPadding.endSeconds
                            - presentationMediaStartSeconds
                    )
                ),
                expectedDuration,
                accuracy: 1 / sampleRate,
                file: file,
                line: line
            )
        }
        for (index, fragment) in presentationBearingFragments.enumerated() {
            let mappedStart = min(
                expectedDuration,
                max(0, fragment.startSeconds - presentationMediaStartSeconds)
            )
            let expectedMappedStart = min(
                expectedDuration,
                max(0, Double(index) - presentationMediaStartSeconds)
            )
            XCTAssertEqual(
                mappedStart,
                expectedMappedStart,
                accuracy: packetDuration,
                file: file,
                line: line
            )
            let mappedEnd = min(
                expectedDuration,
                max(0, fragment.endSeconds - presentationMediaStartSeconds)
            )
            XCTAssertGreaterThan(mappedEnd, mappedStart, file: file, line: line)
            if index > 0, index < presentationBearingFragments.count - 1 {
                XCTAssertEqual(
                    fragment.durationSeconds,
                    1,
                    accuracy: packetDuration,
                    file: file,
                    line: line
                )
            } else {
                XCTAssertLessThanOrEqual(
                    fragment.durationSeconds,
                    1 + packetDuration,
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertEqual(
            inspection.fragments.last?.endSeconds ?? .infinity,
            inspection.mediaDurationSeconds,
            accuracy: packetDuration,
            file: file,
            line: line
        )
        XCTAssertEqual(inspection.initializationRange.lowerBound, 0, file: file, line: line)
        XCTAssertGreaterThan(inspection.initializationRange.upperBound, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(
            inspection.initializationRange.upperBound,
            inspection.contentLength,
            file: file,
            line: line
        )
        if let indexRange = inspection.indexRange {
            XCTAssertGreaterThanOrEqual(indexRange.lowerBound, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(
                indexRange.upperBound,
                inspection.contentLength,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            inspection.payloadBitrateBitsPerSecond,
            nominalBitrate,
            accuracy: nominalBitrate * 0.10,
            file: file,
            line: line
        )
        XCTAssertEqual(inspection.toneWindows.count, expectedToneRegions.count, file: file, line: line)
        for (region, tone) in zip(expectedToneRegions, inspection.toneWindows) {
            XCTAssertEqual(
                tone.estimatedFrequencyHz,
                region.frequencyHz,
                accuracy: region.frequencyHz * 0.03,
                file: file,
                line: line
            )
            XCTAssertEqual(
                tone.peakDecibels,
                expectedPeakDecibels,
                accuracy: aacAmplitudeToleranceDecibels,
                file: file,
                line: line
            )
            XCTAssertEqual(
                tone.rmsDecibels,
                expectedSineRMSDecibels,
                accuracy: aacAmplitudeToleranceDecibels,
                file: file,
                line: line
            )
            XCTAssertGreaterThanOrEqual(
                tone.expectedToneSeparationDecibels,
                6,
                file: file,
                line: line
            )
        }
    }

    private func assertManifest(
        _ manifest: DeterministicFMP4Fixture.Manifest,
        matches inspection: IndependentFixtureInspection,
        expectedDuration: Double,
        expectedToneRegions: [IndependentToneRegion]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(manifest.payloadSHA256, inspection.payloadSHA256, file: file, line: line)
        XCTAssertEqual(manifest.codec, "aac", file: file, line: line)
        XCTAssertEqual(manifest.profile, "aac-lc", file: file, line: line)
        XCTAssertEqual(manifest.qualityLabel, "aac-128kbps", file: file, line: line)
        XCTAssertEqual(manifest.mimeType, "audio/mp4", file: file, line: line)
        XCTAssertEqual(
            manifest.containerLayout,
            inspection.containerLayoutProfile,
            file: file,
            line: line
        )
        XCTAssertEqual(
            manifest.measuredBitrateBitsPerSecond,
            inspection.payloadBitrateBitsPerSecond,
            accuracy: nominalBitrate * 0.01,
            file: file,
            line: line
        )
        XCTAssertEqual(manifest.nominalBitrateBitsPerSecond, Int(nominalBitrate), file: file, line: line)
        XCTAssertEqual(manifest.sampleRate, sampleRate, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(manifest.channelCount, 1, file: file, line: line)
        XCTAssertEqual(
            inspection.measuredFragmentCadenceSeconds,
            1,
            accuracy: packetDuration,
            file: file,
            line: line
        )
        XCTAssertEqual(
            manifest.fragmentCadenceSeconds,
            1,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
        XCTAssertEqual(manifest.durationSeconds, expectedDuration, accuracy: packetDuration, file: file, line: line)
        XCTAssertEqual(manifest.contentLength, inspection.contentLength, file: file, line: line)
        if let expectedToneRegions {
            XCTAssertEqual(
                manifest.toneScheduleSHA256,
                toneScheduleSHA256(expectedToneRegions),
                file: file,
                line: line
            )
        }
    }

    // PRE-RED contract: DeterministicFixtureManifest's memberwise initializer
    // remains fileprivate; callers can only obtain it from a completed generator.
    private func capabilityDescriptor(
        from manifest: DeterministicFMP4Fixture.Manifest,
        mimeType: String? = nil,
        codec: String? = nil,
        profile: String? = nil,
        layout: String? = nil,
        nominalBitrate: Int? = nil,
        measuredBitrate: Double? = nil,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        quality: String? = nil,
        fragmentCadence: Double? = nil
    ) -> DeterministicFMP4Fixture.CapabilityDescriptor {
        let resolvedMIMEType = mimeType ?? manifest.mimeType
        let resolvedCodec = codec ?? manifest.codec
        let resolvedProfile = profile ?? manifest.profile
        let resolvedLayout = layout ?? manifest.containerLayout
        let resolvedNominalBitrate = nominalBitrate
            ?? manifest.nominalBitrateBitsPerSecond
        let resolvedMeasuredBitrate = measuredBitrate
            ?? manifest.measuredBitrateBitsPerSecond
        let resolvedSampleRate = sampleRate ?? manifest.sampleRate
        let resolvedChannelCount = channelCount ?? manifest.channelCount
        let resolvedQuality = quality ?? manifest.qualityLabel
        let resolvedFragmentCadence = fragmentCadence
            ?? manifest.fragmentCadenceSeconds
        return DeterministicFMP4Fixture.CapabilityDescriptor(
            mimeType: resolvedMIMEType,
            codec: resolvedCodec,
            profile: resolvedProfile,
            containerLayout: resolvedLayout,
            nominalBitrateBitsPerSecond: resolvedNominalBitrate,
            measuredBitrateBitsPerSecond: resolvedMeasuredBitrate,
            sampleRate: resolvedSampleRate,
            channelCount: resolvedChannelCount,
            qualityLabel: resolvedQuality,
            fragmentCadenceSeconds: resolvedFragmentCadence
        )
    }

    private static let twentySecondToneRegions: [IndependentToneRegion] = [
        .init(startSeconds: 0, endSeconds: 2.5, frequencyHz: 440),
        .init(startSeconds: 2.5, endSeconds: 7.5, frequencyHz: 660),
        .init(startSeconds: 7.5, endSeconds: 12.5, frequencyHz: 880),
        .init(startSeconds: 12.5, endSeconds: 20, frequencyHz: 1_100),
    ]
}

private final class SegmentPayloadDiagnosticCapture: @unchecked Sendable {
    private struct Observation: CustomStringConvertible {
        let kind: DeterministicFMP4Fixture.SegmentKind
        let ordinal: Int
        let byteCount: Int
        let boxTypes: [String]
        let payload: Data

        var description: String {
            "\(kind)#\(ordinal):\(byteCount):\(boxTypes)"
        }
    }

    private let lock = NSLock()
    private var observations: [Observation] = []

    func record(
        kind: DeterministicFMP4Fixture.SegmentKind,
        ordinal: Int,
        payload: Data
    ) {
        let observation = Observation(
            kind: kind,
            ordinal: ordinal,
            byteCount: payload.count,
            boxTypes: Self.topLevelBoxTypes(in: payload),
            payload: payload
        )
        lock.lock()
        observations.append(observation)
        lock.unlock()
    }

    func summary() -> [String] {
        lock.lock()
        let value = observations.map(\.description)
        lock.unlock()
        return value
    }

    func timelineSummary() -> [String] {
        lock.lock()
        let data = observations.reduce(into: Data()) { output, observation in
            output.append(observation.payload)
        }
        lock.unlock()
        do {
            let inspection = try IndependentISOParser.inspectFragmentedAudio(data)
            return inspection.fragments.enumerated().map { index, fragment in
                "\(index + 1):\(fragment.startTicks)-\(fragment.endTicks)"
            }
        } catch {
            return ["error:\(error)"]
        }
    }

    func structuralAtomSummary() -> [String] {
        lock.lock()
        let initialization = observations.first(where: {
            $0.kind == .initialization
        })?.payload
        lock.unlock()
        guard let initialization else { return ["missing-init"] }
        return ["elst", "mdhd", "mvhd"].map { type in
            let marker = Data(type.utf8)
            guard let typeRange = initialization.range(of: marker),
                typeRange.lowerBound >= initialization.startIndex + 4
            else { return "\(type):missing" }
            let start = typeRange.lowerBound - 4
            let end = min(initialization.endIndex, start + 48)
            let hex = initialization[start..<end].map {
                String(format: "%02x", $0)
            }.joined()
            return "\(type):\(hex)"
        }
    }

    private static func topLevelBoxTypes(in data: Data) -> [String] {
        var result: [String] = []
        var offset = data.startIndex
        while offset <= data.endIndex - min(8, data.count),
            data.endIndex - offset >= 8
        {
            let sizeBytes = data[offset..<(offset + 4)]
            let size = sizeBytes.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard size >= 8, Int(size) <= data.endIndex - offset else {
                break
            }
            let typeBytes = data[(offset + 4)..<(offset + 8)]
            result.append(String(data: typeBytes, encoding: .ascii) ?? "????")
            offset += Int(size)
        }
        return result
    }
}

private final class InitMutationLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let workerCloseRequested: XCTestExpectation
    private var snapshots: [
        DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot
    ] = []
    private var commits = 0
    private var outcomes: [DeterministicFMP4Fixture.TerminalOutcome] = []

    init(workerCloseRequested: XCTestExpectation) {
        self.workerCloseRequested = workerCloseRequested
    }

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) {
        switch event {
        case let .segmentWorkerCloseRequested(snapshot):
            lock.lock()
            let isFirst = snapshots.isEmpty
            snapshots.append(snapshot)
            lock.unlock()
            if isFirst { workerCloseRequested.fulfill() }
        case .outputDidCommitBeforeTerminalClaim:
            lock.lock()
            commits += 1
            lock.unlock()
        case let .terminal(outcome):
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
        default:
            break
        }
    }

    func closeSnapshots()
        -> [DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot]
    {
        lock.lock()
        let value = snapshots
        lock.unlock()
        return value
    }

    func outputCommitCount() -> Int {
        lock.lock()
        let value = commits
        lock.unlock()
        return value
    }

    func terminalOutcomes() -> [DeterministicFMP4Fixture.TerminalOutcome] {
        lock.lock()
        let value = outcomes
        lock.unlock()
        return value
    }
}

private enum InitializationEditMutation: CaseIterable, Sendable {
    case nonzeroSegmentDuration
    case duplicateEditList
    case duplicateEditContainer

    var name: String {
        switch self {
        case .nonzeroSegmentDuration: "nonzero-segment-duration"
        case .duplicateEditList: "duplicate-elst"
        case .duplicateEditContainer: "duplicate-edts"
        }
    }
}

private final class InitializationEditProfileMutator: @unchecked Sendable {
    private struct Box {
        let type: String
        let fullRange: Range<Int>
        let payloadRange: Range<Int>
    }

    private struct EditPath {
        let movie: Box
        let track: Box
        let editContainer: Box
        let editList: Box
    }

    private enum MutationError: Error {
        case malformedInitialization
        case missingUniqueEditList
        case unexpectedEditProfile
    }

    private let lock = NSLock()
    private let mutation: InitializationEditMutation
    private var mutationCount = 0

    init(mutation: InitializationEditMutation) {
        self.mutation = mutation
    }

    func transform(
        kind: DeterministicFMP4Fixture.SegmentKind,
        ordinal: Int,
        payload: Data
    ) throws -> Data {
        guard kind == .initialization else { return payload }
        guard ordinal == 0 else { throw MutationError.unexpectedEditProfile }
        var mutated = payload
        let topLevel = try boxes(
            in: mutated,
            range: mutated.startIndex..<mutated.endIndex
        )
        let movies = topLevel.filter { $0.type == "moov" }
        guard movies.count == 1, let movie = movies.first else {
            throw MutationError.malformedInitialization
        }
        var editPaths: [EditPath] = []
        for track in try children(of: movie, data: mutated)
            where track.type == "trak"
        {
            for editContainer in try children(of: track, data: mutated)
                where editContainer.type == "edts"
            {
                for editList in try children(of: editContainer, data: mutated)
                    where editList.type == "elst"
                {
                    editPaths.append(
                        EditPath(
                            movie: movie,
                            track: track,
                            editContainer: editContainer,
                            editList: editList
                        )
                    )
                }
            }
        }
        guard editPaths.count == 1, let path = editPaths.first else {
            throw MutationError.missingUniqueEditList
        }
        let editList = path.editList
        let fullHeader = try uint32(
            mutated,
            at: editList.payloadRange.lowerBound,
            within: editList.payloadRange
        )
        let version = UInt8((fullHeader >> 24) & 0xFF)
        guard version == 0 || version == 1,
            try uint32(
                mutated,
                at: editList.payloadRange.lowerBound + 4,
                within: editList.payloadRange
            ) == 1
        else {
            throw MutationError.unexpectedEditProfile
        }
        let durationOffset = editList.payloadRange.lowerBound + 8
        let durationByteCount = version == 1 ? 8 : 4
        let durationRange = try checkedRange(
            offset: durationOffset,
            count: durationByteCount,
            within: editList.payloadRange
        )
        guard mutated[durationRange].allSatisfy({ $0 == 0 }) else {
            throw MutationError.unexpectedEditProfile
        }
        switch mutation {
        case .nonzeroSegmentDuration:
            var replacement = Data(repeating: 0, count: durationByteCount)
            guard let lastIndex = replacement.indices.last else {
                throw MutationError.malformedInitialization
            }
            replacement[lastIndex] = 1
            mutated.replaceSubrange(durationRange, with: replacement)

        case .duplicateEditList:
            let duplicated = Data(mutated[path.editList.fullRange])
            try increaseCompactBoxSize(
                path.editContainer,
                by: duplicated.count,
                in: &mutated
            )
            try increaseCompactBoxSize(
                path.track,
                by: duplicated.count,
                in: &mutated
            )
            try increaseCompactBoxSize(
                path.movie,
                by: duplicated.count,
                in: &mutated
            )
            mutated.insert(
                contentsOf: duplicated,
                at: path.editList.fullRange.upperBound
            )

        case .duplicateEditContainer:
            let duplicated = Data(mutated[path.editContainer.fullRange])
            try increaseCompactBoxSize(
                path.track,
                by: duplicated.count,
                in: &mutated
            )
            try increaseCompactBoxSize(
                path.movie,
                by: duplicated.count,
                in: &mutated
            )
            mutated.insert(
                contentsOf: duplicated,
                at: path.editContainer.fullRange.upperBound
            )
        }
        lock.lock()
        mutationCount += 1
        lock.unlock()
        return mutated
    }

    func didApplyMutation() -> Bool {
        lock.lock()
        let value = mutationCount == 1
        lock.unlock()
        return value
    }

    private func children(of box: Box, data: Data) throws -> [Box] {
        try boxes(in: data, range: box.payloadRange)
    }

    private func boxes(in data: Data, range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else {
                throw MutationError.malformedInitialization
            }
            let compactSize = UInt64(
                try uint32(data, at: offset, within: range)
            )
            let typeRange = try checkedRange(
                offset: offset + 4,
                count: 4,
                within: range
            )
            guard let type = String(
                data: data[typeRange],
                encoding: .ascii
            ) else {
                throw MutationError.malformedInitialization
            }
            let headerSize: Int
            let size: UInt64
            switch compactSize {
            case 0:
                headerSize = 8
                size = UInt64(range.upperBound - offset)
            case 1:
                headerSize = 16
                size = try uint64(data, at: offset + 8, within: range)
            default:
                headerSize = 8
                size = compactSize
            }
            guard size >= UInt64(headerSize),
                size <= UInt64(range.upperBound - offset),
                size <= UInt64(Int.max)
            else {
                throw MutationError.malformedInitialization
            }
            let end = offset + Int(size)
            result.append(
                Box(
                    type: type,
                    fullRange: offset..<end,
                    payloadRange: (offset + headerSize)..<end
                )
            )
            offset = end
        }
        return result
    }

    private func increaseCompactBoxSize(
        _ box: Box,
        by byteCount: Int,
        in data: inout Data
    ) throws {
        guard byteCount > 0 else {
            throw MutationError.malformedInitialization
        }
        let encoded = try uint32(
            data,
            at: box.fullRange.lowerBound,
            within: box.fullRange
        )
        guard encoded > 1 else {
            throw MutationError.unexpectedEditProfile
        }
        let (expanded, overflow) = Int(encoded).addingReportingOverflow(
            byteCount
        )
        guard !overflow, expanded <= Int(UInt32.max) else {
            throw MutationError.malformedInitialization
        }
        let bytes = Data([
            UInt8((UInt32(expanded) >> 24) & 0xFF),
            UInt8((UInt32(expanded) >> 16) & 0xFF),
            UInt8((UInt32(expanded) >> 8) & 0xFF),
            UInt8(UInt32(expanded) & 0xFF),
        ])
        let sizeRange = try checkedRange(
            offset: box.fullRange.lowerBound,
            count: 4,
            within: box.fullRange
        )
        data.replaceSubrange(sizeRange, with: bytes)
    }

    private func uint32(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt32 {
        let bytes = try checkedRange(offset: offset, count: 4, within: range)
        return data[bytes].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func uint64(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt64 {
        let bytes = try checkedRange(offset: offset, count: 8, within: range)
        return data[bytes].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func checkedRange(
        offset: Int,
        count: Int,
        within range: Range<Int>
    ) throws -> Range<Int> {
        guard count >= 0,
            offset >= range.lowerBound,
            offset <= range.upperBound,
            count <= range.upperBound - offset
        else {
            throw MutationError.malformedInitialization
        }
        return offset..<(offset + count)
    }
}

private enum DirectGenerationLeaseAttempt {
    case acquired(DeterministicFMP4Fixture.GenerationLeaseToken)
    case rejected(DeterministicFMP4Fixture.SegmentAssemblyError)
    case unexpected(String)
}

private actor TwoPartyStickyBarrier {
    private var arrivalCount = 0
    private var firstArrivalContinuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrivalCount += 1
        if arrivalCount == 2 {
            let continuation = firstArrivalContinuation
            firstArrivalContinuation = nil
            continuation?.resume()
            return
        }
        await withCheckedContinuation { continuation in
            if arrivalCount >= 2 {
                continuation.resume()
            } else {
                firstArrivalContinuation = continuation
            }
        }
    }
}

private final class FirstMediaHookEnteredLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func signalEntered() {
        condition.lock()
        entered = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilEntered(timeout: TimeInterval) -> Bool {
        condition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !entered, !released {
            if !condition.wait(until: deadline) { break }
        }
        let value = entered
        condition.unlock()
        return value
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class HeldFirstMediaWorkerGate: @unchecked Sendable {
    private enum Event: Equatable {
        case segment(Int)
        case writerDidFinish
        case workerClose(DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot)
        case hookAcknowledged(Int)
        case outputCommit
        case terminal(DeterministicFMP4Fixture.TerminalOutcome)
    }

    private let lock = NSLock()
    private let firstMediaHookEntered: FirstMediaHookEnteredLatch
    private let firstMediaHeld: XCTestExpectation
    private let writerDidFinish: XCTestExpectation?
    private let workerCloseRequested: XCTestExpectation
    private let heldHookAcknowledged: XCTestExpectation
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var heldOrdinal: Int?
    private var didSeeWriterFinish = false
    private var didSeeWorkerClose = false
    private var acknowledgedHeldHook = false
    private var segmentCountWhenCloseRequested = 0
    private var events: [Event] = []

    init(
        firstMediaHookEntered: FirstMediaHookEnteredLatch,
        firstMediaHeld: XCTestExpectation,
        writerDidFinish: XCTestExpectation? = nil,
        workerCloseRequested: XCTestExpectation,
        heldHookAcknowledged: XCTestExpectation
    ) {
        self.firstMediaHookEntered = firstMediaHookEntered
        self.firstMediaHeld = firstMediaHeld
        self.writerDidFinish = writerDidFinish
        self.workerCloseRequested = workerCloseRequested
        self.heldHookAcknowledged = heldHookAcknowledged
    }

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) async {
        switch event {
        case let .segmentCallbackDidStart(observation):
            let shouldHold = lock.withLock {
                events.append(.segment(observation.ordinal))
                let value = observation.kind == .media && heldOrdinal == nil
                if value { heldOrdinal = observation.ordinal }
                return value
            }
            guard shouldHold else { return }
            firstMediaHookEntered.signalEntered()
            firstMediaHeld.fulfill()
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if released { return true }
                    releaseContinuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }

        case .writerDidFinish:
            lock.withLock {
                didSeeWriterFinish = true
                events.append(.writerDidFinish)
            }
            writerDidFinish?.fulfill()

        case let .segmentWorkerCloseRequested(snapshot):
            lock.withLock {
                didSeeWorkerClose = true
                segmentCountWhenCloseRequested = events.reduce(0) {
                    count, event in
                    if case .segment = event { return count + 1 }
                    return count
                }
                events.append(.workerClose(snapshot))
            }
            workerCloseRequested.fulfill()

        case .outputDidCommitBeforeTerminalClaim:
            lock.withLock { events.append(.outputCommit) }

        case let .terminal(outcome):
            lock.withLock { events.append(.terminal(outcome)) }

        default:
            break
        }
    }

    func acknowledge(_ event: DeterministicFMP4Fixture.LifecycleEvent) {
        guard case let .segmentCallbackDidStart(observation) = event else { return }
        lock.lock()
        guard observation.ordinal == heldOrdinal, !acknowledgedHeldHook else {
            lock.unlock()
            return
        }
        acknowledgedHeldHook = true
        events.append(.hookAcknowledged(observation.ordinal))
        lock.unlock()
        heldHookAcknowledged.fulfill()
    }

    func releaseHeldMediaHook() {
        lock.lock()
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func firstMediaWasHeld() -> Bool {
        lock.lock()
        let value = heldOrdinal != nil
        lock.unlock()
        return value
    }

    func writerFinishWasSeen() -> Bool {
        lock.lock()
        let value = didSeeWriterFinish
        lock.unlock()
        return value
    }

    func workerCloseWasSeen() -> Bool {
        lock.lock()
        let value = didSeeWorkerClose
        lock.unlock()
        return value
    }

    func closeSnapshots()
        -> [DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot]
    {
        lock.lock()
        let values: [DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot] =
            events.compactMap { event in
            guard case let .workerClose(snapshot) = event else { return nil }
            return snapshot
        }
        lock.unlock()
        return values
    }

    func outputCommitCount() -> Int {
        lock.lock()
        let count = events.filter { $0 == .outputCommit }.count
        lock.unlock()
        return count
    }

    func terminalOutcomes() -> [DeterministicFMP4Fixture.TerminalOutcome] {
        lock.lock()
        let values: [DeterministicFMP4Fixture.TerminalOutcome] =
            events.compactMap { event in
            guard case let .terminal(outcome) = event else { return nil }
            return outcome
        }
        lock.unlock()
        return values
    }

    func terminalIsLastEvent() -> Bool {
        lock.lock()
        let value: Bool
        if let last = events.last, case .terminal = last {
            value = true
        } else {
            value = false
        }
        lock.unlock()
        return value
    }

    func segmentEventCount() -> Int {
        lock.lock()
        let count = events.reduce(0) { count, event in
            if case .segment = event { return count + 1 }
            return count
        }
        lock.unlock()
        return count
    }

    func segmentEventCountAtClose() -> Int {
        lock.lock()
        let value = segmentCountWhenCloseRequested
        lock.unlock()
        return value
    }
}

private final class TruncateSecondMediaSegmentPayload: @unchecked Sendable {
    private let lock = NSLock()
    private let firstMediaHookEntered: FirstMediaHookEnteredLatch
    private var mediaCount = 0
    private var truncatedSecond = false

    init(firstMediaHookEntered: FirstMediaHookEnteredLatch) {
        self.firstMediaHookEntered = firstMediaHookEntered
    }

    func transform(
        kind: DeterministicFMP4Fixture.SegmentKind,
        ordinal: Int,
        payload: Data
    ) throws -> Data {
        _ = ordinal
        guard kind == .media else { return payload }
        lock.lock()
        mediaCount += 1
        let shouldTruncate = mediaCount == 2
        lock.unlock()
        guard shouldTruncate else { return payload }
        guard firstMediaHookEntered.waitUntilEntered(timeout: 30) else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        lock.lock()
        truncatedSecond = true
        lock.unlock()
        return Data(payload.prefix(7))
    }

    func mediaTransformCount() -> Int {
        lock.lock()
        let value = mediaCount
        lock.unlock()
        return value
    }

    func didTruncateSecondMediaPayload() -> Bool {
        lock.lock()
        let value = truncatedSecond
        lock.unlock()
        return value
    }
}

private actor FixtureWriterLifecycleGate {
    private let writerDidStart: XCTestExpectation?
    private let holdWriter: Bool
    private let timeoutCancellationRequested: XCTestExpectation?
    private let terminalEntered: XCTestExpectation?
    private let holdTimedOutTerminal: Bool
    private var writerReleaseContinuation: CheckedContinuation<Void, Never>?
    private var timedOutTerminalContinuation: CheckedContinuation<Void, Never>?
    private var writerReleased = false
    private var timedOutTerminalReleased = false
    private var writerStartObserved = false
    private var outcomes: [DeterministicFMP4Fixture.TerminalOutcome] = []

    init(
        writerDidStart: XCTestExpectation? = nil,
        holdWriter: Bool = false,
        timeoutCancellationRequested: XCTestExpectation? = nil,
        terminalEntered: XCTestExpectation? = nil,
        holdTimedOutTerminal: Bool = false
    ) {
        self.writerDidStart = writerDidStart
        self.holdWriter = holdWriter
        self.timeoutCancellationRequested = timeoutCancellationRequested
        self.terminalEntered = terminalEntered
        self.holdTimedOutTerminal = holdTimedOutTerminal
    }

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) async {
        switch event {
        case .writerDidStart:
            writerStartObserved = true
            writerDidStart?.fulfill()
            guard holdWriter, !writerReleased else { return }
            await withCheckedContinuation { continuation in
                writerReleaseContinuation = continuation
            }
        case .timeoutCancellationRequested:
            timeoutCancellationRequested?.fulfill()
        case let .terminal(outcome):
            outcomes.append(outcome)
            terminalEntered?.fulfill()
            guard outcome == .timedOut,
                holdTimedOutTerminal,
                !timedOutTerminalReleased
            else { return }
            await withCheckedContinuation { continuation in
                timedOutTerminalContinuation = continuation
            }
        default:
            break
        }
    }

    func releaseWriter() {
        writerReleased = true
        let continuation = writerReleaseContinuation
        writerReleaseContinuation = nil
        continuation?.resume()
    }

    func writerDidStartWasObserved() -> Bool {
        writerStartObserved
    }

    func releaseTimedOutTerminal() {
        timedOutTerminalReleased = true
        let continuation = timedOutTerminalContinuation
        timedOutTerminalContinuation = nil
        continuation?.resume()
    }

    func terminalOutcomes() -> [DeterministicFMP4Fixture.TerminalOutcome] {
        outcomes
    }
}

private actor SuccessfulFixtureLifecycleRecorder {
    enum Event: Equatable {
        case writerDidStart
        case finishWritingDidStart
        case writerDidFinish
        case outputDidCommitBeforeTerminalClaim
        case completed
        case failed
        case workerClose(
            DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot
        )
    }

    private var recorded: [Event] = []

    func record(_ event: DeterministicFMP4Fixture.LifecycleEvent) {
        switch event {
        case .writerDidStart:
            recorded.append(.writerDidStart)
        case .finishWritingDidStart:
            recorded.append(.finishWritingDidStart)
        case .writerDidFinish:
            recorded.append(.writerDidFinish)
        case .outputDidCommitBeforeTerminalClaim:
            recorded.append(.outputDidCommitBeforeTerminalClaim)
        case .terminal(.completed):
            recorded.append(.completed)
        case .terminal:
            recorded.append(.failed)
        case .segmentCallbackDidStart:
            break
        case .segmentAssemblySealDidClaim:
            break
        case let .segmentWorkerCloseRequested(snapshot):
            recorded.append(.workerClose(snapshot))
        case .timeoutCancellationRequested, .writerCancellationRequested:
            break
        }
    }

    func events() -> [Event] {
        recorded
    }
}

private actor SegmentLifecycleRecorder {
    enum Event: Equatable {
        case segment(DeterministicFMP4Fixture.SegmentCallbackObservation)
        case writerDidFinish
        case segmentAssemblySealDidClaim
        case outputDidCommitBeforeTerminalClaim
        case terminal(DeterministicFMP4Fixture.TerminalOutcome)
    }

    private var recorded: [Event] = []

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) {
        switch event {
        case let .segmentCallbackDidStart(observation):
            recorded.append(.segment(observation))
        case .writerDidFinish:
            recorded.append(.writerDidFinish)
        case .segmentAssemblySealDidClaim:
            recorded.append(.segmentAssemblySealDidClaim)
        case .outputDidCommitBeforeTerminalClaim:
            recorded.append(.outputDidCommitBeforeTerminalClaim)
        case let .terminal(outcome):
            recorded.append(.terminal(outcome))
        default:
            break
        }
    }

    func events() -> [Event] {
        recorded
    }
}

private final class SealClaimLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private let sealClaimed: XCTestExpectation
    private let workerCloseRequested: XCTestExpectation?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var claimSeen = false
    private var outputCommits = 0
    private var outcomes: [DeterministicFMP4Fixture.TerminalOutcome] = []
    private var closeSnapshots: [
        DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot
    ] = []

    init(
        sealClaimed: XCTestExpectation,
        workerCloseRequested: XCTestExpectation? = nil
    ) {
        self.sealClaimed = sealClaimed
        self.workerCloseRequested = workerCloseRequested
    }

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) async {
        switch event {
        case .segmentAssemblySealDidClaim:
            lock.withLock { claimSeen = true }
            sealClaimed.fulfill()
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if released { return true }
                    releaseContinuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        case .outputDidCommitBeforeTerminalClaim:
            lock.withLock { outputCommits += 1 }
        case let .segmentWorkerCloseRequested(snapshot):
            lock.withLock { closeSnapshots.append(snapshot) }
            workerCloseRequested?.fulfill()
        case let .terminal(outcome):
            lock.withLock { outcomes.append(outcome) }
        default:
            break
        }
    }

    func releaseSealClaim() {
        lock.lock()
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func hasSeenSealClaim() -> Bool {
        lock.lock()
        let value = claimSeen
        lock.unlock()
        return value
    }

    func outputCommitCount() -> Int {
        lock.lock()
        let value = outputCommits
        lock.unlock()
        return value
    }

    func terminalOutcomes() -> [DeterministicFMP4Fixture.TerminalOutcome] {
        lock.lock()
        let value = outcomes
        lock.unlock()
        return value
    }

    func workerCloseSnapshots()
        -> [DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot]
    {
        lock.lock()
        let value = closeSnapshots
        lock.unlock()
        return value
    }
}

private actor EarlyWriterActivityRecorder {
    enum Activity: Equatable {
        case writerDidStart
        case finishWritingDidStart
        case segmentCallback
        case writerDidFinish
        case segmentAssemblySealDidClaim
        case outputDidCommit
        case writerCancellationRequested
        case segmentWorkerCloseRequested
    }

    private var recorded: [Activity] = []

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) {
        switch event {
        case .writerDidStart:
            recorded.append(.writerDidStart)
        case .finishWritingDidStart:
            recorded.append(.finishWritingDidStart)
        case .segmentCallbackDidStart:
            recorded.append(.segmentCallback)
        case .writerDidFinish:
            recorded.append(.writerDidFinish)
        case .segmentAssemblySealDidClaim:
            recorded.append(.segmentAssemblySealDidClaim)
        case .outputDidCommitBeforeTerminalClaim:
            recorded.append(.outputDidCommit)
        case .writerCancellationRequested:
            recorded.append(.writerCancellationRequested)
        case .segmentWorkerCloseRequested:
            recorded.append(.segmentWorkerCloseRequested)
        case .timeoutCancellationRequested, .terminal:
            break
        }
    }

    func activities() -> [Activity] {
        recorded
    }
}

private final class TimeoutWaiterInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func invocationCount() -> Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }
}

private actor OutputCommitLifecycleGate {
    private let outputCommitted: XCTestExpectation
    private let timeoutCancellationRequested: XCTestExpectation?
    private var outputReleaseContinuation: CheckedContinuation<Void, Never>?
    private var outputReleased = false
    private var outcomes: [DeterministicFMP4Fixture.TerminalOutcome] = []

    init(
        outputCommitted: XCTestExpectation,
        timeoutCancellationRequested: XCTestExpectation? = nil
    ) {
        self.outputCommitted = outputCommitted
        self.timeoutCancellationRequested = timeoutCancellationRequested
    }

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) async {
        switch event {
        case .outputDidCommitBeforeTerminalClaim:
            outputCommitted.fulfill()
            guard !outputReleased else { return }
            await withCheckedContinuation { continuation in
                outputReleaseContinuation = continuation
            }
        case .timeoutCancellationRequested:
            timeoutCancellationRequested?.fulfill()
        case let .terminal(outcome):
            outcomes.append(outcome)
        default:
            break
        }
    }

    func releaseCommittedOutput() {
        outputReleased = true
        let continuation = outputReleaseContinuation
        outputReleaseContinuation = nil
        continuation?.resume()
    }

    func terminalOutcomes() -> [DeterministicFMP4Fixture.TerminalOutcome] {
        outcomes
    }
}

private actor TerminalLifecycleRecorder {
    private var outcomes: [DeterministicFMP4Fixture.TerminalOutcome] = []

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) {
        if case let .terminal(outcome) = event {
            outcomes.append(outcome)
        }
    }

    func terminalOutcomes() -> [DeterministicFMP4Fixture.TerminalOutcome] {
        outcomes
    }
}

private actor FinishWritingLifecycleGate {
    private let finishWritingDidStart: XCTestExpectation
    private let timeoutCancellationRequested: XCTestExpectation?
    private let writerCancellationRequested: XCTestExpectation
    private var outcomes: [DeterministicFMP4Fixture.TerminalOutcome] = []

    init(
        finishWritingDidStart: XCTestExpectation,
        timeoutCancellationRequested: XCTestExpectation? = nil,
        writerCancellationRequested: XCTestExpectation
    ) {
        self.finishWritingDidStart = finishWritingDidStart
        self.timeoutCancellationRequested = timeoutCancellationRequested
        self.writerCancellationRequested = writerCancellationRequested
    }

    func handle(_ event: DeterministicFMP4Fixture.LifecycleEvent) {
        switch event {
        case .finishWritingDidStart:
            finishWritingDidStart.fulfill()
        case .timeoutCancellationRequested:
            timeoutCancellationRequested?.fulfill()
        case .writerCancellationRequested:
            writerCancellationRequested.fulfill()
        case let .terminal(outcome):
            outcomes.append(outcome)
        default:
            break
        }
    }

    func terminalOutcomes() -> [DeterministicFMP4Fixture.TerminalOutcome] {
        outcomes
    }
}

private final class StickyNoncooperativeTimeoutWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let started: XCTestExpectation
    private let cancellationObserved: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var recordedCancellation = false

    init(
        started: XCTestExpectation,
        cancellationObserved: XCTestExpectation
    ) {
        self.started = started
        self.cancellationObserved = cancellationObserved
    }

    func wait() async {
        started.fulfill()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            recordCancellationWithoutReleasing()
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func isReleased() -> Bool {
        lock.lock()
        let value = released
        lock.unlock()
        return value
    }

    private func recordCancellationWithoutReleasing() {
        lock.lock()
        guard !recordedCancellation else {
            lock.unlock()
            return
        }
        recordedCancellation = true
        lock.unlock()
        cancellationObserved.fulfill()
    }
}

private final class StickyFinishWritingStarter: @unchecked Sendable {
    private let lock = NSLock()
    private let normalFinishCaptured: XCTestExpectation
    private var heldCompletion: (() -> Void)?
    private var lateInvocationCount = 0

    init(normalFinishCaptured: XCTestExpectation) {
        self.normalFinishCaptured = normalFinishCaptured
    }

    func start(
        writer: AVAssetWriter,
        completion: @escaping () -> Void
    ) {
        _ = writer
        lock.lock()
        heldCompletion = completion
        lock.unlock()
        normalFinishCaptured.fulfill()
    }

    @discardableResult
    func invokeLateCompletion() -> Int {
        lock.lock()
        let completion = heldCompletion
        heldCompletion = nil
        if completion != nil {
            lateInvocationCount += 1
        }
        let count = lateInvocationCount
        lock.unlock()
        completion?()
        return count
    }
}

private enum PostSuccessSegmentIngressKind: CaseIterable, Sendable {
    case separable
    case unknown

    var name: String {
        switch self {
        case .separable: "separable"
        case .unknown: "unknown"
        }
    }

    func invoke(writer: AVAssetWriter, payload: Data) throws {
        _ = try XCTUnwrap(writer.delegate)
        switch self {
        case .separable:
            writer.delegate?.assetWriter?(
                writer,
                didOutputSegmentData: payload,
                segmentType: .separable
            )
        case .unknown:
            let unknown = try XCTUnwrap(AVAssetSegmentType(rawValue: 999))
            writer.delegate?.assetWriter?(
                writer,
                didOutputSegmentData: payload,
                segmentType: unknown
            )
        }
    }
}

private final class CapturingFinishWritingStarter: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var delegate: (any AVAssetWriterDelegate)?

    func start(
        writer: AVAssetWriter,
        completion: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        self.writer = writer
        delegate = writer.delegate
        lock.unlock()
        writer.finishWriting(completionHandler: completion)
    }

    func capturedWriter() -> AVAssetWriter? {
        lock.lock()
        let value = writer
        lock.unlock()
        return value
    }

    func hasCapturedDelegate() -> Bool {
        lock.lock()
        let value = delegate != nil
        lock.unlock()
        return value
    }

    func releaseCapturedObjects() {
        lock.lock()
        writer = nil
        delegate = nil
        lock.unlock()
    }
}

private final class ImmediateSecondMediaSegmentTruncator: @unchecked Sendable {
    private let lock = NSLock()
    private var mediaCount = 0

    func transform(
        kind: DeterministicFMP4Fixture.SegmentKind,
        ordinal: Int,
        payload: Data
    ) -> Data {
        _ = ordinal
        guard kind == .media else { return payload }
        lock.lock()
        mediaCount += 1
        let shouldTruncate = mediaCount == 2
        lock.unlock()
        return shouldTruncate ? Data(payload.prefix(7)) : payload
    }

    func mediaTransformCount() -> Int {
        lock.lock()
        let value = mediaCount
        lock.unlock()
        return value
    }
}

private final class SynchronousWorkerCloseObserver: @unchecked Sendable {
    struct Observation {
        let snapshot: DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot
        let gateIdentifier: ObjectIdentifier
        let gateWasInvalid: Bool
        let writerCancellationWasRequested: Bool
        let gateWasReady: Bool
        let generationLeaseWasActive: Bool
    }

    private let condition = NSCondition()
    private let observed: XCTestExpectation
    private var values: [Observation] = []
    private var released = false

    init(observed: XCTestExpectation) {
        self.observed = observed
    }

    func observe(
        _ snapshot: DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot,
        gate: DeterministicFMP4Fixture.SegmentAssemblyGate
    ) {
        let value = Observation(
            snapshot: snapshot,
            gateIdentifier: ObjectIdentifier(gate),
            gateWasInvalid: gate.isInvalid,
            writerCancellationWasRequested: gate.writerCancellationRequested,
            gateWasReady: gate.isReadyForAssembly,
            generationLeaseWasActive: gate.hasActiveGenerationLease
        )
        condition.lock()
        let isFirst = values.isEmpty
        values.append(value)
        if isFirst { observed.fulfill() }
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func observations() -> [Observation] {
        condition.lock()
        let value = values
        condition.unlock()
        return value
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor InjectedFixtureTimeoutSignal {
    private var triggered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !triggered else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func trigger() {
        triggered = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor GenerationCompletionProbe {
    private var complete = false

    func markComplete() {
        complete = true
    }

    func isComplete() -> Bool {
        complete
    }
}

private struct IndependentToneRegion: Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let frequencyHz: Double
}

private struct IndependentToneObservation: Sendable {
    let estimatedFrequencyHz: Double
    let rmsDecibels: Double
    let peakDecibels: Double
    let expectedToneSeparationDecibels: Double
}

private struct IndependentMediaFragment: Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double

    var durationSeconds: Double { endSeconds - startSeconds }
}

private struct IndependentFixtureInspection: Sendable {
    let payloadSHA256: String
    let contentLength: Int64
    let totalTrackCount: Int
    let audioTrackCount: Int
    let formatID: AudioFormatID
    let audioObjectType: Int
    let sampleRate: Double
    let channelCount: Int
    let durationSeconds: Double
    let mediaDurationSeconds: Double
    let editListPresentationDurationSeconds: Double
    let presentationMediaStartFrame: Int64
    let strictlyIncreasingContinuousPTS: Bool
    let firstDecodedSampleStartSeconds: Double
    let lastDecodedSampleEndSeconds: Double
    let hasCanonicalTopLevelOrder: Bool
    let containerLayoutProfile: String
    let fragments: [IndependentMediaFragment]
    let hasFinalZeroCoveredPadding: Bool
    let measuredFragmentCadenceSeconds: Double
    let initializationRange: Range<Int64>
    let indexRange: Range<Int64>?
    let payloadBitrateBitsPerSecond: Double
    let toneWindows: [IndependentToneObservation]
}

private struct IndependentAACFixtureProfile: Equatable, Sendable {
    let audioObjectType: Int
    let sampleRate: Int
    let channelConfiguration: Int
    let frameLengthFlag: Bool
    let dependsOnCoreCoder: Bool
    let extensionFlag: Bool
}

private struct DecoderConfigObservation: Equatable, Sendable {
    let esFlags: UInt8
    let decoderPayloadByteCount: Int
    let objectTypeIndication: UInt8
    let packedStreamTypeByte: UInt8
    let streamType: UInt8
    let upstream: Bool
    let reserved: Bool
    let fixedHeaderHex: String
    let decoderSpecificInfoByteCount: Int
    let decoderSpecificInfoHex: String
}

private enum IndependentAudioESDSParser {
    private struct Box {
        let type: String
        let payloadRange: Range<Int>
    }

    private struct Descriptor {
        let tag: UInt8
        let payloadRange: Range<Int>
    }

    static func audioSpecificConfig(in initialization: Data) throws -> Data {
        let descriptor = try esDescriptor(in: initialization)
        return try decoderSpecificInfo(from: descriptor, data: initialization)
    }

    static func decoderConfigObservation(
        in initialization: Data
    ) throws -> DecoderConfigObservation {
        let descriptor = try esDescriptor(in: initialization)
        let context = try esChildContext(
            from: descriptor,
            data: initialization
        )
        let decoderConfigurations = context.children.filter {
            $0.tag == 0x04
        }
        guard decoderConfigurations.count == 1,
            let decoder = decoderConfigurations.first,
            decoder.payloadRange.count >= 2
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        let objectTypeIndication = try uint8(
            initialization,
            at: decoder.payloadRange.lowerBound,
            within: decoder.payloadRange
        )
        let packedStreamTypeByte = try uint8(
            initialization,
            at: decoder.payloadRange.lowerBound + 1,
            within: decoder.payloadRange
        )
        let fixedHeaderByteCount = min(13, decoder.payloadRange.count)
        let fixedHeaderEnd = try advanced(
            decoder.payloadRange.lowerBound,
            by: fixedHeaderByteCount,
            within: decoder.payloadRange
        )
        let fixedHeaderHex = initialization[
            decoder.payloadRange.lowerBound..<fixedHeaderEnd
        ].map { String(format: "%02x", $0) }.joined()
        let decoderChildrenStart = try advanced(
            decoder.payloadRange.lowerBound,
            by: 13,
            within: decoder.payloadRange
        )
        let decoderChildren = try descriptors(
            in: initialization,
            range: decoderChildrenStart..<decoder.payloadRange.upperBound
        )
        let specificInfos = decoderChildren.filter { $0.tag == 0x05 }
        guard specificInfos.count == 1,
            let specificInfo = specificInfos.first,
            specificInfo.payloadRange.count > 0,
            specificInfo.payloadRange.count <= 64
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        let decoderSpecificInfo = initialization[specificInfo.payloadRange]
        return DecoderConfigObservation(
            esFlags: context.flags,
            decoderPayloadByteCount: decoder.payloadRange.count,
            objectTypeIndication: objectTypeIndication,
            packedStreamTypeByte: packedStreamTypeByte,
            streamType: packedStreamTypeByte >> 2,
            upstream: packedStreamTypeByte & 0x02 != 0,
            reserved: packedStreamTypeByte & 0x01 != 0,
            fixedHeaderHex: fixedHeaderHex,
            decoderSpecificInfoByteCount: decoderSpecificInfo.count,
            decoderSpecificInfoHex: decoderSpecificInfo.map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func esDescriptor(in initialization: Data) throws -> Descriptor {
        let topLevel = try boxes(
            in: initialization,
            range: initialization.startIndex..<initialization.endIndex
        )
        let movies = topLevel.filter { $0.type == "moov" }
        guard movies.count == 1, let movie = movies.first else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        var audioSampleDescriptions: [Box] = []
        for track in try children(of: movie, data: initialization)
            where track.type == "trak"
        {
            let mediaBoxes = try children(of: track, data: initialization)
                .filter { $0.type == "mdia" }
            guard mediaBoxes.count == 1, let media = mediaBoxes.first else {
                continue
            }
            let mediaChildren = try children(of: media, data: initialization)
            let handlers = mediaChildren.filter { $0.type == "hdlr" }
            guard handlers.count == 1, let handler = handlers.first,
                try fullBoxWord(handler, data: initialization) == 0,
                try ascii(
                    initialization,
                    at: handler.payloadRange.lowerBound + 8,
                    count: 4,
                    within: handler.payloadRange
                ) == "soun"
            else {
                continue
            }
            let mediaInformation = mediaChildren.filter { $0.type == "minf" }
            guard mediaInformation.count == 1,
                let minf = mediaInformation.first
            else {
                throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
            }
            let sampleTables = try children(of: minf, data: initialization)
                .filter { $0.type == "stbl" }
            guard sampleTables.count == 1, let stbl = sampleTables.first else {
                throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
            }
            let descriptions = try children(of: stbl, data: initialization)
                .filter { $0.type == "stsd" }
            guard descriptions.count == 1, let stsd = descriptions.first else {
                throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
            }
            audioSampleDescriptions.append(stsd)
        }
        guard audioSampleDescriptions.count == 1,
            let stsd = audioSampleDescriptions.first,
            try fullBoxWord(stsd, data: initialization) == 0
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        let entryCount = try uint32(
            initialization,
            at: stsd.payloadRange.lowerBound + 4,
            within: stsd.payloadRange
        )
        let entriesStart = try advanced(
            stsd.payloadRange.lowerBound + 8,
            by: 0,
            within: stsd.payloadRange
        )
        let entries = try boxes(
            in: initialization,
            range: entriesStart..<stsd.payloadRange.upperBound
        )
        guard entryCount == 1,
            entries.count == 1,
            UInt64(entryCount) == UInt64(entries.count),
            entries.first?.type == "mp4a"
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        let audioEntries = entries.filter { $0.type == "mp4a" }
        guard audioEntries.count == 1, let mp4a = audioEntries.first,
            try uint16(
                initialization,
                at: mp4a.payloadRange.lowerBound + 6,
                within: mp4a.payloadRange
            ) > 0,
            try uint16(
                initialization,
                at: mp4a.payloadRange.lowerBound + 8,
                within: mp4a.payloadRange
            ) == 0
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        let sampleEntryChildrenStart = try advanced(
            mp4a.payloadRange.lowerBound,
            by: 28,
            within: mp4a.payloadRange
        )
        let sampleEntryChildren = try boxes(
            in: initialization,
            range: sampleEntryChildrenStart..<mp4a.payloadRange.upperBound
        )
        let elementaryStreamBoxes = sampleEntryChildren.filter {
            $0.type == "esds"
        }
        guard elementaryStreamBoxes.count == 1,
            let esds = elementaryStreamBoxes.first,
            try fullBoxWord(esds, data: initialization) == 0
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        let descriptorStart = try advanced(
            esds.payloadRange.lowerBound,
            by: 4,
            within: esds.payloadRange
        )
        let topDescriptors = try descriptors(
            in: initialization,
            range: descriptorStart..<esds.payloadRange.upperBound
        )
        guard topDescriptors.count == 1,
            let esDescriptor = topDescriptors.first,
            esDescriptor.tag == 0x03
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        return esDescriptor
    }

    private static func decoderSpecificInfo(
        from esDescriptor: Descriptor,
        data: Data
    ) throws -> Data {
        let context = try esChildContext(from: esDescriptor, data: data)
        let children = context.children
        guard children.count == 2,
            let decoder = children.first,
            decoder.tag == 0x04,
            let slConfig = children.last,
            slConfig.tag == 0x06,
            Data(data[slConfig.payloadRange]) == Data([0x02])
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        var decoderCursor = decoder.payloadRange.lowerBound
        guard try uint8(data, at: decoderCursor, within: decoder.payloadRange)
            == 0x40
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        decoderCursor = try advanced(decoderCursor, by: 1, within: decoder.payloadRange)
        let streamType = try uint8(
            data,
            at: decoderCursor,
            within: decoder.payloadRange
        )
        let decodedStreamType = streamType >> 2
        let upstream = streamType & 0x02 != 0
        guard decodedStreamType == 0x05, !upstream else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        decoderCursor = try advanced(decoderCursor, by: 12, within: decoder.payloadRange)
        let decoderChildren = try descriptors(
            in: data,
            range: decoderCursor..<decoder.payloadRange.upperBound
        )
        let specificInfos = decoderChildren.filter { $0.tag == 0x05 }
        guard specificInfos.count == 1, let specificInfo = specificInfos.first,
            specificInfo.payloadRange.count >= 2,
            specificInfo.payloadRange.count <= 64
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        return Data(data[specificInfo.payloadRange])
    }

    private static func esChildContext(
        from esDescriptor: Descriptor,
        data: Data
    ) throws -> (flags: UInt8, children: [Descriptor]) {
        var cursor = esDescriptor.payloadRange.lowerBound
        cursor = try advanced(cursor, by: 2, within: esDescriptor.payloadRange)
        let flags = try uint8(data, at: cursor, within: esDescriptor.payloadRange)
        cursor = try advanced(cursor, by: 1, within: esDescriptor.payloadRange)
        if flags & 0x80 != 0 {
            cursor = try advanced(cursor, by: 2, within: esDescriptor.payloadRange)
        }
        if flags & 0x40 != 0 {
            let urlLength = Int(
                try uint8(data, at: cursor, within: esDescriptor.payloadRange)
            )
            cursor = try advanced(cursor, by: 1, within: esDescriptor.payloadRange)
            cursor = try advanced(cursor, by: urlLength, within: esDescriptor.payloadRange)
        }
        if flags & 0x20 != 0 {
            cursor = try advanced(cursor, by: 2, within: esDescriptor.payloadRange)
        }
        let children = try descriptors(
            in: data,
            range: cursor..<esDescriptor.payloadRange.upperBound
        )
        return (flags, children)
    }

    private static func descriptors(
        in data: Data,
        range: Range<Int>
    ) throws -> [Descriptor] {
        var result: [Descriptor] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let tag = try uint8(data, at: cursor, within: range)
            cursor = try advanced(cursor, by: 1, within: range)
            var length = 0
            var terminated = false
            for byteIndex in 0..<4 {
                let byte = try uint8(data, at: cursor, within: range)
                cursor = try advanced(cursor, by: 1, within: range)
                let (scaled, scaleOverflow) = length
                    .multipliedReportingOverflow(by: 128)
                let (next, additionOverflow) = scaled
                    .addingReportingOverflow(Int(byte & 0x7F))
                guard !scaleOverflow, !additionOverflow else {
                    throw IndependentFixtureOracleError
                        .invalidElementaryStreamDescriptor
                }
                length = next
                if byte & 0x80 == 0 {
                    terminated = true
                    break
                }
                guard byteIndex < 3 else {
                    throw IndependentFixtureOracleError
                        .invalidElementaryStreamDescriptor
                }
            }
            guard terminated else {
                throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
            }
            let payloadEnd = try advanced(cursor, by: length, within: range)
            result.append(
                Descriptor(tag: tag, payloadRange: cursor..<payloadEnd)
            )
            cursor = payloadEnd
        }
        return result
    }

    private static func children(of box: Box, data: Data) throws -> [Box] {
        try boxes(in: data, range: box.payloadRange)
    }

    private static func boxes(in data: Data, range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard range.upperBound - cursor >= 8 else {
                throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
            }
            let compactSize = UInt64(
                try uint32(data, at: cursor, within: range)
            )
            let type = try ascii(
                data,
                at: cursor + 4,
                count: 4,
                within: range
            )
            let headerSize: Int
            let size: UInt64
            switch compactSize {
            case 0:
                headerSize = 8
                size = UInt64(range.upperBound - cursor)
            case 1:
                headerSize = 16
                size = try uint64(data, at: cursor + 8, within: range)
            default:
                headerSize = 8
                size = compactSize
            }
            guard size >= UInt64(headerSize),
                size <= UInt64(range.upperBound - cursor),
                size <= UInt64(Int.max)
            else {
                throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
            }
            let end = cursor + Int(size)
            result.append(
                Box(type: type, payloadRange: (cursor + headerSize)..<end)
            )
            cursor = end
        }
        return result
    }

    private static func fullBoxWord(_ box: Box, data: Data) throws -> UInt32 {
        try uint32(
            data,
            at: box.payloadRange.lowerBound,
            within: box.payloadRange
        )
    }

    private static func ascii(
        _ data: Data,
        at offset: Int,
        count: Int,
        within range: Range<Int>
    ) throws -> String {
        let bytes = try slice(data, at: offset, count: count, within: range)
        guard let value = String(data: bytes, encoding: .ascii) else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        return value
    }

    private static func uint8(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt8 {
        let bytes = try slice(data, at: offset, count: 1, within: range)
        guard let value = bytes.first else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        return value
    }

    private static func uint16(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt16 {
        try slice(data, at: offset, count: 2, within: range)
            .reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    private static func uint32(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt32 {
        try slice(data, at: offset, count: 4, within: range)
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt64 {
        try slice(data, at: offset, count: 8, within: range)
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func slice(
        _ data: Data,
        at offset: Int,
        count: Int,
        within range: Range<Int>
    ) throws -> Data.SubSequence {
        let end = try advanced(offset, by: count, within: range)
        return data[offset..<end]
    }

    private static func advanced(
        _ offset: Int,
        by count: Int,
        within range: Range<Int>
    ) throws -> Int {
        guard count >= 0,
            offset >= range.lowerBound,
            offset <= range.upperBound,
            count <= range.upperBound - offset
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        return offset + count
    }
}

private enum IndependentAudioSpecificConfigParser {
    private static let indexedSampleRates = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
        22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    static func fixtureProfile(
        in data: Data
    ) throws -> IndependentAACFixtureProfile {
        guard data.count >= 2, data.count <= 64 else {
            throw IndependentFixtureOracleError.invalidAudioSpecificConfig
        }
        var reader = BoundedBitReader(data: data)
        var objectType = try reader.readBits(count: 5)
        if objectType == 31 {
            objectType = 32 + (try reader.readBits(count: 6))
        }
        guard objectType == 2 else {
            throw IndependentFixtureOracleError.invalidAudioSpecificConfig
        }
        let samplingFrequencyIndex = try reader.readBits(count: 4)
        let sampleRate: UInt32
        switch samplingFrequencyIndex {
        case 0...12:
            guard indexedSampleRates.indices.contains(
                Int(samplingFrequencyIndex)
            ) else {
                throw IndependentFixtureOracleError.invalidAudioSpecificConfig
            }
            sampleRate = UInt32(
                indexedSampleRates[Int(samplingFrequencyIndex)]
            )
        case 15:
            sampleRate = try reader.readBits(count: 24)
            guard sampleRate > 0 else {
                throw IndependentFixtureOracleError.invalidAudioSpecificConfig
            }
        default:
            throw IndependentFixtureOracleError.invalidAudioSpecificConfig
        }
        let channelConfiguration = try reader.readBits(count: 4)
        let frameLengthFlag = try reader.readBits(count: 1) == 1
        let dependsOnCoreCoder = try reader.readBits(count: 1) == 1
        if dependsOnCoreCoder {
            _ = try reader.readBits(count: 14)
        }
        let extensionFlag = try reader.readBits(count: 1) == 1
        guard sampleRate == 48_000,
            channelConfiguration == 1,
            !frameLengthFlag,
            !dependsOnCoreCoder,
            !extensionFlag,
            reader.remainingBitsAreZero()
        else {
            throw IndependentFixtureOracleError.invalidAudioSpecificConfig
        }
        return IndependentAACFixtureProfile(
            audioObjectType: Int(objectType),
            sampleRate: Int(sampleRate),
            channelConfiguration: Int(channelConfiguration),
            frameLengthFlag: frameLengthFlag,
            dependsOnCoreCoder: dependsOnCoreCoder,
            extensionFlag: extensionFlag
        )
    }

    private struct BoundedBitReader {
        let data: Data
        private(set) var bitOffset = 0

        mutating func readBits(count: Int) throws -> UInt32 {
            guard count > 0, count <= 32 else {
                throw IndependentFixtureOracleError.invalidAudioSpecificConfig
            }
            let (totalBitCount, sizeOverflow) = data.count
                .multipliedReportingOverflow(by: 8)
            let (endBit, offsetOverflow) = bitOffset
                .addingReportingOverflow(count)
            guard !sizeOverflow,
                !offsetOverflow,
                endBit <= totalBitCount
            else {
                throw IndependentFixtureOracleError.invalidAudioSpecificConfig
            }
            var value: UInt32 = 0
            while bitOffset < endBit {
                let byteOffset = bitOffset / 8
                guard byteOffset < data.count else {
                    throw IndependentFixtureOracleError.invalidAudioSpecificConfig
                }
                let index = data.index(data.startIndex, offsetBy: byteOffset)
                let bitInByte = 7 - (bitOffset % 8)
                value = (value << 1)
                    | UInt32((data[index] >> bitInByte) & 1)
                bitOffset += 1
            }
            return value
        }

        func remainingBitsAreZero() -> Bool {
            let totalBitCount = data.count * 8
            guard bitOffset <= totalBitCount else { return false }
            for offset in bitOffset..<totalBitCount {
                let byteOffset = offset / 8
                guard byteOffset < data.count else { return false }
                let index = data.index(data.startIndex, offsetBy: byteOffset)
                let bitInByte = 7 - (offset % 8)
                if ((data[index] >> bitInByte) & 1) != 0 { return false }
            }
            return true
        }
    }
}

private enum InspectorStage: String, Equatable, Sendable {
    case iso
    case assetTracks
    case audioTracks
    case formatDescriptions
    case esdsASC
    case duration
    case readerCreateStart
    case readerDecodeDrain
}

private final class InspectorStageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [InspectorStage] = []

    func record(_ stage: InspectorStage) {
        lock.lock()
        recorded.append(stage)
        lock.unlock()
    }

    func stages() -> [InspectorStage] {
        lock.lock()
        let value = recorded
        lock.unlock()
        return value
    }

    func failureContext() -> String {
        let value = stages()
        let last = value.last?.rawValue ?? "none"
        return "lastStage=\(last), stages=\(value.map(\.rawValue))"
    }
}

private enum IndependentFixtureInspector {
    static func inspect(
        url: URL,
        expectedPresentationDurationSeconds: Double,
        expectedToneRegions: [IndependentToneRegion],
        stageObserver: (@Sendable (InspectorStage) -> Void)? = nil
    ) async throws -> IndependentFixtureInspection {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        stageObserver?(.iso)
        let iso = try IndependentISOParser.inspectFragmentedAudio(
            data,
            expectedPresentationDurationSeconds: expectedPresentationDurationSeconds
        )
        guard iso.presentationMediaStartTicks <= UInt64(Int64.max) else {
            throw IndependentFixtureOracleError.integerOverflow
        }
        let asset = AVURLAsset(url: url)
        stageObserver?(.assetTracks)
        let allTracks = try await asset.load(.tracks)
        stageObserver?(.audioTracks)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 1, let track = audioTracks.first else {
            throw IndependentFixtureOracleError.invalidAudioTrackCount(audioTracks.count)
        }
        stageObserver?(.formatDescriptions)
        let descriptions = try await track.load(.formatDescriptions)
        guard
            descriptions.count == 1,
            let description = descriptions.first,
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            throw IndependentFixtureOracleError.invalidFormatDescription
        }
        let asbd = streamDescription.pointee
        stageObserver?(.esdsASC)
        guard iso.initializationRange.lowerBound >= 0,
            iso.initializationRange.upperBound <= Int64(data.count),
            iso.initializationRange.lowerBound <= Int64(Int.max),
            iso.initializationRange.upperBound <= Int64(Int.max)
        else {
            throw IndependentFixtureOracleError.invalidElementaryStreamDescriptor
        }
        let initializationRange = Int(iso.initializationRange.lowerBound)
            ..< Int(iso.initializationRange.upperBound)
        let audioSpecificConfig = try IndependentAudioESDSParser
            .audioSpecificConfig(
                in: Data(data[initializationRange])
            )
        let audioProfile = try IndependentAudioSpecificConfigParser
            .fixtureProfile(in: audioSpecificConfig)
        let presentationStartFrames = Double(iso.presentationMediaStartTicks)
            * asbd.mSampleRate
            / Double(iso.mediaTimescale)
        guard presentationStartFrames.isFinite,
            presentationStartFrames >= 0,
            presentationStartFrames <= Double(Int64.max)
        else {
            throw IndependentFixtureOracleError.integerOverflow
        }
        let presentationMediaStartFrame = Int64(
            presentationStartFrames.rounded()
        )
        stageObserver?(.duration)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw IndependentFixtureOracleError.invalidDuration
        }

        stageObserver?(.readerCreateStart)
        let decoded = try decodePCM(
            asset: asset,
            track: track,
            sampleRate: asbd.mSampleRate,
            expectedToneRegions: expectedToneRegions,
            readerDidStart: { stageObserver?(.readerDecodeDrain) }
        )
        let fixtureFrequencies = expectedToneRegions.map(\.frequencyHz)
        guard decoded.windows.count == expectedToneRegions.count else {
            throw IndependentFixtureOracleError.incompleteToneWindow
        }
        let observations = try zip(decoded.windows, expectedToneRegions).map {
            samples, region in
            let expected = region.frequencyHz
            return try IndependentToneEstimator.inspect(
                samples: samples,
                sampleRate: asbd.mSampleRate,
                expectedFrequencyHz: expected,
                otherFixtureFrequenciesHz: fixtureFrequencies.filter { $0 != expected }
            )
        }
        let measuredFragmentCadenceSeconds = measuredPresentationFragmentCadence(
            fragments: iso.fragments,
            hasFinalZeroCoveredPadding: iso.hasFinalZeroCoveredPadding,
            mediaTimescale: iso.mediaTimescale,
            fallbackPresentationDurationSeconds:
                iso.editListPresentationDurationSeconds
        )

        return IndependentFixtureInspection(
            payloadSHA256: sha256Hex(data),
            contentLength: Int64(data.count),
            totalTrackCount: allTracks.count,
            audioTrackCount: audioTracks.count,
            formatID: asbd.mFormatID,
            audioObjectType: audioProfile.audioObjectType,
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            durationSeconds: durationSeconds,
            mediaDurationSeconds: Double(iso.mediaDurationTicks)
                / Double(iso.mediaTimescale),
            editListPresentationDurationSeconds: iso.editListPresentationDurationSeconds,
            presentationMediaStartFrame: presentationMediaStartFrame,
            strictlyIncreasingContinuousPTS: decoded.strictlyIncreasingContinuousPTS,
            firstDecodedSampleStartSeconds: decoded.firstSampleStartSeconds,
            lastDecodedSampleEndSeconds: decoded.lastSampleEndSeconds,
            hasCanonicalTopLevelOrder: iso.hasCanonicalTopLevelOrder,
            containerLayoutProfile: iso.containerLayoutProfile,
            fragments: iso.fragments.map {
                IndependentMediaFragment(
                    startSeconds: Double($0.startTicks) / Double(iso.mediaTimescale),
                    endSeconds: Double($0.endTicks) / Double(iso.mediaTimescale)
                )
            },
            hasFinalZeroCoveredPadding: iso.hasFinalZeroCoveredPadding,
            measuredFragmentCadenceSeconds: measuredFragmentCadenceSeconds,
            initializationRange: iso.initializationRange,
            indexRange: iso.indexRange,
            payloadBitrateBitsPerSecond: Double(iso.mediaPayloadBytes * 8)
                / durationSeconds,
            toneWindows: observations
        )
    }

    private static func decodePCM(
        asset: AVAsset,
        track: AVAssetTrack,
        sampleRate: Double,
        expectedToneRegions: [IndependentToneRegion],
        readerDidStart: @Sendable () -> Void = {}
    ) throws -> IndependentDecodedPCM {
        let reader = try AVAssetReader(asset: asset)
        defer {
            switch reader.status {
            case .unknown, .reading:
                reader.cancelReading()
            case .completed, .failed, .cancelled:
                break
            @unknown default:
                reader.cancelReading()
            }
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw IndependentFixtureOracleError.cannotAddReaderOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? IndependentFixtureOracleError.readerFailed
        }
        readerDidStart()

        var windows = Array(repeating: [Float](), count: expectedToneRegions.count)
        var previousStartSeconds: Double?
        var previousEndSeconds: Double?
        var firstStartSeconds: Double?
        var strictlyIncreasingContinuousPTS = true

        while true {
            do {
                try Task.checkCancellation()
            } catch {
                reader.cancelReading()
                throw error
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            let ptsSeconds = CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            guard ptsSeconds.isFinite else {
                throw IndependentFixtureOracleError.invalidSamplePTS
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw IndependentFixtureOracleError.missingSampleData
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Int16>.size) else {
                throw IndependentFixtureOracleError.invalidSampleDataLength
            }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let copyStatus = bytes.withUnsafeMutableBytes { destination -> OSStatus in
                guard let baseAddress = destination.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: baseAddress
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw IndependentFixtureOracleError.sampleCopyFailed(copyStatus)
            }
            let availableSampleCount = byteCount / MemoryLayout<Int16>.size
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0, frameCount <= availableSampleCount else {
                throw IndependentFixtureOracleError.truncatedSampleData
            }
            let endSeconds = ptsSeconds + Double(frameCount) / sampleRate
            if let previousStartSeconds, ptsSeconds <= previousStartSeconds {
                strictlyIncreasingContinuousPTS = false
            }
            if let previousEndSeconds {
                let delta = ptsSeconds - previousEndSeconds
                if delta < -(1 / sampleRate) || delta > 1_024 / sampleRate {
                    strictlyIncreasingContinuousPTS = false
                }
            }
            firstStartSeconds = firstStartSeconds ?? ptsSeconds
            previousStartSeconds = ptsSeconds
            previousEndSeconds = endSeconds

            for frameIndex in 0..<frameCount {
                let (byteIndex, overflow) = frameIndex.multipliedReportingOverflow(by: 2)
                guard !overflow,
                    bytes.indices.contains(byteIndex),
                    bytes.indices.contains(byteIndex + 1)
                else { throw IndependentFixtureOracleError.truncatedSampleData }
                let sampleBits = UInt16(bytes[byteIndex])
                    | (UInt16(bytes[byteIndex + 1]) << 8)
                let sample = Int16(bitPattern: sampleBits)
                let sampleTime = ptsSeconds + Double(frameIndex) / sampleRate
                for regionIndex in expectedToneRegions.indices {
                    let region = expectedToneRegions[regionIndex]
                    let midpoint = (region.startSeconds + region.endSeconds) / 2
                    if sampleTime >= midpoint - 0.25, sampleTime < midpoint + 0.25 {
                        windows[regionIndex].append(Float(sample) / 32_768)
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else {
            throw reader.error ?? IndependentFixtureOracleError.readerFailed
        }
        guard let firstStartSeconds, let lastEndSeconds = previousEndSeconds else {
            throw IndependentFixtureOracleError.missingSampleData
        }
        guard windows.allSatisfy({ $0.count >= Int(sampleRate * 0.49) }) else {
            throw IndependentFixtureOracleError.incompleteToneWindow
        }
        return IndependentDecodedPCM(
            windows: windows,
            strictlyIncreasingContinuousPTS: strictlyIncreasingContinuousPTS,
            firstSampleStartSeconds: firstStartSeconds,
            lastSampleEndSeconds: lastEndSeconds
        )
    }
}

private struct IndependentDecodedPCM {
    let windows: [[Float]]
    let strictlyIncreasingContinuousPTS: Bool
    let firstSampleStartSeconds: Double
    let lastSampleEndSeconds: Double
}

private enum IndependentToneEstimator {
    static func inspect(
        samples: [Float],
        sampleRate: Double,
        expectedFrequencyHz: Double,
        otherFixtureFrequenciesHz: [Double]
    ) throws -> IndependentToneObservation {
        guard samples.count >= 3, sampleRate.isFinite, sampleRate > 0 else {
            throw IndependentFixtureOracleError.invalidToneWindow
        }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let centered = samples.map { Double($0) - mean }
        let rms = sqrt(centered.reduce(0) { $0 + $1 * $1 } / Double(centered.count))
        let peak = centered.reduce(0) { max($0, abs($1)) }
        guard rms > 0, peak > 0 else {
            throw IndependentFixtureOracleError.invalidToneWindow
        }
        var crossings: [Double] = []
        crossings.reserveCapacity(samples.count / 64)
        for index in 1..<centered.count {
            let lower = centered[index - 1]
            let upper = centered[index]
            if lower <= 0, upper > 0, upper != lower {
                crossings.append(Double(index - 1) + (-lower / (upper - lower)))
            }
        }
        guard crossings.count >= 3,
            let first = crossings.first,
            let last = crossings.last,
            last > first
        else {
            throw IndependentFixtureOracleError.invalidToneWindow
        }
        let estimatedFrequency = Double(crossings.count - 1) * sampleRate / (last - first)
        let expectedPower = goertzelPower(
            samples: centered,
            sampleRate: sampleRate,
            frequency: expectedFrequencyHz
        )
        let strongestOtherPower = otherFixtureFrequenciesHz.map {
            goertzelPower(samples: centered, sampleRate: sampleRate, frequency: $0)
        }.max() ?? .leastNonzeroMagnitude
        let separation = 10 * log10(expectedPower / max(strongestOtherPower, .leastNonzeroMagnitude))

        return IndependentToneObservation(
            estimatedFrequencyHz: estimatedFrequency,
            rmsDecibels: 20 * log10(rms),
            peakDecibels: 20 * log10(peak),
            expectedToneSeparationDecibels: separation
        )
    }

    private static func goertzelPower(
        samples: [Double],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
        var previous = 0.0
        var previousPrevious = 0.0
        for sample in samples {
            let current = sample + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = current
        }
        return max(
            .leastNonzeroMagnitude,
            previousPrevious * previousPrevious + previous * previous
                - coefficient * previous * previousPrevious
        )
    }
}

private struct IndependentISOBox {
    let type: String
    let fullRange: Range<Int>
    let payloadRange: Range<Int>
}

private struct IndependentISOTimedFragment {
    let startTicks: UInt64
    let endTicks: UInt64
}

private struct IndependentISOInspection {
    let mediaTimescale: UInt32
    let mediaDurationTicks: UInt64
    let movieTimescale: UInt32
    let editListPresentationDurationSeconds: Double
    let presentationMediaStartTicks: UInt64
    let trailingPaddingTicks: UInt64
    let resolvedMediaDurationSource: IndependentISODurationSource
    let fragments: [IndependentISOTimedFragment]
    let hasFinalZeroCoveredPadding: Bool
    let mediaPayloadBytes: Int
    let hasCanonicalTopLevelOrder: Bool
    let containerLayoutProfile: String
    let initializationRange: Range<Int64>
    let indexRange: Range<Int64>?
}

private func measuredPresentationFragmentCadence(
    fragments: [IndependentISOTimedFragment],
    hasFinalZeroCoveredPadding: Bool,
    mediaTimescale: UInt32,
    fallbackPresentationDurationSeconds: Double
) -> Double {
    let presentationBearingFragments = hasFinalZeroCoveredPadding
        ? Array(fragments.dropLast())
        : fragments
    guard presentationBearingFragments.count > 1,
        let firstStart = presentationBearingFragments.first?.startTicks,
        let lastStart = presentationBearingFragments.last?.startTicks,
        mediaTimescale > 0
    else {
        return fallbackPresentationDurationSeconds
    }
    return Double(lastStart - firstStart)
        / Double(presentationBearingFragments.count - 1)
        / Double(mediaTimescale)
}

private enum IndependentISODurationSource: Equatable {
    case mdhd
    case finalFragment
}

private struct IndependentISOMediaInfo {
    let trackID: UInt32
    let timescale: UInt32
    let durationTicks: UInt64?
    let trak: IndependentISOBox
}

private struct IndependentISOMovieInfo {
    let timescale: UInt32
    let durationTicks: UInt64?
}

private struct IndependentISOEditInfo {
    let segmentDurationMovieTicks: UInt64
    let presentationMediaStartTicks: UInt64
    let usesZeroDurationPlaceholder: Bool
}

private enum IndependentISOParser {
    static func inspectFragmentedAudio(
        _ data: Data,
        expectedPresentationDurationSeconds: Double? = nil
    ) throws -> IndependentISOInspection {
        let topLevel = try boxes(in: data, range: data.startIndex..<data.endIndex)
        guard let ftyp = topLevel.first,
            ftyp.type == "ftyp",
            topLevel.filter({ $0.type == "moov" }).count == 1,
            let moov = topLevel.first(where: { $0.type == "moov" })
        else {
            throw IndependentFixtureOracleError.invalidTopLevelOrder
        }
        let relevant = topLevel.filter { ["ftyp", "moov", "moof", "mdat"].contains($0.type) }
        guard relevant.count >= 4,
            relevant.first?.type == "ftyp",
            relevant.dropFirst().first?.type == "moov"
        else {
            throw IndependentFixtureOracleError.invalidTopLevelOrder
        }
        let mediaSequence = Array(relevant.dropFirst(2))
        guard mediaSequence.count.isMultiple(of: 2) else {
            throw IndependentFixtureOracleError.invalidTopLevelOrder
        }
        for pairStart in stride(from: 0, to: mediaSequence.count, by: 2) {
            guard mediaSequence.indices.contains(pairStart),
                mediaSequence.indices.contains(pairStart + 1),
                mediaSequence[pairStart].type == "moof",
                mediaSequence[pairStart + 1].type == "mdat"
            else {
                throw IndependentFixtureOracleError.invalidTopLevelOrder
            }
        }

        let media = try audioMediaInfo(in: moov, data: data)
        let movie = try movieInfo(in: moov, data: data)
        let trexDefaults = try trackDefaults(in: moov, data: data)
        let moofs = mediaSequence.enumerated().compactMap { index, box in
            index.isMultiple(of: 2) ? box : nil
        }
        let fragments = try moofs.map {
            try timedFragment(
                in: $0,
                trackID: media.trackID,
                trexDefaultDuration: trexDefaults[media.trackID],
                data: data
            )
        }
        guard !fragments.isEmpty else {
            throw IndependentFixtureOracleError.missingFragmentTiming
        }
        guard fragments.first?.startTicks == 0 else {
            throw IndependentFixtureOracleError.nonprogressingFragment
        }
        let oneSecondTicks = UInt64(media.timescale)
        var previous: IndependentISOTimedFragment?
        for fragment in fragments {
            guard fragment.endTicks > fragment.startTicks else {
                throw IndependentFixtureOracleError.nonprogressingFragment
            }
            if let previous {
                guard fragment.startTicks > previous.startTicks,
                    fragment.startTicks >= previous.endTicks,
                    fragment.startTicks - previous.endTicks <= 1_024
                else {
                    throw IndependentFixtureOracleError.nonprogressingFragment
                }
            }
            previous = fragment
        }
        guard let finalDecodeEnd = fragments.last?.endTicks else {
            throw IndependentFixtureOracleError.mediaDurationMismatch
        }
        let resolvedDuration = try resolveMediaDuration(
            mdhdDuration: media.durationTicks,
            finalDecodeEnd: finalDecodeEnd
        )
        guard absoluteDifference(finalDecodeEnd, resolvedDuration.ticks) <= 1_024 else {
            throw IndependentFixtureOracleError.mediaDurationMismatch
        }
        let editInfo = try editListInfo(media: media, data: data)
        let mehdPresentationTicks = try fragmentPresentationDuration(
            in: moov,
            data: data
        )
        let expectedMovieTicks: UInt64? = try expectedPresentationDurationSeconds
            .map { seconds in
                let ticks = seconds * Double(movie.timescale)
                guard ticks.isFinite,
                    ticks > 0,
                    ticks < Double(UInt64.max)
                else {
                    throw IndependentFixtureOracleError.invalidDuration
                }
                return UInt64(ticks.rounded())
            }
        let presentationMovieTicks: UInt64
        if let editInfo, editInfo.segmentDurationMovieTicks > 0 {
            presentationMovieTicks = editInfo.segmentDurationMovieTicks
        } else if let expectedMovieTicks {
            presentationMovieTicks = expectedMovieTicks
        } else if let knownMovieDuration = movie.durationTicks {
            presentationMovieTicks = knownMovieDuration
        } else if let mehdPresentationTicks {
            presentationMovieTicks = mehdPresentationTicks
        } else if editInfo == nil {
            presentationMovieTicks = try convertTimescale(
                resolvedDuration.ticks,
                from: media.timescale,
                to: movie.timescale
            )
        } else {
            throw IndependentFixtureOracleError.missingMovieTiming
        }
        guard presentationMovieTicks > 0 else {
            throw IndependentFixtureOracleError.invalidDuration
        }
        let presentationDuration = Double(presentationMovieTicks)
            / Double(movie.timescale)
        let presentationMediaStartTicks = editInfo?
            .presentationMediaStartTicks ?? 0
        let presentationDurationMediaTicks = try convertTimescale(
            presentationMovieTicks,
            from: movie.timescale,
            to: media.timescale
        )
        let (expectedRawPresentationEnd, rawEndOverflow) =
            presentationMediaStartTicks.addingReportingOverflow(
                presentationDurationMediaTicks
            )
        guard !rawEndOverflow,
            presentationMediaStartTicks < resolvedDuration.ticks,
            finalDecodeEnd >= expectedRawPresentationEnd
        else {
            throw IndependentFixtureOracleError.editListDurationMismatch
        }
        let trailingPaddingTicks = finalDecodeEnd - expectedRawPresentationEnd
        var presentationCadenceFragments = fragments
        if let finalFragment = fragments.last {
            let mappedStart = min(
                presentationDurationMediaTicks,
                finalFragment.startTicks > presentationMediaStartTicks
                    ? finalFragment.startTicks - presentationMediaStartTicks
                    : 0
            )
            let mappedEnd = min(
                presentationDurationMediaTicks,
                finalFragment.endTicks > presentationMediaStartTicks
                    ? finalFragment.endTicks - presentationMediaStartTicks
                    : 0
            )
            if mappedStart == presentationDurationMediaTicks,
                mappedEnd == presentationDurationMediaTicks
            {
                guard finalFragment.startTicks == expectedRawPresentationEnd else {
                    throw IndependentFixtureOracleError.fragmentCadenceMismatch
                }
                let paddingDuration = finalFragment.endTicks
                    - finalFragment.startTicks
                guard paddingDuration > 0, paddingDuration <= 1_024 else {
                    throw IndependentFixtureOracleError.fragmentDurationOutOfBounds
                }
                presentationCadenceFragments.removeLast()
            }
        }
        guard trailingPaddingTicks <= 1_024 else {
            throw IndependentFixtureOracleError.editListDurationMismatch
        }
        guard !presentationCadenceFragments.isEmpty else {
            throw IndependentFixtureOracleError.fragmentCadenceMismatch
        }
        let maximumEdgeDuration = oneSecondTicks + 1_024
        for (index, fragment) in presentationCadenceFragments.enumerated() {
            let (rawCadenceStart, cadenceOverflow) = UInt64(index)
                .multipliedReportingOverflow(by: oneSecondTicks)
            guard !cadenceOverflow else {
                throw IndependentFixtureOracleError.integerOverflow
            }
            let expectedMappedStart = min(
                presentationDurationMediaTicks,
                rawCadenceStart > presentationMediaStartTicks
                    ? rawCadenceStart - presentationMediaStartTicks
                    : 0
            )
            let actualMappedStart = min(
                presentationDurationMediaTicks,
                fragment.startTicks > presentationMediaStartTicks
                    ? fragment.startTicks - presentationMediaStartTicks
                    : 0
            )
            let actualMappedEnd = min(
                presentationDurationMediaTicks,
                fragment.endTicks > presentationMediaStartTicks
                    ? fragment.endTicks - presentationMediaStartTicks
                    : 0
            )
            guard absoluteDifference(actualMappedStart, expectedMappedStart)
                <= 1_024,
                actualMappedEnd > actualMappedStart
            else {
                throw IndependentFixtureOracleError.fragmentCadenceMismatch
            }
            let duration = fragment.endTicks - fragment.startTicks
            let isInterior = index > 0
                && index < presentationCadenceFragments.count - 1
            if isInterior {
                guard absoluteDifference(duration, oneSecondTicks) <= 1_024 else {
                    throw IndependentFixtureOracleError.fragmentDurationOutOfBounds
                }
            } else if duration > maximumEdgeDuration {
                throw IndependentFixtureOracleError.fragmentDurationOutOfBounds
            }
        }
        let hasFinalZeroCoveredPadding = presentationCadenceFragments.count
            != fragments.count
        let wholeSecondCount = presentationDurationMediaTicks / oneSecondTicks
        guard wholeSecondCount <= UInt64(Int.max),
            presentationCadenceFragments.count
                >= max(1, Int(wholeSecondCount))
        else {
            throw IndependentFixtureOracleError.fragmentCadenceMismatch
        }
        let presentationToleranceMovieTicks = max(
            1,
            try convertTimescale(1_024, from: media.timescale, to: movie.timescale)
        )
        if let expectedMovieTicks,
            absoluteDifference(expectedMovieTicks, presentationMovieTicks)
                > presentationToleranceMovieTicks
        {
            throw IndependentFixtureOracleError.editListDurationMismatch
        }
        if let mehdPresentationTicks,
            absoluteDifference(mehdPresentationTicks, presentationMovieTicks)
                > presentationToleranceMovieTicks
        {
            throw IndependentFixtureOracleError.mehdPresentationDurationMismatch
        }
        if let knownMovieDuration = movie.durationTicks,
            !(expectedMovieTicks != nil
                && editInfo?.usesZeroDurationPlaceholder == true
                && knownMovieDuration == 1),
            absoluteDifference(knownMovieDuration, presentationMovieTicks)
                > presentationToleranceMovieTicks
        {
            throw IndependentFixtureOracleError.moviePresentationDurationMismatch
        }
        let mediaPayloadBytes = mediaSequence.enumerated().reduce(0) { partial, entry in
            entry.offset.isMultiple(of: 2) ? partial : partial + entry.element.payloadRange.count
        }
        guard mediaPayloadBytes > 0 else {
            throw IndependentFixtureOracleError.missingMediaData
        }
        let initializationRange = Int64(ftyp.fullRange.lowerBound)
            ..< Int64(moov.fullRange.upperBound)
        let sidx = topLevel.filter { $0.type == "sidx" }
        let indexRange: Range<Int64>? = if
            let lower = sidx.map(\.fullRange.lowerBound).min(),
            let upper = sidx.map(\.fullRange.upperBound).max()
        {
            Int64(lower)..<Int64(upper)
        } else {
            nil
        }
        return IndependentISOInspection(
            mediaTimescale: media.timescale,
            mediaDurationTicks: resolvedDuration.ticks,
            movieTimescale: movie.timescale,
            editListPresentationDurationSeconds: presentationDuration,
            presentationMediaStartTicks: presentationMediaStartTicks,
            trailingPaddingTicks: trailingPaddingTicks,
            resolvedMediaDurationSource: resolvedDuration.source,
            fragments: fragments,
            hasFinalZeroCoveredPadding: hasFinalZeroCoveredPadding,
            mediaPayloadBytes: mediaPayloadBytes,
            hasCanonicalTopLevelOrder: true,
            containerLayoutProfile: "ftyp+moov+(moof+mdat)*",
            initializationRange: initializationRange,
            indexRange: indexRange
        )
    }

    private static func audioMediaInfo(
        in moov: IndependentISOBox,
        data: Data
    ) throws -> IndependentISOMediaInfo {
        for trak in try children(of: moov, data: data).filter({ $0.type == "trak" }) {
            let trakChildren = try children(of: trak, data: data)
            guard let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
                let mdia = trakChildren.first(where: { $0.type == "mdia" })
            else { continue }
            let mdiaChildren = try children(of: mdia, data: data)
            guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) else {
                continue
            }
            _ = try fullBoxHeader(hdlr, supportedVersions: [0], data: data)
            guard try ascii(
                data,
                at: hdlr.payloadRange.lowerBound + 8,
                count: 4,
                within: hdlr.payloadRange
            ) == "soun",
                let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" })
            else { continue }
            let tkhdVersion = try fullBoxHeader(
                tkhd,
                supportedVersions: [0, 1],
                data: data
            ).version
            let trackIDOffset = tkhd.payloadRange.lowerBound + (tkhdVersion == 1 ? 20 : 12)
            let trackID = try uint32(data, at: trackIDOffset, within: tkhd.payloadRange)
            let mdhdVersion = try fullBoxHeader(
                mdhd,
                supportedVersions: [0, 1],
                data: data
            ).version
            let timescaleOffset = mdhd.payloadRange.lowerBound + (mdhdVersion == 1 ? 20 : 12)
            let durationOffset = mdhd.payloadRange.lowerBound + (mdhdVersion == 1 ? 24 : 16)
            let timescale = try uint32(data, at: timescaleOffset, within: mdhd.payloadRange)
            let encodedDuration = mdhdVersion == 1
                ? try uint64(data, at: durationOffset, within: mdhd.payloadRange)
                : UInt64(try uint32(data, at: durationOffset, within: mdhd.payloadRange))
            let duration = knownDuration(
                encodedDuration,
                allOnes: mdhdVersion == 1 ? UInt64.max : UInt64(UInt32.max)
            )
            guard trackID > 0, timescale > 0 else {
                throw IndependentFixtureOracleError.invalidFragmentTimescale
            }
            return IndependentISOMediaInfo(
                trackID: trackID,
                timescale: timescale,
                durationTicks: duration,
                trak: trak
            )
        }
        throw IndependentFixtureOracleError.missingAudioTiming
    }

    private static func movieInfo(
        in moov: IndependentISOBox,
        data: Data
    ) throws -> IndependentISOMovieInfo {
        guard let mvhd = try children(of: moov, data: data).first(where: { $0.type == "mvhd" })
        else { throw IndependentFixtureOracleError.missingMovieTiming }
        let version = try fullBoxHeader(mvhd, supportedVersions: [0, 1], data: data).version
        let timescaleOffset = mvhd.payloadRange.lowerBound + (version == 1 ? 20 : 12)
        let durationOffset = mvhd.payloadRange.lowerBound + (version == 1 ? 24 : 16)
        let timescale = try uint32(data, at: timescaleOffset, within: mvhd.payloadRange)
        let encodedDuration = version == 1
            ? try uint64(data, at: durationOffset, within: mvhd.payloadRange)
            : UInt64(try uint32(data, at: durationOffset, within: mvhd.payloadRange))
        let duration = knownDuration(
            encodedDuration,
            allOnes: version == 1 ? UInt64.max : UInt64(UInt32.max)
        )
        guard timescale > 0 else {
            throw IndependentFixtureOracleError.missingMovieTiming
        }
        return IndependentISOMovieInfo(timescale: timescale, durationTicks: duration)
    }

    private static func editListInfo(
        media: IndependentISOMediaInfo,
        data: Data
    ) throws -> IndependentISOEditInfo? {
        let editContainers = try children(of: media.trak, data: data)
            .filter { $0.type == "edts" }
        guard editContainers.count <= 1 else {
            throw IndependentFixtureOracleError.unsupportedEditList
        }
        guard let edts = editContainers.first else {
            return nil
        }
        let editLists = try children(of: edts, data: data)
            .filter { $0.type == "elst" }
        guard editLists.count == 1, let elst = editLists.first else {
            throw IndependentFixtureOracleError.unsupportedEditList
        }
        let version = try fullBoxHeader(elst, supportedVersions: [0, 1], data: data).version
        let entryCount = UInt64(
            try uint32(
                data,
                at: elst.payloadRange.lowerBound + 4,
                within: elst.payloadRange
            )
        )
        let entrySize = version == 1 ? 20 : 12
        guard entryCount == 1 else {
            throw IndependentFixtureOracleError.unsupportedEditList
        }
        let (requiredBytes, overflow) = Int(entryCount)
            .multipliedReportingOverflow(by: entrySize)
        guard !overflow else { throw IndependentFixtureOracleError.integerOverflow }
        let cursor = try advanced(
            elst.payloadRange.lowerBound + 8,
            by: 0,
            within: elst.payloadRange
        )
        _ = try advanced(cursor, by: requiredBytes, within: elst.payloadRange)
        let segmentDuration = version == 1
            ? try uint64(data, at: cursor, within: elst.payloadRange)
            : UInt64(try uint32(data, at: cursor, within: elst.payloadRange))
        let mediaTime = version == 1
            ? try int64(data, at: cursor + 8, within: elst.payloadRange)
            : Int64(try int32(data, at: cursor + 4, within: elst.payloadRange))
        let rateOffset = cursor + (version == 1 ? 16 : 8)
        let rateInteger = try int16(data, at: rateOffset, within: elst.payloadRange)
        let rateFraction = try int16(data, at: rateOffset + 2, within: elst.payloadRange)
        guard mediaTime >= 0,
            rateInteger == 1,
            rateFraction == 0
        else {
            throw IndependentFixtureOracleError.unsupportedEditList
        }
        return IndependentISOEditInfo(
            segmentDurationMovieTicks: segmentDuration,
            presentationMediaStartTicks: UInt64(mediaTime),
            usesZeroDurationPlaceholder: segmentDuration == 0
        )
    }

    private static func fragmentPresentationDuration(
        in moov: IndependentISOBox,
        data: Data
    ) throws -> UInt64? {
        guard let mvex = try children(of: moov, data: data)
            .first(where: { $0.type == "mvex" }),
            let mehd = try children(of: mvex, data: data)
                .first(where: { $0.type == "mehd" })
        else { return nil }
        let version = try fullBoxHeader(mehd, supportedVersions: [0, 1], data: data)
            .version
        let encoded = version == 1
            ? try uint64(
                data,
                at: mehd.payloadRange.lowerBound + 4,
                within: mehd.payloadRange
            )
            : UInt64(
                try uint32(
                    data,
                    at: mehd.payloadRange.lowerBound + 4,
                    within: mehd.payloadRange
                )
            )
        return knownDuration(
            encoded,
            allOnes: version == 1 ? UInt64.max : UInt64(UInt32.max)
        )
    }

    private static func resolveMediaDuration(
        mdhdDuration: UInt64?,
        finalDecodeEnd: UInt64
    ) throws -> (ticks: UInt64, source: IndependentISODurationSource) {
        if let mdhdDuration,
            absoluteDifference(mdhdDuration, finalDecodeEnd) > 1_024
        {
            throw IndependentFixtureOracleError.mediaDurationMismatch
        }
        if let mdhdDuration {
            return (mdhdDuration, .mdhd)
        }
        return (finalDecodeEnd, .finalFragment)
    }

    private static func convertTimescale(
        _ ticks: UInt64,
        from sourceTimescale: UInt32,
        to destinationTimescale: UInt32
    ) throws -> UInt64 {
        let converted = Double(ticks) * Double(destinationTimescale)
            / Double(sourceTimescale)
        guard converted.isFinite,
            converted >= 0,
            converted < Double(UInt64.max)
        else { throw IndependentFixtureOracleError.integerOverflow }
        return UInt64(converted.rounded())
    }

    private static func knownDuration(_ value: UInt64, allOnes: UInt64) -> UInt64? {
        value == 0 || value == allOnes ? nil : value
    }

    private static func trackDefaults(
        in moov: IndependentISOBox,
        data: Data
    ) throws -> [UInt32: UInt32] {
        guard let mvex = try children(of: moov, data: data).first(where: { $0.type == "mvex" })
        else { return [:] }
        var defaults: [UInt32: UInt32] = [:]
        for trex in try children(of: mvex, data: data).filter({ $0.type == "trex" }) {
            _ = try fullBoxHeader(trex, supportedVersions: [0], data: data)
            let trackID = try uint32(
                data,
                at: trex.payloadRange.lowerBound + 4,
                within: trex.payloadRange
            )
            let duration = try uint32(
                data,
                at: trex.payloadRange.lowerBound + 12,
                within: trex.payloadRange
            )
            defaults[trackID] = duration
        }
        return defaults
    }

    private static func timedFragment(
        in moof: IndependentISOBox,
        trackID: UInt32,
        trexDefaultDuration: UInt32?,
        data: Data
    ) throws -> IndependentISOTimedFragment {
        let matching = try children(of: moof, data: data)
            .filter { $0.type == "traf" }
            .compactMap { traf -> (UInt64, UInt64)? in
                let entries = try children(of: traf, data: data)
                guard let tfhd = entries.first(where: { $0.type == "tfhd" }) else {
                    throw IndependentFixtureOracleError.missingFragmentTiming
                }
                let header = try parseTFHD(tfhd, data: data)
                guard header.trackID == trackID else { return nil }
                guard let tfdt = entries.first(where: { $0.type == "tfdt" }) else {
                    throw IndependentFixtureOracleError.missingFragmentTiming
                }
                let start = try parseTFDT(tfdt, data: data)
                let truns = entries.filter { $0.type == "trun" }
                guard !truns.isEmpty else {
                    throw IndependentFixtureOracleError.missingFragmentTiming
                }
                let defaultDuration = header.defaultSampleDuration ?? trexDefaultDuration
                var duration: UInt64 = 0
                for trun in truns {
                    let addition = try parseTRUN(
                        trun,
                        defaultSampleDuration: defaultDuration,
                        data: data
                    )
                    let (sum, overflow) = duration.addingReportingOverflow(addition)
                    guard !overflow else {
                        throw IndependentFixtureOracleError.integerOverflow
                    }
                    duration = sum
                }
                let (end, overflow) = start.addingReportingOverflow(duration)
                guard !overflow, duration > 0 else {
                    throw IndependentFixtureOracleError.integerOverflow
                }
                return (start, end)
            }
        guard matching.count == 1, let timing = matching.first else {
            throw IndependentFixtureOracleError.missingFragmentTiming
        }
        return IndependentISOTimedFragment(startTicks: timing.0, endTicks: timing.1)
    }

    private static func parseTFHD(
        _ box: IndependentISOBox,
        data: Data
    ) throws -> (trackID: UInt32, defaultSampleDuration: UInt32?) {
        let header = try fullBoxHeader(box, supportedVersions: [0], data: data)
        let flags = header.flags
        let trackID = try uint32(
            data,
            at: box.payloadRange.lowerBound + 4,
            within: box.payloadRange
        )
        var cursor = box.payloadRange.lowerBound + 8
        if flags & 0x000001 != 0 { cursor = try advanced(cursor, by: 8, within: box.payloadRange) }
        if flags & 0x000002 != 0 { cursor = try advanced(cursor, by: 4, within: box.payloadRange) }
        let defaultDuration: UInt32?
        if flags & 0x000008 != 0 {
            defaultDuration = try uint32(data, at: cursor, within: box.payloadRange)
            cursor = try advanced(cursor, by: 4, within: box.payloadRange)
        } else {
            defaultDuration = nil
        }
        if flags & 0x000010 != 0 { cursor = try advanced(cursor, by: 4, within: box.payloadRange) }
        if flags & 0x000020 != 0 { _ = try advanced(cursor, by: 4, within: box.payloadRange) }
        return (trackID, defaultDuration)
    }

    private static func parseTFDT(_ box: IndependentISOBox, data: Data) throws -> UInt64 {
        let version = try fullBoxHeader(box, supportedVersions: [0, 1], data: data).version
        return version == 1
            ? try uint64(
                data,
                at: box.payloadRange.lowerBound + 4,
                within: box.payloadRange
            )
            : UInt64(
                try uint32(
                    data,
                    at: box.payloadRange.lowerBound + 4,
                    within: box.payloadRange
                )
            )
    }

    private static func parseTRUN(
        _ box: IndependentISOBox,
        defaultSampleDuration: UInt32?,
        data: Data
    ) throws -> UInt64 {
        let header = try fullBoxHeader(box, supportedVersions: [0, 1], data: data)
        let flags = header.flags
        let sampleCount = UInt64(
            try uint32(
                data,
                at: box.payloadRange.lowerBound + 4,
                within: box.payloadRange
            )
        )
        guard sampleCount > 0 else {
            throw IndependentFixtureOracleError.missingSampleDuration
        }
        var cursor = box.payloadRange.lowerBound + 8
        if flags & 0x000001 != 0 { cursor = try advanced(cursor, by: 4, within: box.payloadRange) }
        if flags & 0x000004 != 0 { cursor = try advanced(cursor, by: 4, within: box.payloadRange) }
        let hasDuration = flags & 0x000100 != 0
        let perSampleBytes = (hasDuration ? 4 : 0)
            + (flags & 0x000200 != 0 ? 4 : 0)
            + (flags & 0x000400 != 0 ? 4 : 0)
            + (flags & 0x000800 != 0 ? 4 : 0)
        guard sampleCount <= UInt64(Int.max) else {
            throw IndependentFixtureOracleError.integerOverflow
        }
        let (requiredBytes, byteOverflow) = Int(sampleCount)
            .multipliedReportingOverflow(by: perSampleBytes)
        guard !byteOverflow else {
            throw IndependentFixtureOracleError.integerOverflow
        }
        _ = try advanced(cursor, by: requiredBytes, within: box.payloadRange)

        if !hasDuration {
            guard let defaultSampleDuration, defaultSampleDuration > 0 else {
                throw IndependentFixtureOracleError.missingSampleDuration
            }
            let (duration, overflow) = sampleCount.multipliedReportingOverflow(
                by: UInt64(defaultSampleDuration)
            )
            guard !overflow else { throw IndependentFixtureOracleError.integerOverflow }
            return duration
        }
        var total: UInt64 = 0
        for _ in 0..<Int(sampleCount) {
            let duration = UInt64(
                try uint32(data, at: cursor, within: box.payloadRange)
            )
            guard duration > 0 else {
                throw IndependentFixtureOracleError.missingSampleDuration
            }
            let (sum, overflow) = total.addingReportingOverflow(duration)
            guard !overflow else { throw IndependentFixtureOracleError.integerOverflow }
            total = sum
            cursor += perSampleBytes
        }
        return total
    }

    private static func children(
        of box: IndependentISOBox,
        data: Data
    ) throws -> [IndependentISOBox] {
        try boxes(in: data, range: box.payloadRange)
    }

    private static func boxes(in data: Data, range: Range<Int>) throws -> [IndependentISOBox] {
        guard range.lowerBound >= data.startIndex,
            range.upperBound <= data.endIndex,
            range.lowerBound <= range.upperBound
        else { throw IndependentFixtureOracleError.invalidISOBoxSize }
        var result: [IndependentISOBox] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else {
                throw IndependentFixtureOracleError.truncatedISOBoxHeader
            }
            let compactSize = UInt64(try uint32(data, at: offset, within: range))
            let type = try ascii(data, at: offset + 4, count: 4, within: range)
            var headerSize = 8
            let size: UInt64
            if compactSize == 0 {
                size = UInt64(range.upperBound - offset)
            } else if compactSize == 1 {
                guard range.upperBound - offset >= 16 else {
                    throw IndependentFixtureOracleError.truncatedISOBoxHeader
                }
                size = try uint64(data, at: offset + 8, within: range)
                headerSize = 16
            } else {
                size = compactSize
            }
            guard size >= UInt64(headerSize),
                size <= UInt64(range.upperBound - offset),
                size <= UInt64(Int.max)
            else { throw IndependentFixtureOracleError.invalidISOBoxSize }
            let integerSize = Int(size)
            let end = offset + integerSize
            guard end > offset else {
                throw IndependentFixtureOracleError.nonprogressingISOBox
            }
            result.append(
                IndependentISOBox(
                    type: type,
                    fullRange: offset..<end,
                    payloadRange: (offset + headerSize)..<end
                )
            )
            offset = end
        }
        guard offset == range.upperBound else {
            throw IndependentFixtureOracleError.invalidISOBoxSize
        }
        return result
    }

    private static func advanced(
        _ offset: Int,
        by count: Int,
        within range: Range<Int>
    ) throws -> Int {
        guard count >= 0, offset >= range.lowerBound, offset <= range.upperBound,
            count <= range.upperBound - offset
        else { throw IndependentFixtureOracleError.truncatedISOBoxHeader }
        return offset + count
    }

    private static func absoluteDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private static func fullBoxHeader(
        _ box: IndependentISOBox,
        supportedVersions: Set<UInt8>,
        data: Data
    ) throws -> (version: UInt8, flags: UInt32) {
        let full = try uint32(
            data,
            at: box.payloadRange.lowerBound,
            within: box.payloadRange
        )
        let version = UInt8((full >> 24) & 0xFF)
        guard supportedVersions.contains(version) else {
            throw IndependentFixtureOracleError.unsupportedFullBoxVersion
        }
        return (version, full & 0x00FF_FFFF)
    }

    private static func uint32(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt32 {
        let bytes = try checkedSlice(data, offset: offset, count: 4, within: range)
        return bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt64 {
        let bytes = try checkedSlice(data, offset: offset, count: 8, within: range)
        return bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    }

    private static func int16(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> Int16 {
        let bytes = try checkedSlice(data, offset: offset, count: 2, within: range)
        let value = bytes.reduce(UInt16.zero) { ($0 << 8) | UInt16($1) }
        return Int16(bitPattern: value)
    }

    private static func int32(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> Int32 {
        Int32(bitPattern: try uint32(data, at: offset, within: range))
    }

    private static func int64(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> Int64 {
        Int64(bitPattern: try uint64(data, at: offset, within: range))
    }

    private static func ascii(
        _ data: Data,
        at offset: Int,
        count: Int,
        within range: Range<Int>
    ) throws -> String {
        let bytes = try checkedSlice(
            data,
            offset: offset,
            count: count,
            within: range
        )
        guard let value = String(data: bytes, encoding: .ascii) else {
            throw IndependentFixtureOracleError.invalidISOBoxType
        }
        return value
    }

    private static func checkedSlice(
        _ data: Data,
        offset: Int,
        count: Int,
        within range: Range<Int>
    ) throws -> Data.SubSequence {
        guard range.lowerBound >= data.startIndex,
            range.upperBound <= data.endIndex,
            offset >= range.lowerBound,
            count >= 0,
            offset <= range.upperBound,
            count <= range.upperBound - offset
        else { throw IndependentFixtureOracleError.truncatedISOBoxHeader }
        return data[offset..<(offset + count)]
    }
}

private enum IndependentFixtureOracleError: Error {
    case invalidAudioTrackCount(Int)
    case invalidFormatDescription
    case invalidElementaryStreamDescriptor
    case invalidAudioSpecificConfig
    case invalidDuration
    case cannotAddReaderOutput
    case readerFailed
    case invalidSamplePTS
    case missingSampleData
    case invalidSampleDataLength
    case sampleCopyFailed(OSStatus)
    case truncatedSampleData
    case incompleteToneWindow
    case invalidToneWindow
    case truncatedISOBoxHeader
    case invalidISOBoxType
    case invalidISOBoxSize
    case nonprogressingISOBox
    case invalidTopLevelOrder
    case missingMediaData
    case missingAudioTiming
    case missingMovieTiming
    case invalidFragmentTimescale
    case unsupportedFullBoxVersion
    case unsupportedEditList
    case editListDurationMismatch
    case mediaDurationMismatch
    case mehdPresentationDurationMismatch
    case moviePresentationDurationMismatch
    case fragmentDurationOutOfBounds
    case fragmentCadenceMismatch
    case missingFragmentTiming
    case missingSampleDuration
    case nonprogressingFragment
    case integerOverflow
}

private func withUniqueTemporaryDirectory(
    _ operation: (URL) async throws -> Void
) async rethrows {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LovelyMusic-Task10-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
    } catch {
        XCTFail("Failed to create isolated fixture directory: \(error)")
        return
    }
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        } catch {
            XCTFail("Failed to remove isolated fixture directory: \(error)")
        }
    }
    try await operation(directory)
}

private func recursiveRelativeContents(in directory: URL) throws -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil
    ) else { return [] }
    let prefix = directory.standardizedFileURL.path + "/"
    return enumerator.compactMap { item -> String? in
        guard let url = item as? URL else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }.sorted()
}

private func requireSendable<T: Sendable>(_: T) {}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func toneScheduleSHA256(_ regions: [IndependentToneRegion]) -> String {
    let canonical = regions.map { region in
        String(
            format: "%.6f-%.6f:%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            region.startSeconds,
            region.endSeconds,
            region.frequencyHz
        )
    }.joined(separator: "\n")
    return sha256Hex(Data(canonical.utf8))
}

private func syntheticSine(
    frequencyHz: Double,
    sampleRate: Double,
    durationSeconds: Double,
    peakAmplitude: Double
) -> [Float] {
    let count = Int(sampleRate * durationSeconds)
    return (0..<count).map { frame in
        Float(peakAmplitude * sin(2 * .pi * frequencyHz * Double(frame) / sampleRate))
    }
}

private func isoBox(_ type: String, payload: Data) -> Data {
    var data = uint32Data(UInt32(payload.count + 8))
    data.append(Data(type.utf8.prefix(4)))
    data.append(payload)
    return data
}

private func fullBox(version: UInt8 = 0, flags: UInt32 = 0) -> Data {
    Data([version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)])
}

private func packedAudioSpecificConfigBits(
    _ fields: [(value: UInt32, width: Int)]
) -> Data {
    var bits: [UInt8] = []
    for field in fields {
        precondition(field.width > 0 && field.width <= 32)
        if field.width < 32 {
            precondition(field.value < (UInt32(1) << UInt32(field.width)))
        }
        for shift in stride(from: field.width - 1, through: 0, by: -1) {
            bits.append(UInt8((field.value >> UInt32(shift)) & 1))
        }
    }
    while !bits.count.isMultiple(of: 8) { bits.append(0) }
    return stride(from: 0, to: bits.count, by: 8).reduce(into: Data()) {
        output, start in
        let byte = bits[start..<(start + 8)].reduce(UInt8(0)) {
            ($0 << 1) | $1
        }
        output.append(byte)
    }
}

private enum SyntheticESDSMutation: CaseIterable {
    case duplicateDecoderConfig
    case duplicateDecoderSpecificInfo
    case duplicateESDSBox
    case duplicateSLConfig
    case extraSampleEntry
    case invalidDescriptorLength
    case missingSLConfig
    case nonzeroESDSFullBoxFlags
    case nonzeroHandlerFullBoxFlags
    case nonzeroSTSDTypeFullBoxFlags
    case slConfigBeforeDecoderConfig
    case truncatedDecoderSpecificInfo
    case truncatedSLConfig
    case wrongHierarchy
    case wrongObjectTypeIndication
    case wrongSLConfigPayload
    case wrongSLConfigTag
}

private func syntheticAudioInitialization(
    audioSpecificConfig: Data = Data([0x11, 0x88]),
    packedStreamTypeByte: UInt8 = 0x15,
    mutation: SyntheticESDSMutation? = nil
) -> Data {
    let specificInfo: Data
    switch mutation {
    case .truncatedDecoderSpecificInfo:
        specificInfo = Data([0x05, 0x03]) + audioSpecificConfig
    default:
        specificInfo = mpeg4Descriptor(
            tag: 0x05,
            payload: audioSpecificConfig
        )
    }
    let decoderPayload = Data([0x40, packedStreamTypeByte])
        + Data(repeating: 0, count: 11)
        + specificInfo
        + (mutation == .duplicateDecoderSpecificInfo ? specificInfo : Data())
    let decoder: Data
    switch mutation {
    case .invalidDescriptorLength:
        decoder = Data([0x04, 0x80, 0x80, 0x80, 0x80, 0x00])
    default:
        decoder = mpeg4Descriptor(
            tag: 0x04,
            payload: (mutation == .wrongObjectTypeIndication
                ? Data([0x66]) + Data(decoderPayload.dropFirst())
                : decoderPayload)
        )
    }
    let esChildren: Data
    if mutation == .wrongHierarchy {
        esChildren = specificInfo
    } else {
        let canonicalSLConfig = mpeg4Descriptor(
            tag: 0x06,
            payload: Data([0x02])
        )
        let slConfig: Data
        switch mutation {
        case .missingSLConfig:
            slConfig = Data()
        case .duplicateSLConfig:
            slConfig = canonicalSLConfig + canonicalSLConfig
        case .truncatedSLConfig:
            slConfig = Data([0x06, 0x02, 0x02])
        case .wrongSLConfigPayload:
            slConfig = mpeg4Descriptor(tag: 0x06, payload: Data([0x03]))
        case .wrongSLConfigTag:
            slConfig = mpeg4Descriptor(tag: 0x07, payload: Data([0x02]))
        default:
            slConfig = canonicalSLConfig
        }
        if mutation == .slConfigBeforeDecoderConfig {
            esChildren = slConfig + decoder
        } else {
            esChildren = decoder
                + (mutation == .duplicateDecoderConfig ? decoder : Data())
                + slConfig
        }
    }
    let esDescriptor = mpeg4Descriptor(
        tag: 0x03,
        payload: Data([0x00, 0x01, 0x00]) + esChildren
    )
    let esds = isoBox(
        "esds",
        payload: fullBox(
            flags: mutation == .nonzeroESDSFullBoxFlags ? 1 : 0
        ) + esDescriptor
    )
    var sampleEntryHeader = Data(repeating: 0, count: 28)
    sampleEntryHeader[7] = 1
    let mp4a = isoBox(
        "mp4a",
        payload: sampleEntryHeader + esds
            + (mutation == .duplicateESDSBox ? esds : Data())
    )
    let extraSampleEntry = mutation == .extraSampleEntry
        ? isoBox("enca", payload: sampleEntryHeader)
        : Data()
    let stsd = isoBox(
        "stsd",
        payload: fullBox(
            flags: mutation == .nonzeroSTSDTypeFullBoxFlags ? 1 : 0
        ) + uint32Data(mutation == .extraSampleEntry ? 2 : 1)
            + mp4a + extraSampleEntry
    )
    let stbl = isoBox("stbl", payload: stsd)
    let minf = isoBox("minf", payload: stbl)
    let hdlr = isoBox(
        "hdlr",
        payload: fullBox(
            flags: mutation == .nonzeroHandlerFullBoxFlags ? 1 : 0
        ) + uint32Data(0) + Data("soun".utf8)
    )
    let mdia = isoBox("mdia", payload: hdlr + minf)
    let trak = isoBox("trak", payload: mdia)
    return isoBox("ftyp", payload: Data("isom".utf8))
        + isoBox("moov", payload: trak)
}

private func mpeg4Descriptor(tag: UInt8, payload: Data) -> Data {
    precondition(payload.count <= 0x0FFF_FFFF)
    var remaining = payload.count
    var lengthBytes = [UInt8(remaining & 0x7F)]
    remaining >>= 7
    while remaining > 0 {
        lengthBytes.append(UInt8(remaining & 0x7F) | 0x80)
        remaining >>= 7
    }
    return Data([tag]) + Data(lengthBytes.reversed()) + payload
}

private func uint32Data(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ])
}

private func truncatedExtendedBox() -> Data {
    uint32Data(1) + Data("moof".utf8) + uint32Data(0)
}

private func overflowingExtendedBox() -> Data {
    uint32Data(1) + Data("moof".utf8) + Data(repeating: 0xFF, count: 8)
}

private func nonprogressBox() -> Data {
    uint32Data(4) + Data("free".utf8)
}

private func containerWithTruncatedNestedBox() -> Data {
    let badChild = uint32Data(100) + Data("trak".utf8)
    return isoBox("ftyp", payload: Data("isom".utf8))
        + isoBox("moov", payload: badChild)
        + isoBox("moof", payload: Data())
        + isoBox("mdat", payload: Data([0]))
}

private func containerWithoutSampleDuration() -> Data {
    let tkhd = isoBox(
        "tkhd",
        payload: fullBox() + uint32Data(0) + uint32Data(0) + uint32Data(1) + uint32Data(0)
    )
    let hdlr = isoBox("hdlr", payload: fullBox() + uint32Data(0) + Data("soun".utf8))
    let mdhd = isoBox(
        "mdhd",
        payload: fullBox() + uint32Data(0) + uint32Data(0) + uint32Data(48_000)
            + uint32Data(48_000)
    )
    let trak = isoBox("trak", payload: tkhd + isoBox("mdia", payload: mdhd + hdlr))
    let trex = isoBox(
        "trex",
        payload: fullBox() + uint32Data(1) + uint32Data(1) + uint32Data(0)
            + uint32Data(0) + uint32Data(0)
    )
    let moov = isoBox("moov", payload: trak + isoBox("mvex", payload: trex))
    let tfhd = isoBox("tfhd", payload: fullBox() + uint32Data(1))
    let tfdt = isoBox("tfdt", payload: fullBox() + uint32Data(0))
    let trun = isoBox("trun", payload: fullBox() + uint32Data(1))
    let moof = isoBox("moof", payload: isoBox("traf", payload: tfhd + tfdt + trun))
    return isoBox("ftyp", payload: Data("isom".utf8)) + moov + moof
        + isoBox("mdat", payload: Data([0]))
}

private func syntheticEditedContainer(
    shortField: String? = nil,
    unsupportedVersionField: String? = nil,
    includeTwoSIDXBoxes: Bool = false,
    unknownDurationEncoding: SyntheticUnknownDurationEncoding? = nil,
    includeMEHDForUnknownDuration: Bool = true,
    mehdVersion: UInt8 = 0,
    mehdDurationMovieTicks: UInt64? = nil,
    movieTimescale: UInt32 = 1_000,
    knownMovieDuration: UInt32? = nil,
    knownMediaDuration: UInt32? = nil,
    editEntryCount: UInt32 = 1,
    duplicateEditListBox: Bool = false,
    duplicateEditContainer: Bool = false,
    editSegmentDuration: UInt32 = 1_000,
    editMediaTime: UInt32 = 1_152,
    defaultSampleDuration: UInt32 = 1,
    fragmentSampleCounts: [UInt32] = [48_000, 1_152],
    fragmentStartTicks: [UInt32]? = nil
) -> Data {
    precondition(
        fragmentStartTicks == nil
            || fragmentStartTicks?.count == fragmentSampleCounts.count
    )
    func version(for field: String) -> UInt8 {
        unsupportedVersionField == field ? 2 : 0
    }
    let movieDuration = unknownDurationEncoding?.encodedValue
        ?? knownMovieDuration
        ?? 1_000
    let mediaDuration = unknownDurationEncoding?.encodedValue
        ?? knownMediaDuration
        ?? 49_152
    let mvhd = isoBox(
        "mvhd",
        payload: fullBox(version: version(for: "mvhd")) + uint32Data(0) + uint32Data(0)
            + uint32Data(movieTimescale) + uint32Data(movieDuration)
    )
    let validTKHD = fullBox(version: version(for: "tkhd")) + uint32Data(0) + uint32Data(0)
        + uint32Data(1) + uint32Data(0)
    let tkhd = isoBox("tkhd", payload: shortField == "tkhd" ? fullBox() : validTKHD)
    let tkhdSibling = shortField == "tkhd"
        ? isoBox("junk", payload: uint32Data(1) + Data(repeating: 0, count: 12))
        : Data()

    let mdhdVersion = version(for: "mdhd")
    let validMDHD = fullBox(version: mdhdVersion) + uint32Data(0) + uint32Data(0)
        + uint32Data(48_000) + uint32Data(mediaDuration)
    let mdhd = isoBox("mdhd", payload: shortField == "mdhd" ? fullBox() : validMDHD)
    let mdhdSibling = shortField == "mdhd"
        ? isoBox(
            "junk",
            payload: uint32Data(48_000) + uint32Data(49_152)
                + Data(repeating: 0, count: 8)
        )
        : Data()
    let hdlr = isoBox(
        "hdlr",
        payload: shortField == "hdlr"
            ? fullBox()
            : fullBox(version: version(for: "hdlr")) + uint32Data(0) + Data("soun".utf8)
    )
    let hdlrSibling = shortField == "hdlr"
        ? isoBox("soun", payload: Data(repeating: 0, count: 12))
        : Data()
    let mdia = isoBox(
        "mdia",
        payload: hdlr + hdlrSibling + mdhd + mdhdSibling
    )

    let editEntry = uint32Data(editSegmentDuration) + uint32Data(editMediaTime)
        + int16Data(1) + int16Data(0)
    let editEntries = (0..<Int(editEntryCount)).reduce(into: Data()) {
        result, _ in result.append(editEntry)
    }
    let elst = isoBox(
        "elst",
        payload: fullBox(version: version(for: "elst"))
            + uint32Data(editEntryCount) + editEntries
    )
    let edts = isoBox(
        "edts",
        payload: elst + (duplicateEditListBox ? elst : Data())
    )
    let trak = isoBox(
        "trak",
        payload: tkhd + tkhdSibling + mdia + edts
            + (duplicateEditContainer ? edts : Data())
    )

    let validTREX = fullBox(version: version(for: "trex")) + uint32Data(1) + uint32Data(1)
        + uint32Data(defaultSampleDuration) + uint32Data(0) + uint32Data(0)
    let trex = isoBox("trex", payload: shortField == "trex" ? fullBox() : validTREX)
    let trexSibling = shortField == "trex"
        ? isoBox("junk", payload: uint32Data(1) + Data(repeating: 0, count: 16))
        : Data()
    let shouldIncludeMEHD = mehdDurationMovieTicks != nil
        || (unknownDurationEncoding != nil && includeMEHDForUnknownDuration)
    let mehdDuration = mehdDurationMovieTicks ?? 1_000
    precondition(mehdVersion == 1 || mehdDuration <= UInt64(UInt32.max))
    let mehd = !shouldIncludeMEHD
        ? Data()
        : isoBox(
            "mehd",
            payload: fullBox(
                version: unsupportedVersionField == "mehd" ? 2 : mehdVersion
            ) + (mehdVersion == 1
                ? uint64Data(mehdDuration)
                : uint32Data(UInt32(mehdDuration)))
        )
    let moov = isoBox(
        "moov",
        payload: mvhd + trak + isoBox("mvex", payload: mehd + trex + trexSibling)
    )

    let validTFHD = fullBox(version: version(for: "tfhd"), flags: 0x000008)
        + uint32Data(1) + uint32Data(defaultSampleDuration)
    let ftyp = isoBox("ftyp", payload: Data("isom".utf8))
    let sidx = includeTwoSIDXBoxes
        ? isoBox("sidx", payload: Data(repeating: 0, count: 12))
            + isoBox("sidx", payload: Data(repeating: 1, count: 12))
        : Data()
    let mediaFragments = fragmentSampleCounts.enumerated().reduce(into: Data()) {
        result, entry in
        let isFirst = entry.offset == 0
        let tfhd = isoBox(
            "tfhd",
            payload: isFirst && shortField == "tfhd" ? fullBox() : validTFHD
        )
        let tfhdSibling = isFirst && shortField == "tfhd"
            ? isoBox("junk", payload: uint32Data(1) + uint32Data(defaultSampleDuration))
            : Data()
        let startTicks: UInt32
        if let fragmentStartTicks,
            fragmentStartTicks.indices.contains(entry.offset)
        {
            startTicks = fragmentStartTicks[entry.offset]
        } else {
            startTicks = UInt32(entry.offset) * 48_000
        }
        let tfdt = isoBox(
            "tfdt",
            payload: isFirst && shortField == "tfdt"
                ? fullBox()
                : fullBox(version: version(for: "tfdt")) + uint32Data(startTicks)
        )
        let tfdtSibling = isFirst && shortField == "tfdt"
            ? isoBox("junk", payload: uint32Data(startTicks) + Data(repeating: 0, count: 4))
            : Data()
        let trun = isoBox(
            "trun",
            payload: isFirst && shortField == "trun"
                ? fullBox()
                : fullBox(version: version(for: "trun")) + uint32Data(entry.element)
        )
        let trunSibling = isFirst && shortField == "trun"
            ? isoBox("junk", payload: uint32Data(entry.element) + Data(repeating: 0, count: 4))
            : Data()
        let traf = isoBox(
            "traf",
            payload: tfhd + tfhdSibling + tfdt + tfdtSibling + trun + trunSibling
        )
        result.append(isoBox("moof", payload: traf))
        result.append(isoBox("mdat", payload: Data(repeating: 0, count: 128)))
    }
    return ftyp + moov + sidx + mediaFragments
}

private enum SyntheticUnknownDurationEncoding {
    case zero
    case allOnes

    var encodedValue: UInt32 {
        switch self {
        case .zero: 0
        case .allOnes: .max
        }
    }
}

private func int16Data(_ value: Int16) -> Data {
    let bits = UInt16(bitPattern: value)
    return Data([UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])
}

private func uint64Data(_ value: UInt64) -> Data {
    Data([
        UInt8((value >> 56) & 0xFF), UInt8((value >> 48) & 0xFF),
        UInt8((value >> 40) & 0xFF), UInt8((value >> 32) & 0xFF),
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ])
}
