import Foundation
import XCTest

@testable import LovelyMusic

@MainActor
final class GuardedLegacyIntegrationTests: XCTestCase {
    func testEveryIneligibleInitialReasonTransfersZeroFullBytesBeforeConsent() async throws {
        let enabled = featureSnapshot(rangeEnabled: true, killSwitch: false)
        let cases: [InitialLegacyCase] = [
            .init(
                name: "range-disabled",
                controls: featureSnapshot(rangeEnabled: false, killSwitch: false),
                cohortEligible: true,
                capability: .supported,
                network: .cellular(constrained: false, pathVersion: 1)
            ),
            .init(
                name: "cohort-excluded",
                controls: enabled,
                cohortEligible: false,
                capability: .supported,
                network: .cellular(constrained: false, pathVersion: 1)
            ),
            .init(
                name: "incompatible-tuple",
                controls: enabled,
                cohortEligible: true,
                capability: .incompatible,
                network: .cellular(constrained: false, pathVersion: 1)
            ),
            .init(
                name: "kill-switch",
                controls: featureSnapshot(rangeEnabled: true, killSwitch: true),
                cohortEligible: true,
                capability: .supported,
                network: .cellular(constrained: false, pathVersion: 1)
            ),
            .init(
                name: "expensive-wifi",
                controls: featureSnapshot(rangeEnabled: false, killSwitch: false),
                cohortEligible: true,
                capability: .supported,
                network: .wifi(expensive: true, constrained: false, pathVersion: 1)
            ),
            .init(
                name: "constrained-wifi-low-data",
                controls: featureSnapshot(rangeEnabled: false, killSwitch: false),
                cohortEligible: true,
                capability: .supported,
                network: .wifi(expensive: false, constrained: true, pathVersion: 1)
            ),
        ]

        for testCase in cases {
            let rangeEligible = GuardedLegacyRouting.isRangeEligible(
                controls: testCase.controls,
                cohortEligible: testCase.cohortEligible,
                capabilityStatus: testCase.capability
            )
            XCTAssertFalse(rangeEligible, testCase.name)
            let harness = GuardedAudioEngineHarness(
                network: testCase.network,
                rangeEligible: rangeEligible
            )

            harness.playRemoteSong()
            await waitUntil {
                harness.engine.transferConsentViewState != nil
            }

            let invocationCount = await harness.transport.invocationCount
            let fullBodyBytes = await harness.transport.responseBodyBytes
            let probeBodyBytes = await harness.probe.responseBodyBytes
            let probeInvocationBytes = await harness.probe.responseBodyBytesByInvocation
            let probeInvocationCount = await harness.probe.invocationCount
            let recordedRequest = await harness.gate.lastRequest
            let recordedQualification = await harness.probe.lastResult
            let request = try XCTUnwrap(recordedRequest)
            let qualified = try XCTUnwrap(recordedQualification)
            XCTAssertEqual(invocationCount, 0, testCase.name)
            XCTAssertEqual(fullBodyBytes, 0, testCase.name)
            XCTAssertEqual(probeInvocationCount, 2, testCase.name)
            XCTAssertEqual(probeInvocationBytes, [1, 1], testCase.name)
            XCTAssertTrue(
                probeInvocationBytes.allSatisfy { $0 <= 1 },
                testCase.name
            )
            XCTAssertEqual(probeBodyBytes, 2, testCase.name)
            XCTAssertEqual(request.validatedContentLength, 16, testCase.name)
            XCTAssertEqual(request.initialGeneration, qualified.generationScope, testCase.name)
            XCTAssertFalse(harness.engine.isPlaying, testCase.name)
            harness.engine.stop()
        }
    }

    func testRangeDisabledOnUnconstrainedWiFiStartsExactlyOneGatedLegacyTransfer() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false
        )

        harness.playRemoteSong()
        await waitUntil { harness.host.commands.containsRawPlay }

        let recordedRequest = await harness.gate.lastRequest
        let recordedQualification = await harness.probe.lastResult
        let request = try XCTUnwrap(recordedRequest)
        let invocationCount = await harness.transport.invocationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        let qualification = try XCTUnwrap(recordedQualification)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(responseBodyBytes, 16)
        XCTAssertEqual(request.validatedContentLength, 16)
        XCTAssertEqual(
            request.initialGeneration,
            qualification.generationScope
        )
        XCTAssertEqual(harness.host.commands.rawPlayCount, 1)
        XCTAssertTrue(harness.engine.isPlaying)
        XCTAssertNil(harness.engine.transferConsentViewState)
        harness.engine.stop()
    }

    func testNilDeclaredLengthUsesOriginValidatedLengthEndToEndAndPlaysOnce() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            descriptorContentLength: nil,
            probeOutcome: .success(totalLength: 16, bytes: 1)
        )

        harness.playRemoteSong()
        await waitUntil { harness.host.commands.containsRawPlay }

        let transportRequests = await harness.transport.requests
        let request = try XCTUnwrap(transportRequests.first)
        let pendingGateRequest = await harness.gate.lastRequest
        let gateRequest = try XCTUnwrap(pendingGateRequest)
        XCTAssertNil(request.descriptor.contentLength)
        XCTAssertEqual(request.validatedContentLength, 16)
        XCTAssertEqual(gateRequest.validatedContentLength, 16)
        let invocationCount = await harness.transport.invocationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(responseBodyBytes, 16)
        XCTAssertEqual(harness.host.commands.rawPlayCount, 1)
        XCTAssertTrue(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testProductionUncalibratedStorageProfileFailsClosedBeforeLegacyTransfer() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            storageProfile: .unavailable,
            requiredCalibrationID: nil
        )

        harness.playRemoteSong()
        await waitUntil { harness.engine.guardedPlaybackError != nil }

        XCTAssertEqual(
            harness.engine.guardedPlaybackError,
            .policyDenied(.cannotEstablishConservativeUpperBound)
        )
        let invocationCount = await harness.transport.invocationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(responseBodyBytes, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testConsentAcceptStartsOneAttemptAndDeclineDismissBackgroundRemainTruthful() async {
        let cellular = NetworkSnapshot.cellular(constrained: false, pathVersion: 1)

        let accepted = GuardedAudioEngineHarness(network: cellular, rangeEligible: false)
        accepted.playRemoteSong()
        await waitUntil { accepted.engine.transferConsentViewState != nil }
        accepted.engine.respondToTransferConsent(.accept)
        await waitUntil { await accepted.transport.invocationCount == 1 }
        let acceptedInvocations = await accepted.transport.invocationCount
        XCTAssertEqual(acceptedInvocations, 1)
        accepted.engine.stop()

        for disposition in [TransferConsentUserDisposition.decline, .dismissed] {
            let rejected = GuardedAudioEngineHarness(network: cellular, rangeEligible: false)
            rejected.playRemoteSong()
            await waitUntil { rejected.engine.transferConsentViewState != nil }
            rejected.engine.respondToTransferConsent(disposition)
            await waitUntil { rejected.engine.guardedPlaybackError != nil }

            XCTAssertEqual(rejected.engine.guardedPlaybackError, .transferConsentDeclined)
            XCTAssertTrue(rejected.engine.guardedPlaybackError?.isRecoverable == true)
            let rejectedInvocations = await rejected.transport.invocationCount
            let rejectedBytes = await rejected.transport.responseBodyBytes
            XCTAssertEqual(rejectedInvocations, 0)
            XCTAssertEqual(rejectedBytes, 0)
            XCTAssertFalse(rejected.engine.isPlaying)
            rejected.engine.stop()
        }

        let background = GuardedAudioEngineHarness(network: cellular, rangeEligible: false)
        background.playRemoteSong()
        await waitUntil { background.engine.transferConsentViewState != nil }
        background.engine.updateTransferConsentPresentation(
            applicationIsActive: false,
            phoneUIAvailable: false
        )
        await waitUntil { background.engine.guardedPlaybackError != nil }

        XCTAssertEqual(background.engine.guardedPlaybackError, .continueOnPhone)
        XCTAssertTrue(background.engine.guardedPlaybackError?.isRecoverable == true)
        let backgroundInvocations = await background.transport.invocationCount
        let backgroundBytes = await background.transport.responseBodyBytes
        XCTAssertEqual(backgroundInvocations, 0)
        XCTAssertEqual(backgroundBytes, 0)
        XCTAssertFalse(background.engine.isPlaying)
        background.engine.stop()
    }

    func testConsentPromptKeepsTokenUpdatesLatestSeekAndShowsConservativeEstimates() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false
        )
        harness.playRemoteSong()
        await waitUntil { harness.engine.transferConsentViewState != nil }
        let firstPrompt = try XCTUnwrap(harness.engine.transferConsentViewState)

        harness.engine.seek(to: 87)
        await waitUntil {
            harness.engine.transferConsentViewState?.targetSeconds == 87
        }
        let updatedPrompt = try XCTUnwrap(harness.engine.transferConsentViewState)

        XCTAssertEqual(updatedPrompt.token, firstPrompt.token)
        XCTAssertEqual(updatedPrompt.targetSeconds, 87)
        XCTAssertEqual(updatedPrompt.networkUpperBoundBytes, 16)
        XCTAssertEqual(updatedPrompt.temporaryStorageUpperBoundBytes, 40)

        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.transport.invocationCount == 1 }
        let requests = await harness.transport.requests
        XCTAssertEqual(requests.last?.targetSeconds, 87)
        harness.engine.stop()
    }

    func testPolicyChangeInvalidatesPresentedConsentAndStaleAcceptCannotTransfer() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false
        )
        harness.playRemoteSong()
        await waitUntil { harness.engine.transferConsentViewState != nil }

        let prompt = try XCTUnwrap(harness.engine.transferConsentViewState)
        let gateEvaluationsBeforePolicyChange = await harness.gate.evaluationCount
        let initialTransferInvocations = await harness.transport.invocationCount
        let initialFullBodyBytes = await harness.transport.responseBodyBytes
        let initialReservations = await harness.gate.allowedReservationIDs
        XCTAssertEqual(prompt.networkUpperBoundBytes, 16)
        XCTAssertEqual(initialTransferInvocations, 0)
        XCTAssertEqual(initialFullBodyBytes, 0)
        XCTAssertTrue(initialReservations.isEmpty)

        await harness.publishNetwork(
            .cellular(constrained: true, pathVersion: 2),
            notifyEngine: true
        )
        await waitUntil {
            guard case .failed = harness.engine.guardedPlaybackPhase else {
                return false
            }
            return await harness.gate.networkUpdateCount == 2
                && !harness.engine.hasPendingGuardedGateOperation
        }

        XCTAssertNil(harness.engine.transferConsentViewState)
        XCTAssertEqual(
            harness.engine.guardedPlaybackError,
            .policyDenied(.consentChallengeInvalidated)
        )
        XCTAssertTrue(harness.engine.guardedPlaybackError?.isRecoverable == true)
        XCTAssertFalse(harness.engine.isPlaying)

        // Models a stale alert callback that was already queued before the
        // policy-relevant path update invalidated its challenge.
        harness.engine.respondToTransferConsent(.accept)
        harness.engine.updateTransferConsentPresentation(
            applicationIsActive: false,
            phoneUIAvailable: false
        )
        await waitUntil {
            !harness.engine.hasPendingGuardedConsentOperation
                && !harness.engine.hasPendingGuardedGateOperation
        }

        XCTAssertNil(harness.engine.transferConsentViewState)
        XCTAssertEqual(
            harness.engine.guardedPlaybackError,
            .policyDenied(.consentChallengeInvalidated)
        )
        let finalGateEvaluations = await harness.gate.evaluationCount
        let finalReservations = await harness.gate.allowedReservationIDs
        let releasedReservations = await harness.gate.releasedReservationIDs
        let finalTransferInvocations = await harness.transport.invocationCount
        let finalFullBodyBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(finalGateEvaluations, gateEvaluationsBeforePolicyChange)
        XCTAssertTrue(finalReservations.isEmpty)
        XCTAssertTrue(releasedReservations.isEmpty)
        XCTAssertEqual(finalTransferInvocations, 0)
        XCTAssertEqual(finalFullBodyBytes, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testUnavailablePhonePresentationSetBeforePlayNeverTransfersOrPretendsPlayback() async {
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false
        )
        harness.engine.updateTransferConsentPresentation(
            applicationIsActive: false,
            phoneUIAvailable: false
        )

        harness.playRemoteSong()
        await waitUntil { harness.engine.guardedPlaybackError != nil }

        let invocations = await harness.transport.invocationCount
        let bodyBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(harness.engine.guardedPlaybackError, .continueOnPhone)
        XCTAssertNil(harness.engine.transferConsentViewState)
        XCTAssertEqual(invocations, 0)
        XCTAssertEqual(bodyBytes, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testBoundedProbeQualifiesTotalLengthWithAtMostOneBodyByte() async throws {
        let descriptor = StreamDescriptor.fixture(contentLength: nil)
        let tokens = ActivePlaybackTokens.freshSession(source: .legacyDownloadRemux)
        let probe = RecordingLegacyDescriptorProbe(
            outcomes: [.success(totalLength: 16, bytes: 1)]
        )

        let qualified = try await LegacyDescriptorQualifier(probe: probe).qualify(
            descriptor: descriptor,
            tokens: tokens
        )

        XCTAssertEqual(qualified.validatedContentLength, 16)
        XCTAssertEqual(qualified.metadataProbeResponseBodyBytes, 1)
        let probeInvocations = await probe.invocationCount
        let probeBytes = await probe.responseBodyBytes
        XCTAssertEqual(probeInvocations, 1)
        XCTAssertEqual(probeBytes, 1)
    }

    func testNonnilDeclaredLengthStillRequiresOriginProbeAndConflictNeverReachesGate() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            descriptorContentLength: 16,
            probeOutcome: .success(totalLength: 15, bytes: 1)
        )

        harness.playRemoteSong()
        await waitUntil { harness.engine.guardedPlaybackError != nil }

        XCTAssertEqual(
            harness.engine.guardedPlaybackError,
            .descriptorQualificationFailed(.originContentLengthMismatch)
        )
        let probeInvocations = await harness.probe.invocationCount
        let gateEvaluations = await harness.gate.evaluationCount
        let transportInvocations = await harness.transport.invocationCount
        let transportBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(probeInvocations, 2)
        XCTAssertEqual(gateEvaluations, 0)
        XCTAssertEqual(transportInvocations, 0)
        XCTAssertEqual(transportBytes, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testProbeFailureIsTypedAndCannotFallThroughToBareURLTransfer() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            descriptorContentLength: nil,
            probeOutcome: .failure
        )

        harness.playRemoteSong()
        await waitUntil { harness.engine.guardedPlaybackError != nil }

        XCTAssertEqual(
            harness.engine.guardedPlaybackError,
            .descriptorQualificationFailed(.cannotEstablishValidatedGeneration)
        )
        let probeInvocations = await harness.probe.invocationCount
        let gateEvaluations = await harness.gate.evaluationCount
        let transportInvocations = await harness.transport.invocationCount
        let transportBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(probeInvocations, 2)
        XCTAssertEqual(gateEvaluations, 0)
        XCTAssertEqual(transportInvocations, 0)
        XCTAssertEqual(transportBytes, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testUnsafeProbeAccountingAndMismatchedGenerationFailTypedBeforeGate() async {
        let cases: [(
            String,
            RecordingLegacyDescriptorProbe.Outcome,
            LegacyDescriptorQualificationError
        )] = [
            (
                "more-than-one-body-byte",
                .success(totalLength: 16, bytes: 2),
                .probeByteCeilingExceeded
            ),
            (
                "mismatched-generation-session",
                .mismatchedScope(totalLength: 16, bytes: 1),
                .generationScopeMismatch
            ),
            (
                "mismatched-generation-source",
                .mismatchedSource(totalLength: 16, bytes: 1),
                .generationScopeMismatch
            ),
        ]

        for (name, outcome, expectedError) in cases {
            let harness = GuardedAudioEngineHarness(
                network: .wifi(expensive: false, constrained: false, pathVersion: 1),
                rangeEligible: false,
                descriptorContentLength: nil,
                probeOutcome: outcome
            )
            harness.playRemoteSong()
            await waitUntil { harness.engine.guardedPlaybackError != nil }

            let probeInvocations = await harness.probe.invocationCount
            let gateEvaluations = await harness.gate.evaluationCount
            let transferInvocations = await harness.transport.invocationCount
            let fullBodyBytes = await harness.transport.responseBodyBytes
            XCTAssertEqual(
                harness.engine.guardedPlaybackError,
                .descriptorQualificationFailed(expectedError),
                name
            )
            XCTAssertEqual(probeInvocations, 2, name)
            XCTAssertEqual(gateEvaluations, 0, name)
            XCTAssertEqual(transferInvocations, 0, name)
            XCTAssertEqual(fullBodyBytes, 0, name)
            XCTAssertFalse(harness.engine.isPlaying, name)
            harness.engine.stop()
        }
    }

    func testPathChangeCancelsBeforeNextChunkAndRegatesBeforeMoreBytes() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenWaitForCancellation, .complete]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        await harness.publishNetwork(
            .wifi(expensive: true, constrained: false, pathVersion: 2),
            notifyEngine: true
        )
        await waitUntil {
            let cancellationCount = await harness.transport.cancellationCount
            return harness.engine.transferConsentViewState != nil
                && cancellationCount == 1
        }

        let invocationCount = await harness.transport.invocationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        let releasedReservations = await harness.gate.releasedReservationIDs
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(responseBodyBytes, 1)
        XCTAssertEqual(releasedReservations.count, 1)
        XCTAssertFalse(harness.engine.isPlaying)

        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.transport.invocationCount == 2 }
        harness.engine.stop()
    }

    func testStaleTransportCompletionAfterPathCancellationCannotPublishOrDoubleRelease() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenIgnoreCancellationUntilReleased]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        await harness.publishNetwork(
            .wifi(expensive: true, constrained: false, pathVersion: 2),
            notifyEngine: true
        )
        await waitUntil { await harness.transport.cancellationCount == 1 }

        XCTAssertNil(harness.engine.transferConsentViewState)
        let releasesBeforeAcknowledgement = await harness.gate.releasedReservationIDs
        XCTAssertTrue(releasesBeforeAcknowledgement.isEmpty)
        await waitUntil { await harness.transport.staleCompletionIsHeld }
        await harness.transport.releaseStaleCompletion()
        await waitUntil { harness.engine.transferConsentViewState != nil }

        let releases = await harness.gate.releasedReservationIDs
        let eventKinds = await harness.events.kinds
        let remuxInvocations = await harness.remuxer.invocationCount
        let transferInvocations = await harness.transport.invocationCount
        let bodyBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(releases.count, 1)
        XCTAssertTrue(eventKinds.isEmpty)
        XCTAssertEqual(remuxInvocations, 0)
        XCTAssertEqual(transferInvocations, 1)
        XCTAssertEqual(bodyBytes, 1)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testLegacyWatchdogCancelsRealDriverThenCleansAndReleasesExactlyOnce() async {
        let clock = IntegrationPlaybackClock()
        let scheduler = IntegrationPlaybackWatchdogScheduler()
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenWaitForCancellation],
            monotonicClock: clock,
            watchdogScheduler: scheduler
        )
        harness.playRemoteSong()
        await waitUntil {
            await harness.transport.responseBodyBytes == 1
                && scheduler.startedSleeps > 0
        }
        await harness.publishNetwork(
            .cellular(constrained: false, pathVersion: 2),
            notifyEngine: false
        )

        clock.advance(by: 10_000)
        await waitUntil {
            let cancellationCount = await harness.transport.cancellationCount
            let releasedReservationIDs = await harness.gate.releasedReservationIDs
            return harness.engine.transferConsentViewState != nil
                && cancellationCount == 1
                && releasedReservationIDs.count == 1
        }

        let removed = await harness.files.removedURLs
        let artifacts = await harness.files.lastArtifacts
        let released = await harness.gate.releasedReservationIDs
        let invocations = await harness.transport.invocationCount
        let bytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(removed.filter { $0 == artifacts?.rawURL }.count, 1)
        XCTAssertEqual(removed.filter { $0 == artifacts?.remuxedURL }.count, 1)
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(bytes, 1)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testValidatedDriverProgressNearOriginalDeadlineRefreshesHostWatchdog() async throws {
        let clock = IntegrationPlaybackClock()
        let scheduler = IntegrationPlaybackWatchdogScheduler()
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.secondByteWhenReleasedThenWaitForCancellation],
            monotonicClock: clock,
            watchdogScheduler: scheduler
        )
        harness.playRemoteSong()
        await waitUntil {
            await harness.transport.responseBodyBytes == 1
                && scheduler.activeSleeps == 1
        }
        let startedBeforeRefresh = scheduler.startedSleeps
        let completedBeforeRefresh = scheduler.completedSleeps
        let noProgressDeadline = try XCTUnwrap(
            PlaybackWatchdog.deadlines(
                for: .legacyDownload,
                networkClass: .wifiUnconstrained
            ).noProgress
        )

        clock.advance(by: noProgressDeadline - 1)
        await waitUntil { await harness.transport.secondProgressIsHeld }
        await harness.transport.releaseSecondProgressByte()
        await waitUntil { await harness.transport.responseBodyBytes == 2 }
        clock.advance(by: 1)
        await waitUntil {
            scheduler.completedSleeps == completedBeforeRefresh + 1
                && scheduler.startedSleeps == startedBeforeRefresh + 1
        }

        let cancellationCount = await harness.transport.cancellationCount
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertNil(harness.engine.guardedPlaybackError)
        clock.advance(by: noProgressDeadline - 1)
        await waitUntil { await harness.transport.cancellationCount == 1 }
        harness.engine.stop()
    }

    func testStaleSessionProgressCannotRefreshCurrentHostWatchdog() async throws {
        let clock = IntegrationPlaybackClock()
        let scheduler = IntegrationPlaybackWatchdogScheduler()
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [
                .staleSecondByteAfterCancellationWhenReleased,
                .oneByteThenWaitForCancellation,
            ],
            monotonicClock: clock,
            watchdogScheduler: scheduler
        )
        harness.playRemoteSong(id: "task8-watchdog-old")
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        let oldRequests = await harness.transport.requests
        let oldTokens = try XCTUnwrap(oldRequests.first?.tokens)

        harness.playRemoteSong(id: "task8-watchdog-current")
        await waitUntil {
            let invocationCount = await harness.transport.invocationCount
            let responseBodyBytes = await harness.transport.responseBodyBytes
            let cancellationCount = await harness.transport.cancellationCount
            return invocationCount == 2
                && responseBodyBytes == 2
                && cancellationCount == 1
        }
        let currentRequests = await harness.transport.requests
        let currentTokens = try XCTUnwrap(currentRequests.last?.tokens)
        XCTAssertFalse(harness.engine.acceptsGuardedLegacyTokens(oldTokens))
        XCTAssertTrue(harness.engine.acceptsGuardedLegacyTokens(currentTokens))
        XCTAssertFalse(
            harness.engine.acceptsGuardedLegacyTokens(
                .freshSession(source: .legacyDownloadRemux)
            )
        )
        let noProgressDeadline = try XCTUnwrap(
            PlaybackWatchdog.deadlines(
                for: .legacyDownload,
                networkClass: .wifiUnconstrained
            ).noProgress
        )

        clock.advance(by: noProgressDeadline - 1)
        await waitUntil { await harness.transport.staleProgressIsHeld }
        await harness.transport.releaseStaleProgress()
        await waitUntil { await harness.transport.staleProgressEmissionCount == 1 }
        clock.advance(by: 1)
        await waitUntil { await harness.transport.cancellationCount == 2 }

        XCTAssertEqual(harness.engine.currentTrack?.id, "task8-watchdog-current")
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testPauseAtFinalByteWinsOverPlayingRequestSnapshot() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenCompleteWhenReleased]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        harness.engine.playPause()
        await waitUntil { await harness.transport.completionIsHeld }
        await harness.transport.releaseCompletion()
        await waitUntil { harness.host.commands.contains(.installRemuxedArtifact) }

        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertEqual(harness.engine.currentTime, 0)
        let containsNeutralRawArtifact = await harness.events.containsNeutralRawArtifact
        XCTAssertTrue(containsNeutralRawArtifact)
        XCTAssertEqual(harness.host.commands.rawPlayCount, 0)
        harness.engine.stop()
    }

    func testSeekDuringFinalByteSuppressesRawPlaybackAndLastTargetWins() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenCompleteWhenReleased]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        harness.engine.seek(to: 41)
        harness.engine.seek(to: 87)
        await waitUntil { await harness.transport.completionIsHeld }
        await harness.transport.releaseCompletion()
        await waitUntil { harness.host.commands.preparedSeekTarget == 87 }

        XCTAssertEqual(harness.engine.currentTime, 87)
        XCTAssertEqual(harness.host.commands.rawPlayCount, 0)
        XCTAssertEqual(
            harness.host.commands,
            [.installRemuxedArtifact, .seekLocalArtifact(targetSeconds: 87)]
        )
        harness.engine.stop()
    }

    func testByteBearingFailureUsesLatestPathAndReentersGateWithFreshReservation() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenFailWhenReleased, .complete]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        let initialReservations = await harness.gate.allowedReservationIDs
        let firstReservation = try XCTUnwrap(initialReservations.first)

        await harness.publishNetwork(
            .cellular(constrained: false, pathVersion: 2),
            notifyEngine: false
        )
        await waitUntil { await harness.transport.failureIsHeld }
        await harness.transport.releaseFailure()
        await waitUntil {
            let evaluationCount = await harness.gate.evaluationCount
            let request = await harness.gate.lastRequest
            return evaluationCount == 2
                && request?.intent == .transportRetry
                && harness.engine.transferConsentViewState != nil
        }

        let recordedRetryRequest = await harness.gate.lastRequest
        let retryRequest = try XCTUnwrap(recordedRetryRequest)
        let releasedReservations = await harness.gate.releasedReservationIDs
        let invocationCount = await harness.transport.invocationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(retryRequest.intent, .transportRetry)
        XCTAssertEqual(releasedReservations, [firstReservation])
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(responseBodyBytes, 1)
        XCTAssertFalse(harness.engine.isPlaying)

        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.transport.invocationCount == 2 }
        let reservations = await harness.gate.allowedReservationIDs
        XCTAssertEqual(reservations.count, 2)
        let firstAllowedReservation = try XCTUnwrap(reservations.first)
        let secondAllowedReservation = try XCTUnwrap(reservations.dropFirst().first)
        XCTAssertNotEqual(firstAllowedReservation, secondAllowedReservation)
        harness.engine.stop()
    }

    func testLateProgressFromFailedAttemptCannotRefreshRetryWatchdog() async throws {
        let clock = IntegrationPlaybackClock()
        let scheduler = IntegrationPlaybackWatchdogScheduler()
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [
                .oneByteThenFailAndRetainProgress,
                .oneByteThenWaitForCancellation,
            ],
            monotonicClock: clock,
            watchdogScheduler: scheduler
        )

        harness.playRemoteSong()
        await waitUntil {
            let invocationCount = await harness.transport.invocationCount
            let responseBodyBytes = await harness.transport.responseBodyBytes
            return invocationCount == 2 && responseBodyBytes == 2
        }
        let requests = await harness.transport.requests
        let oldRequest = try XCTUnwrap(requests.first)
        let retryRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(retryRequest.tokens.sessionID, oldRequest.tokens.sessionID)
        XCTAssertNotEqual(
            retryRequest.tokens.currentSourceAttempt.id,
            oldRequest.tokens.currentSourceAttempt.id
        )

        clock.advance(by: 14)
        await harness.transport.emitRetainedStaleProgress(totalBytes: 2)
        clock.advance(by: 1)
        await waitUntil { await harness.transport.cancellationCount == 1 }

        let staleEmissions = await harness.transport.staleProgressEmissionCount
        let invocationCount = await harness.transport.invocationCount
        XCTAssertEqual(staleEmissions, 1)
        XCTAssertEqual(invocationCount, 2)
        harness.engine.stop()
    }

    func testInitiallyMeteredFailureHasZeroAutomaticRetryUntilExplicitRetry() async throws {
        let clock = IntegrationPlaybackClock()
        let scheduler = IntegrationPlaybackWatchdogScheduler()
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenFailWhenReleased, .complete],
            monotonicClock: clock,
            watchdogScheduler: scheduler
        )
        harness.playRemoteSong()
        await waitUntil { harness.engine.transferConsentViewState != nil }
        let initialToken = try XCTUnwrap(
            harness.engine.transferConsentViewState?.token
        )
        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        let allowedReservations = await harness.gate.allowedReservationIDs
        let firstReservation = try XCTUnwrap(allowedReservations.first)

        await waitUntil { await harness.transport.failureIsHeld }
        await harness.transport.releaseFailure()
        await waitUntil { harness.engine.guardedPlaybackError != nil }
        clock.advance(by: 10_000)
        await scheduler.drainUntilQuiescent()

        let invocationsBeforeRetry = await harness.transport.invocationCount
        let bytesBeforeRetry = await harness.transport.responseBodyBytes
        let releasedBeforeRetry = await harness.gate.releasedReservationIDs
        XCTAssertEqual(harness.engine.guardedPlaybackError, .legacyTransportFailed)
        XCTAssertEqual(invocationsBeforeRetry, 1)
        XCTAssertEqual(bytesBeforeRetry, 1)
        XCTAssertEqual(releasedBeforeRetry, [firstReservation])
        XCTAssertNil(harness.engine.transferConsentViewState)
        XCTAssertFalse(harness.engine.isPlaying)

        harness.engine.retryGuardedPlayback()
        await waitUntil { harness.engine.transferConsentViewState != nil }
        let explicitRetryPrompt = try XCTUnwrap(
            harness.engine.transferConsentViewState
        )
        let invocationsAwaitingExplicitConsent = await harness.transport.invocationCount
        let bytesAwaitingExplicitConsent = await harness.transport.responseBodyBytes
        XCTAssertNotEqual(explicitRetryPrompt.token, initialToken)
        XCTAssertEqual(invocationsAwaitingExplicitConsent, 1)
        XCTAssertEqual(bytesAwaitingExplicitConsent, 1)

        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.transport.invocationCount == 2 }
        harness.engine.stop()
    }

    func testRecoveryServiceOnlyReportsDetectedStallAndNeverRetriesOrAdvancesDirectly() async {
        let delegate = RecoveryDelegateProbe()
        let clock = IntegrationRecoveryClock()
        let scheduler = IntegrationRecoveryScheduler()
        var reportedEvents: [PlaybackRecoveryEvent] = []
        let service = PlaybackRecoveryService(
            clock: clock,
            scheduler: scheduler,
            eventSink: { event in reportedEvents.append(event) }
        )
        service.delegate = delegate

        service.startStallDetection()
        clock.advance(by: 11)
        scheduler.fireRepeatingCheck()
        await scheduler.drainMainActor()
        clock.advance(by: 3)
        scheduler.resumeAllSleeps()
        await scheduler.drainMainActor()

        XCTAssertEqual(
            reportedEvents,
            [.stallDetected(trackID: "task8-recovery", position: 12)]
        )
        XCTAssertEqual(delegate.resumeCount, 0)
        XCTAssertEqual(delegate.nextCount, 0)
        XCTAssertEqual(delegate.resolverCount, 0)
        XCTAssertEqual(delegate.recoveryLoadCount, 0)
        XCTAssertEqual(delegate.retryStateUpdateCount, 0)
        XCTAssertFalse(service.hasAttemptedRetry)
        service.stopStallDetection()
    }

    func testConsentEstimateProjectionNeverRoundsApprovedBoundsDownToZero() {
        XCTAssertEqual(TransferEstimateFormatter.upperBoundString(bytes: 16), "up to 16 bytes")
        XCTAssertEqual(TransferEstimateFormatter.upperBoundString(bytes: 40), "up to 40 bytes")
        XCTAssertEqual(TransferEstimateFormatter.upperBoundString(bytes: 1_025), "up to 1.1 KB")
    }

    func testDeterministicStorageDenialIsNotPresentedAsRecoverable() {
        XCTAssertFalse(
            GuardedPlaybackError.policyDenied(.cannotEstablishConservativeUpperBound)
                .isRecoverable
        )
        XCTAssertTrue(GuardedPlaybackError.legacyTransportFailed.isRecoverable)
        XCTAssertTrue(GuardedPlaybackError.continueOnPhone.isRecoverable)
    }

    func testPhoneUIStartsUnavailableBeforeAnyPresenterAppears() async {
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false,
            phoneUIAvailable: false
        )

        harness.playRemoteSong()
        await waitUntil { harness.engine.guardedPlaybackError == .continueOnPhone }

        XCTAssertNil(harness.engine.transferConsentViewState)
        let invocationCount = await harness.transport.invocationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(responseBodyBytes, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testBackgroundTruthWinsIfAlertDismissalCallbackArrivesFirst() async {
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false
        )
        harness.engine.updateTransferConsentPresentation(
            applicationIsActive: true,
            phoneUIAvailable: true
        )
        harness.playRemoteSong()
        await waitUntil { harness.engine.transferConsentViewState != nil }

        harness.engine.respondToTransferConsent(.dismissed)
        harness.engine.updateTransferConsentPresentation(
            applicationIsActive: false,
            phoneUIAvailable: false
        )

        XCTAssertEqual(harness.engine.guardedPlaybackError, .continueOnPhone)
        XCTAssertNil(harness.engine.transferConsentViewState)
        let invocationCount = await harness.transport.invocationCount
        XCTAssertEqual(invocationCount, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testConsentAcceptedThenBackgroundedBeforeHeldGateReturnsCannotStartBytes() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false,
            holdAcceptedGateEvaluation: true
        )
        harness.engine.updateTransferConsentPresentation(
            applicationIsActive: true,
            phoneUIAvailable: true
        )
        harness.playRemoteSong()
        await waitUntil { harness.engine.transferConsentViewState != nil }

        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.gate.acceptedEvaluationIsHeld }
        harness.engine.updateTransferConsentPresentation(
            applicationIsActive: false,
            phoneUIAvailable: false
        )
        await harness.gate.releaseAcceptedEvaluation()
        await waitUntil { await harness.gate.releasedReservationIDs.count == 1 }

        XCTAssertEqual(harness.engine.guardedPlaybackError, .continueOnPhone)
        let invocationCount = await harness.transport.invocationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        let releasedReservationIDs = await harness.gate.releasedReservationIDs
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(responseBodyBytes, 0)
        XCTAssertEqual(releasedReservationIDs.count, 1)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testQualifiedAttemptScopeExactlyMatchesGateAndDriverAttempt() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.invocationCount == 1 }

        let transportRequests = await harness.transport.requests
        let request = try XCTUnwrap(transportRequests.first)
        let recordedProbeResult = await harness.probe.lastResult
        let qualification = try XCTUnwrap(recordedProbeResult)
        guard case .attemptOnly(let sessionID, let sourceAttemptID, _) =
            qualification.generationScope
        else {
            return XCTFail("Legacy qualification must be bound to the active attempt")
        }
        XCTAssertEqual(sessionID, request.tokens.sessionID)
        XCTAssertEqual(sourceAttemptID, request.tokens.currentSourceAttempt.id)
        let recordedGateRequest = await harness.gate.lastRequest
        let gateRequest = try XCTUnwrap(recordedGateRequest)
        XCTAssertEqual(gateRequest.initialGeneration, qualification.generationScope)
        harness.engine.stop()
    }

    func testStopWaitsForOldDriverAckThenReleasesThroughOriginalGateExactlyOnce() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenIgnoreCancellationUntilReleased]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        harness.engine.stop()
        await waitUntil { await harness.transport.cancellationCount == 1 }
        let releasesBeforeAcknowledgement = await harness.gate.releasedReservationIDs
        XCTAssertEqual(releasesBeforeAcknowledgement.count, 0)

        await waitUntil { await harness.transport.staleCompletionIsHeld }
        await harness.transport.releaseStaleCompletion()
        await waitUntil { await harness.gate.releasedReservationIDs.count == 1 }
        let releasesAfterAcknowledgement = await harness.gate.releasedReservationIDs
        XCTAssertEqual(releasesAfterAcknowledgement.count, 1)
        XCTAssertTrue(harness.host.commands.isEmpty)
        XCTAssertFalse(harness.engine.isPlaying)
    }

    func testReplacementWaitsForOldAckAndLateFailureCannotMutateNewSession() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [
                .oneByteThenIgnoreCancellationUntilReleased,
                .complete,
            ]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        let oldReservation = await harness.gate.allowedReservationIDs.first

        harness.playRemoteSong(id: "task8-replacement")
        await waitUntil {
            await harness.transport.cancellationCount == 1
                && harness.host.commands.containsRawPlay
        }
        let releasesBeforeAcknowledgement = await harness.gate.releasedReservationIDs
        XCTAssertEqual(
            releasesBeforeAcknowledgement.filter { $0 == oldReservation }.count,
            0
        )

        await waitUntil { await harness.transport.staleCompletionIsHeld }
        await harness.transport.releaseStaleCompletion()
        await waitUntil {
            await harness.gate.releasedReservationIDs.filter { $0 == oldReservation }.count == 1
        }
        XCTAssertNil(harness.engine.guardedPlaybackError)
        XCTAssertEqual(harness.engine.currentTrack?.id, "task8-replacement")
        XCTAssertEqual(harness.host.commands.rawPlayCount, 1)
        XCTAssertTrue(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testLatestNetworkSnapshotSeedsReplacementSessionAndMeteredFailureDoesNotAutoRetry()
        async
    {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenFailWhenReleased, .complete]
        )
        await harness.publishNetwork(
            .cellular(constrained: false, pathVersion: 2),
            notifyEngine: true
        )
        harness.engine.updateTransferConsentPresentation(
            applicationIsActive: true,
            phoneUIAvailable: true
        )
        harness.playRemoteSong()
        await waitUntil { harness.engine.transferConsentViewState != nil }
        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        await waitUntil { await harness.transport.failureIsHeld }
        await harness.transport.releaseFailure()
        await waitUntil { harness.engine.guardedPlaybackError == .legacyTransportFailed }

        let invocationCount = await harness.transport.invocationCount
        XCTAssertEqual(invocationCount, 1)
        XCTAssertNil(harness.engine.transferConsentViewState)
        let gateEvaluationCount = await harness.gate.evaluationCount
        XCTAssertEqual(gateEvaluationCount, 2)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testCoordinatorCancelsBeforeAwaitingBlockedGateNetworkUpdate() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenWaitForCancellation]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        await harness.gate.holdNextNetworkUpdate()

        harness.engine.receivePlaybackNetworkSnapshot(
            .wifi(expensive: true, constrained: false, pathVersion: 2)
        )
        await waitUntil { await harness.gate.networkUpdateIsHeld }

        let cancellationCount = await harness.transport.cancellationCount
        let responseBodyBytes = await harness.transport.responseBodyBytes
        let releasedReservationIDs = await harness.gate.releasedReservationIDs
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(responseBodyBytes, 1)
        XCTAssertEqual(releasedReservationIDs.count, 0)
        await harness.gate.releaseNetworkUpdate()
        harness.engine.stop()
    }

    func testRangeCandidateFailsClosedWithoutFabricatingPlayableOrSeekEvents() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: true
        )
        harness.playRemoteSong()
        await waitUntil { harness.engine.guardedPlaybackError == .rangePathUnavailable }

        XCTAssertEqual(harness.engine.guardedPlaybackError, .rangePathUnavailable)
        XCTAssertTrue(harness.host.commands.isEmpty)
        let invocationCount = await harness.transport.invocationCount
        XCTAssertEqual(invocationCount, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testSuccessfulArtifactsRemainOwnedUntilStopThenCleanExactlyOnce() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false
        )
        harness.playRemoteSong()
        await waitUntil { harness.host.commands.contains(.installRemuxedArtifact) }
        let removalsBeforeStop = await harness.files.removedURLs
        XCTAssertTrue(removalsBeforeStop.isEmpty)

        harness.engine.stop()
        await waitUntil { await harness.files.removedURLs.count == 2 }
        let removed = await harness.files.removedURLs
        let artifacts = await harness.files.lastArtifacts
        XCTAssertEqual(removed.filter { $0 == artifacts?.rawURL }.count, 1)
        XCTAssertEqual(removed.filter { $0 == artifacts?.remuxedURL }.count, 1)
    }

    func testSecondRemuxFailureStopsTruthfullyCleansAndReleasesOnce() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            remuxOutcomes: [.failure, .failure]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.remuxer.invocationCount == 2 }
        await waitUntil { harness.engine.guardedPlaybackError == .legacyRemuxFailed }
        await waitUntil {
            let releases = await harness.gate.releasedReservationIDs
            let removals = await harness.files.removedURLs
            return releases.count == 1 && removals.count == 2
        }

        XCTAssertFalse(harness.engine.isPlaying)
        let releasesAfterFailure = await harness.gate.releasedReservationIDs
        let removalsAfterFailure = await harness.files.removedURLs
        XCTAssertEqual(releasesAfterFailure.count, 1)
        XCTAssertEqual(removalsAfterFailure.count, 2)
        XCTAssertFalse(harness.host.commands.contains(.installRemuxedArtifact))
        harness.engine.stop()
        let releasesAfterStop = await harness.gate.releasedReservationIDs
        let removalsAfterStop = await harness.files.removedURLs
        XCTAssertEqual(releasesAfterStop.count, 1)
        XCTAssertEqual(removalsAfterStop.count, 2)
    }

    func testNonzeroRemuxInstallsPausedWaitsForVerifiedPhysicalSeekThenResumes() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenCompleteWhenReleased]
        )
        harness.artifactHost.holdNextSeek()
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        harness.engine.seek(to: 41)
        harness.engine.seek(to: 87)
        await waitUntil { await harness.transport.completionIsHeld }
        await harness.transport.releaseCompletion()
        await waitUntil { harness.artifactHost.seekIsHeld }

        XCTAssertEqual(
            harness.artifactHost.events,
            [
                .installRemuxed,
                .seek(targetSeconds: 87),
            ]
        )
        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertFalse(harness.artifactHost.events.contains(.play))

        harness.artifactHost.releaseHeldSeek(confirmedPosition: 87)
        await waitUntil {
            guard case .playing(let localAttempt) = harness.engine.guardedPlaybackPhase else {
                return false
            }
            return localAttempt.source == .remuxCache
                && harness.artifactHost.events.last == .play
                && !harness.engine.hasPendingGuardedArtifactOperation
        }
        XCTAssertEqual(harness.engine.currentTime, 87, accuracy: 0.25)
        XCTAssertTrue(harness.engine.isPlaying)
        guard case .playing(let localAttempt) = harness.engine.guardedPlaybackPhase else {
            return XCTFail("Remux playback must settle in coordinator playing state")
        }
        XCTAssertEqual(localAttempt.source, .remuxCache)
        XCTAssertNil(harness.engine.guardedPlaybackError)
        harness.engine.stop()
    }

    func testPauseWhilePhysicalSeekIsHeldPreventsDelayedAutoplay() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenCompleteWhenReleased]
        )
        harness.artifactHost.holdNextSeek()
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        harness.engine.seek(to: 87)
        await waitUntil { await harness.transport.completionIsHeld }
        await harness.transport.releaseCompletion()
        await waitUntil { harness.artifactHost.seekIsHeld }

        harness.engine.playPause()
        harness.artifactHost.releaseHeldSeek(confirmedPosition: 87)
        await waitUntil {
            !harness.artifactHost.seekIsHeld
                && !harness.engine.hasPendingGuardedArtifactOperation
        }

        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertFalse(harness.artifactHost.events.contains(.play))
        XCTAssertEqual(harness.engine.currentTime, 87, accuracy: 0.25)
        harness.engine.stop()
    }

    func testRawToRemuxHandoffPreservesObservedLivePositionBeforeResume() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            remuxOutcomes: [.holdThenSuccess]
        )
        harness.playRemoteSong()
        await waitUntil {
            let remuxIsHeld = await harness.remuxer.isHeld
            return harness.artifactHost.events.contains(.installRaw)
                && remuxIsHeld
        }
        harness.artifactHost.setCurrentPosition(23.5)
        await harness.remuxer.releaseHeldRemux()
        await waitUntil {
            guard case .playing(let localAttempt) = harness.engine.guardedPlaybackPhase else {
                return false
            }
            return localAttempt.source == .remuxCache
                && harness.artifactHost.events.contains(.seek(targetSeconds: 23.5))
                && !harness.engine.hasPendingGuardedArtifactOperation
        }

        XCTAssertEqual(
            Array(harness.artifactHost.events.suffix(3)),
            [
                .installRemuxed,
                .seek(targetSeconds: 23.5),
                .play,
            ]
        )
        XCTAssertEqual(harness.engine.currentTime, 23.5, accuracy: 0.25)
        XCTAssertTrue(harness.engine.isPlaying)
        guard case .playing(let localAttempt) = harness.engine.guardedPlaybackPhase else {
            return XCTFail("Raw-to-remux handoff must settle in coordinator playing state")
        }
        XCTAssertEqual(localAttempt.source, .remuxCache)
        XCTAssertNil(harness.engine.guardedPlaybackError)
        harness.engine.stop()
    }

    func testLatestSeekBackToZeroStillPerformsPhysicalSeekBeforeResume() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenCompleteWhenReleased]
        )
        harness.artifactHost.holdNextSeek()
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        harness.engine.seek(to: 87)
        harness.engine.seek(to: 0)
        await waitUntil { await harness.transport.completionIsHeld }
        await harness.transport.releaseCompletion()
        await waitUntil { harness.artifactHost.seekIsHeld }

        XCTAssertEqual(
            Array(harness.artifactHost.events.suffix(2)),
            [
                .installRemuxed,
                .seek(targetSeconds: 0),
            ],
            "phase=\(String(describing: harness.engine.guardedPlaybackPhase)) error=\(String(describing: harness.engine.guardedPlaybackError)) pendingArtifact=\(harness.engine.hasPendingGuardedArtifactOperation)"
        )
        XCTAssertFalse(harness.engine.isPlaying)
        harness.artifactHost.releaseHeldSeek(confirmedPosition: 0)
        await waitUntil {
            guard case .playing(let localAttempt) = harness.engine.guardedPlaybackPhase else {
                return false
            }
            return localAttempt.source == .remuxCache
                && harness.artifactHost.events.last == .play
                && !harness.engine.hasPendingGuardedArtifactOperation
        }
        XCTAssertEqual(harness.engine.currentTime, 0, accuracy: 0.01)
        guard case .playing(let localAttempt) = harness.engine.guardedPlaybackPhase else {
            return XCTFail("Explicit seek-to-zero must settle in playing state")
        }
        XCTAssertEqual(localAttempt.source, .remuxCache)
        harness.engine.stop()
    }

    func testStopAtScheduledRemuxEntryDisposesDownloadedOnlyResourceExactlyOnce()
        async throws
    {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            holdInitialGateEvaluation: true
        )
        harness.remuxEffectProbe.stopEngineOnNextEntry { [weak engine = harness.engine] in
            engine?.stop()
        }

        harness.playRemoteSong(id: "task8-downloaded-before-remux-stop")
        await waitUntil { await harness.gate.initialEvaluationIsHeld }
        harness.engine.seek(to: 87)
        await harness.gate.releaseInitialEvaluation()
        await waitUntil {
            harness.remuxEffectProbe.invocationCount == 1
        }

        let recordedArtifacts = await harness.files.lastArtifacts
        let artifacts = try XCTUnwrap(recordedArtifacts)
        let transportRequests = await harness.transport.requests
        let transferRequest = try XCTUnwrap(transportRequests.first)
        let allowedReservations = await harness.gate.allowedReservationIDs
        let reservation = try XCTUnwrap(allowedReservations.first)
        await waitUntil {
            let removals = await harness.files.removedURLs
            let releases = await harness.gate.releasedReservationIDs
            let trackedAttemptCount = await harness.driver.trackedAttemptCount
            let remuxInvocationCount = await harness.remuxer.invocationCount
            return removals.filter { $0 == artifacts.rawURL }.count == 1
                && removals.filter { $0 == artifacts.remuxedURL }.count == 1
                && releases.filter { $0 == reservation }.count == 1
                && trackedAttemptCount == 0
                && remuxInvocationCount == 0
        }
        let removals = await harness.files.removedURLs
        let releases = await harness.gate.releasedReservationIDs
        let trackedAttemptCount = await harness.driver.trackedAttemptCount
        let remuxInvocationCount = await harness.remuxer.invocationCount
        XCTAssertEqual(removals.filter { $0 == artifacts.rawURL }.count, 1)
        XCTAssertEqual(removals.filter { $0 == artifacts.remuxedURL }.count, 1)
        XCTAssertEqual(releases.filter { $0 == reservation }.count, 1)
        XCTAssertEqual(trackedAttemptCount, 0)
        XCTAssertEqual(remuxInvocationCount, 0)
        XCTAssertEqual(harness.remuxEffectProbe.attempts.count, 1)
        XCTAssertEqual(
            harness.remuxEffectProbe.attempts.first?.sourceAttempt.id,
            transferRequest.tokens.currentSourceAttempt.id
        )
        XCTAssertTrue(harness.host.commands.isEmpty)
        XCTAssertFalse(harness.artifactHost.events.contains(.installRaw))
        XCTAssertFalse(harness.artifactHost.events.contains(.installRemuxed))
        XCTAssertFalse(
            harness.artifactHost.events.contains { event in
                if case .seek = event { return true }
                return false
            }
        )
        XCTAssertFalse(harness.artifactHost.events.contains(.play))
        XCTAssertFalse(harness.engine.isPlaying)

        harness.engine.stop()
        await drainGuardedMainActorQueue()
        let removalsAfterLateWork = await harness.files.removedURLs
        let releasesAfterLateWork = await harness.gate.releasedReservationIDs
        let trackedAfterLateWork = await harness.driver.trackedAttemptCount
        let remuxAfterLateWork = await harness.remuxer.invocationCount
        XCTAssertEqual(
            removalsAfterLateWork.filter { $0 == artifacts.rawURL }.count,
            1
        )
        XCTAssertEqual(
            removalsAfterLateWork.filter { $0 == artifacts.remuxedURL }.count,
            1
        )
        XCTAssertEqual(
            releasesAfterLateWork.filter { $0 == reservation }.count,
            1
        )
        XCTAssertEqual(trackedAfterLateWork, 0)
        XCTAssertEqual(remuxAfterLateWork, 0)
        XCTAssertEqual(harness.remuxEffectProbe.invocationCount, 1)
        XCTAssertTrue(harness.host.commands.isEmpty)
        XCTAssertFalse(harness.artifactHost.events.contains(.installRaw))
        XCTAssertFalse(harness.artifactHost.events.contains(.installRemuxed))
        XCTAssertFalse(
            harness.artifactHost.events.contains { event in
                if case .seek = event { return true }
                return false
            }
        )
        XCTAssertFalse(harness.artifactHost.events.contains(.play))
    }

    func testStopBeforePreparedRemuxOwnershipClaimDisposesOnceAndSuppressesStaleLocalEffect()
        async throws
    {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenCompleteWhenReleased]
        )
        harness.artifactHost.holdNextSeek()
        harness.host.stopEngineOnNextRemuxInstall { [weak engine = harness.engine] in
            engine?.stop()
        }
        harness.playRemoteSong(id: "task8-prepared-remux-stop")
        await waitUntil { await harness.transport.completionIsHeld }
        let recordedArtifacts = await harness.files.lastArtifacts
        let artifacts = try XCTUnwrap(recordedArtifacts)
        let allowedReservations = await harness.gate.allowedReservationIDs
        let oldReservation = try XCTUnwrap(allowedReservations.first)

        harness.engine.seek(to: 87)
        await harness.transport.releaseCompletion()
        await waitUntil {
            let removed = await harness.files.removedURLs
            let releases = await harness.gate.releasedReservationIDs
            let cleanupCompleted = removed.filter {
                $0 == artifacts.rawURL || $0 == artifacts.remuxedURL
            }.count == 2
            return harness.host.remuxInstallStopHookInvocationCount == 1
                && releases.filter { $0 == oldReservation }.count == 1
                && (cleanupCompleted || harness.artifactHost.seekIsHeld)
        }

        let removals = await harness.files.removedURLs
        let releases = await harness.gate.releasedReservationIDs
        let trackedAttemptCount = await harness.driver.trackedAttemptCount
        XCTAssertEqual(removals.filter { $0 == artifacts.rawURL }.count, 1)
        XCTAssertEqual(removals.filter { $0 == artifacts.remuxedURL }.count, 1)
        XCTAssertEqual(releases.filter { $0 == oldReservation }.count, 1)
        XCTAssertEqual(trackedAttemptCount, 0)
        XCTAssertFalse(harness.artifactHost.events.contains(.installRemuxed))
        XCTAssertFalse(harness.artifactHost.events.contains(.play))

        harness.artifactHost.releaseHeldSeek(confirmedPosition: nil)
        await waitUntil {
            !harness.artifactHost.seekIsHeld
                && !harness.engine.hasPendingGuardedArtifactOperation
        }
        XCTAssertFalse(
            harness.artifactHost.events.contains { event in
                if case .seek = event { return true }
                return false
            }
        )
        XCTAssertFalse(
            harness.host.commands.contains { command in
                if case .seekLocalArtifact = command { return true }
                return false
            }
        )
        harness.engine.stop()
        let removalsAfterSecondStop = await harness.files.removedURLs
        let releasesAfterSecondStop = await harness.gate.releasedReservationIDs
        XCTAssertEqual(
            removalsAfterSecondStop.filter { $0 == artifacts.rawURL }.count,
            1
        )
        XCTAssertEqual(
            removalsAfterSecondStop.filter { $0 == artifacts.remuxedURL }.count,
            1
        )
        XCTAssertEqual(
            releasesAfterSecondStop.filter { $0 == oldReservation }.count,
            1
        )
        let trackedAfterSecondStop = await harness.driver.trackedAttemptCount
        XCTAssertEqual(trackedAfterSecondStop, 0)
    }

    func testStaleRemuxFailureAfterReplacementCleansOldArtifactsWithoutPoisoningNewSession()
        async throws
    {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.complete, .complete],
            remuxOutcomes: [.holdThenLateWriteFailureIgnoringCancellation, .success]
        )
        harness.playRemoteSong(id: "task8-stale-remux-old")
        await waitUntil { await harness.remuxer.isHeld }
        let recordedOldArtifacts = await harness.files.lastArtifacts
        let oldArtifacts = try XCTUnwrap(recordedOldArtifacts)
        let allowedBeforeReplacement = await harness.gate.allowedReservationIDs
        let oldReservation = try XCTUnwrap(allowedBeforeReplacement.first)

        harness.playRemoteSong(id: "task8-stale-remux-new")
        await waitUntil { await harness.transport.invocationCount == 2 }
        await waitUntil {
            guard case .playing = harness.engine.guardedPlaybackPhase else {
                return false
            }
            return harness.engine.currentTrack?.id == "task8-stale-remux-new"
        }
        let artifactEventsBeforeStaleFailure = harness.artifactHost.events
        let hostCommandsBeforeStaleFailure = harness.host.commands

        await harness.remuxer.releaseHeldRemux()
        await waitUntil {
            let remuxIsHeld = await harness.remuxer.isHeld
            let releases = await harness.gate.releasedReservationIDs
            let trackedAttemptCount = await harness.driver.trackedAttemptCount
            return !remuxIsHeld
                && releases.filter { $0 == oldReservation }.count == 1
                && trackedAttemptCount == 0
        }
        await drainGuardedMainActorQueue()

        let removals = await harness.files.removedURLs
        let releases = await harness.gate.releasedReservationIDs
        XCTAssertEqual(removals.filter { $0 == oldArtifacts.rawURL }.count, 1)
        XCTAssertEqual(removals.filter { $0 == oldArtifacts.remuxedURL }.count, 1)
        let remuxedFileSize = try await harness.files.fileSize(oldArtifacts.remuxedURL)
        XCTAssertEqual(remuxedFileSize, 0)
        XCTAssertEqual(releases.filter { $0 == oldReservation }.count, 1)
        XCTAssertEqual(harness.engine.currentTrack?.id, "task8-stale-remux-new")
        XCTAssertNil(harness.engine.guardedPlaybackError)
        XCTAssertEqual(harness.artifactHost.events, artifactEventsBeforeStaleFailure)
        XCTAssertEqual(harness.host.commands, hostCommandsBeforeStaleFailure)
        let trackedAttemptCount = await harness.driver.trackedAttemptCount
        XCTAssertEqual(trackedAttemptCount, 0)
        harness.engine.stop()
    }

    func testCancelledStaleGateQualificationCannotOverwriteFreshPathPrompt() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            probeOutcomes: [
                .success(totalLength: 16, bytes: 1),
                .holdThenFailureIgnoringCancellation,
                .success(totalLength: 16, bytes: 1),
            ]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.probe.heldFailureCount == 1 }

        await harness.publishNetwork(
            .wifi(expensive: true, constrained: false, pathVersion: 2),
            notifyEngine: true
        )
        await waitUntil { harness.engine.transferConsentViewState != nil }
        await harness.probe.releaseNextFailure()
        await waitUntil { await harness.probe.heldFailureCount == 0 }
        await waitUntil { !harness.engine.hasPendingGuardedGateOperation }

        let transportInvocations = await harness.transport.invocationCount
        XCTAssertNotNil(harness.engine.transferConsentViewState)
        XCTAssertNil(harness.engine.guardedPlaybackError)
        XCTAssertEqual(transportInvocations, 0)
        XCTAssertFalse(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testGuardedItemFailurePhysicallyPausesInstalledRawArtifact() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            remuxOutcomes: [.holdThenSuccess]
        )
        harness.playRemoteSong()
        await waitUntil {
            let remuxIsHeld = await harness.remuxer.isHeld
            return remuxIsHeld && harness.artifactHost.events.last == .play
        }

        harness.engine.reportPlaybackItemFailure()
        XCTAssertEqual(harness.artifactHost.events.last, .pause)
        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertEqual(harness.engine.guardedPlaybackError, .legacyTransportFailed)
        await harness.remuxer.releaseHeldRemux()
        harness.engine.stop()
    }

    func testGuardedStallPhysicallyPausesInstalledRawArtifact() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            remuxOutcomes: [.holdThenSuccess]
        )
        harness.playRemoteSong()
        await waitUntil {
            let remuxIsHeld = await harness.remuxer.isHeld
            return remuxIsHeld && harness.artifactHost.events.last == .play
        }

        harness.engine.receivePlaybackRecoveryEvent(
            .stallDetected(trackID: Song.fixture.id, position: 0)
        )
        XCTAssertEqual(harness.artifactHost.events.last, .pause)
        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertEqual(harness.engine.guardedPlaybackError, .legacyTransportFailed)
        await harness.remuxer.releaseHeldRemux()
        harness.engine.stop()
    }

    func testReplacementSynchronouslyPausesOldInstalledArtifactBeforeNewSession() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.complete, .complete],
            remuxOutcomes: [.holdThenSuccess, .success]
        )
        harness.playRemoteSong(id: "task8-pause-old")
        await waitUntil {
            let remuxIsHeld = await harness.remuxer.isHeld
            return remuxIsHeld && harness.artifactHost.events.last == .play
        }

        harness.playRemoteSong(id: "task8-pause-new")
        XCTAssertEqual(harness.artifactHost.events.last, .pause)
        XCTAssertFalse(harness.engine.isPlaying)
        await harness.remuxer.releaseHeldRemux()
        await waitUntil { await harness.transport.invocationCount == 2 }
        harness.engine.stop()
    }

    func testEngineDeinitDisposesCompletedOwnedArtifactsExactlyOnce() async throws {
        var harness: GuardedAudioEngineHarness? = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false
        )
        harness?.playRemoteSong()
        await waitUntil {
            guard let harness else { return false }
            return harness.host.commands.contains(.installRemuxedArtifact)
                && !harness.engine.hasPendingGuardedArtifactOperation
        }
        let files = try XCTUnwrap(harness?.files)
        let recordedArtifacts = await files.lastArtifacts
        let artifacts = try XCTUnwrap(recordedArtifacts)
        weak let weakEngine = harness?.engine

        harness = nil
        await waitUntil { weakEngine == nil }
        await waitUntil { await files.removedURLs.count == 2 }

        let removals = await files.removedURLs
        XCTAssertEqual(removals.filter { $0 == artifacts.rawURL }.count, 1)
        XCTAssertEqual(removals.filter { $0 == artifacts.remuxedURL }.count, 1)
    }

    func testOldHeldGateDecisionCannotMutateReplacementAndReleasesOriginalReservation() async
        throws
    {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            holdInitialGateEvaluation: true
        )
        harness.playRemoteSong(id: "task8-old-gate")
        await waitUntil { await harness.gate.initialEvaluationIsHeld }
        let heldReservationID = await harness.gate.heldInitialReservationID
        let oldReservation = try XCTUnwrap(heldReservationID)

        harness.playRemoteSong(id: "task8-new-gate")
        await waitUntil { harness.host.commands.containsRawPlay }
        let releasesBeforeDecision = await harness.gate.releasedReservationIDs
        XCTAssertFalse(releasesBeforeDecision.contains(oldReservation))

        await harness.gate.releaseInitialEvaluation()
        await waitUntil {
            (await harness.gate.releasedReservationIDs).filter { $0 == oldReservation }.count == 1
        }
        XCTAssertEqual(harness.engine.currentTrack?.id, "task8-new-gate")
        XCTAssertNil(harness.engine.guardedPlaybackError)
        XCTAssertEqual(harness.host.commands.rawPlayCount, 1)
        harness.engine.stop()
    }

    func testStaleHeldConsentGrantFailureCannotOverwriteReplacementSession() async {
        let harness = GuardedAudioEngineHarness(
            network: .cellular(constrained: false, pathVersion: 1),
            rangeEligible: false,
            holdConsentAcceptanceReturningNil: true
        )
        harness.playRemoteSong(id: "task8-old-consent")
        await waitUntil { harness.engine.transferConsentViewState != nil }
        harness.engine.respondToTransferConsent(.accept)
        await waitUntil { await harness.gate.consentAcceptanceIsHeld }

        await harness.publishNetwork(
            .wifi(expensive: false, constrained: false, pathVersion: 2),
            notifyEngine: false
        )
        harness.playRemoteSong(id: "task8-new-consent")
        await waitUntil { harness.host.commands.containsRawPlay }
        await harness.gate.releaseConsentAcceptance()
        await waitUntil {
            !(await harness.gate.consentAcceptanceIsHeld)
                && !harness.engine.hasPendingGuardedConsentOperation
        }

        XCTAssertEqual(harness.engine.currentTrack?.id, "task8-new-consent")
        XCTAssertNil(harness.engine.guardedPlaybackError)
        XCTAssertEqual(harness.host.commands.rawPlayCount, 1)
        XCTAssertTrue(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testTwoStaleAndCurrentHeldResolverFailuresKeepBudgetsSessionScoped() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            resolverOutcomes: [
                .holdThenFailureIgnoringCancellation,
                .holdThenFailureIgnoringCancellation,
                .success,
            ]
        )
        harness.playRemoteSong(id: "task8-old-resolver")
        await waitUntil { await harness.resolver.heldFailureCount == 1 }
        harness.playRemoteSong(id: "task8-new-resolver")
        await waitUntil { await harness.resolver.heldFailureCount == 2 }

        await harness.resolver.releaseNextFailure()
        await waitUntil { await harness.resolver.heldFailureCount == 1 }
        await harness.resolver.releaseNextFailure()
        await waitUntil { harness.host.commands.containsRawPlay }

        XCTAssertEqual(harness.engine.currentTrack?.id, "task8-new-resolver")
        XCTAssertNil(harness.engine.guardedPlaybackError)
        let resolverInvocationCount = await harness.resolver.invocationCount
        XCTAssertEqual(resolverInvocationCount, 3)
        XCTAssertTrue(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testCancellationIgnoringOldTransportFailureCannotPoisonReplacement() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [
                .oneByteThenFailIgnoringCancellationWhenReleased,
                .complete,
            ]
        )
        harness.playRemoteSong(id: "task8-old-download")
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        let recordedOldReservation = await harness.gate.allowedReservationIDs.first
        guard let oldReservation = recordedOldReservation else {
            XCTFail("Expected the old transfer to own a reservation")
            return
        }

        harness.playRemoteSong(id: "task8-new-download")
        await waitUntil { await harness.transport.staleFailureIsHeld }
        await waitUntil {
            let invocationCount = await harness.transport.invocationCount
            return harness.engine.currentTrack?.id == "task8-new-download"
                && invocationCount == 2
                && harness.host.commands.rawPlayCount == 1
                && harness.engine.isPlaying
        }
        let allowedReservations = await harness.gate.allowedReservationIDs
        guard let newReservation = allowedReservations.first(where: {
            $0 != oldReservation
        }) else {
            XCTFail("Expected the replacement transfer to own a fresh reservation")
            return
        }
        await waitUntil {
            let staleFailureIsHeld = await harness.transport.staleFailureIsHeld
            let releases = await harness.gate.releasedReservationIDs
            guard case .playing(let attempt) = harness.engine.guardedPlaybackPhase else {
                return false
            }
            return staleFailureIsHeld
                && attempt.source == .remuxCache
                && releases.filter { $0 == newReservation }.count == 1
                && harness.host.commands.contains(.installRemuxedArtifact)
                && !harness.engine.hasPendingGuardedArtifactOperation
        }
        let releasesBeforeAcknowledgement = await harness.gate.releasedReservationIDs
        XCTAssertEqual(
            releasesBeforeAcknowledgement.filter { $0 == oldReservation }.count,
            0
        )
        XCTAssertEqual(
            releasesBeforeAcknowledgement.filter { $0 == newReservation }.count,
            1
        )
        let hostCommandsBeforeAcknowledgement = harness.host.commands

        await harness.transport.releaseStaleFailure()
        await waitUntil {
            let failureIsHeld = await harness.transport.staleFailureIsHeld
            let releases = await harness.gate.releasedReservationIDs
            return !failureIsHeld
                && releases.filter { $0 == oldReservation }.count == 1
                && releases.filter { $0 == newReservation }.count == 1
        }
        let releases = await harness.gate.releasedReservationIDs
        XCTAssertEqual(releases.filter { $0 == oldReservation }.count, 1)
        XCTAssertEqual(releases.filter { $0 == newReservation }.count, 1)
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(harness.engine.currentTrack?.id, "task8-new-download")
        XCTAssertNil(harness.engine.guardedPlaybackError)
        XCTAssertEqual(harness.host.commands.rawPlayCount, 1)
        XCTAssertEqual(harness.host.commands, hostCommandsBeforeAcknowledgement)
        XCTAssertTrue(harness.engine.isPlaying)
        harness.engine.stop()
    }

    func testPrefetchedNextInvalidatesOldGuardedTransferBeforeLocalFastPath() async throws {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenIgnoreCancellationUntilReleased]
        )
        let first = Song.fixture(id: "task8-prefetch-old")
        let next = Song.fixture(id: "task8-prefetch-local")
        let cache = AudioCacheManager()
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("task8-prefetch-\(UUID().uuidString).m4a")
        try Data([0]).write(to: localURL)
        cache.registerFile(videoId: next.id, fileURL: localURL)
        defer { cache.clearAll() }
        harness.engine.audioCacheManager = cache
        harness.playRemoteSong(id: first.id, queue: [first, next])
        await waitUntil { await harness.transport.responseBodyBytes == 1 }
        harness.engine.prepareNextLocalItemForPlayback()

        harness.engine.next()
        await waitUntil { await harness.transport.cancellationCount == 1 }
        XCTAssertEqual(harness.engine.currentTrack?.id, next.id)
        let releasesBeforeAcknowledgement = await harness.gate.releasedReservationIDs
        XCTAssertEqual(releasesBeforeAcknowledgement.count, 0)

        await waitUntil { await harness.transport.staleCompletionIsHeld }
        await harness.transport.releaseStaleCompletion()
        await waitUntil { await harness.gate.releasedReservationIDs.count == 1 }
        XCTAssertEqual(harness.engine.currentTrack?.id, next.id)
        XCTAssertTrue(harness.host.commands.isEmpty)
        harness.engine.stop()
    }

    func testSuccessfulArtifactReplacementCleansPriorOwnershipExactlyOnce() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.complete, .complete]
        )
        harness.playRemoteSong(id: "task8-owned-first")
        await waitUntil { harness.host.commands.contains(.installRemuxedArtifact) }
        let firstArtifacts = await harness.files.lastArtifacts
        harness.playRemoteSong(id: "task8-owned-second")
        await waitUntil { await harness.transport.invocationCount == 2 }
        await waitUntil { await harness.files.removedURLs.count >= 2 }

        let removed = await harness.files.removedURLs
        XCTAssertEqual(removed.filter { $0 == firstArtifacts?.rawURL }.count, 1)
        XCTAssertEqual(removed.filter { $0 == firstArtifacts?.remuxedURL }.count, 1)
        harness.engine.stop()
    }

    func testGuardedItemFailureStopsThroughCoordinatorWithoutIndependentRetry() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenIgnoreCancellationUntilReleased, .complete]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        harness.engine.reportPlaybackItemFailure()
        await waitUntil { await harness.transport.cancellationCount == 1 }
        let invocationsBeforeAcknowledgement = await harness.transport.invocationCount
        let releasesBeforeAcknowledgement = await harness.gate.releasedReservationIDs
        XCTAssertEqual(invocationsBeforeAcknowledgement, 1)
        XCTAssertEqual(releasesBeforeAcknowledgement.count, 0)
        XCTAssertEqual(harness.engine.guardedPlaybackError, .legacyTransportFailed)
        XCTAssertFalse(harness.engine.isPlaying)

        await waitUntil { await harness.transport.staleCompletionIsHeld }
        await harness.transport.releaseStaleCompletion()
        await waitUntil { await harness.gate.releasedReservationIDs.count == 1 }
        let invocationsAfterAcknowledgement = await harness.transport.invocationCount
        XCTAssertEqual(invocationsAfterAcknowledgement, 1)
        harness.engine.stop()
    }

    func testGuardedStallSignalStopsThroughCoordinatorWithoutIndependentRetry() async {
        let harness = GuardedAudioEngineHarness(
            network: .wifi(expensive: false, constrained: false, pathVersion: 1),
            rangeEligible: false,
            transportOutcomes: [.oneByteThenIgnoreCancellationUntilReleased, .complete]
        )
        harness.playRemoteSong()
        await waitUntil { await harness.transport.responseBodyBytes == 1 }

        harness.engine.receivePlaybackRecoveryEvent(
            .stallDetected(trackID: Song.fixture.id, position: 0)
        )
        await waitUntil { await harness.transport.cancellationCount == 1 }
        let invocationCount = await harness.transport.invocationCount
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(harness.engine.guardedPlaybackError, .legacyTransportFailed)
        XCTAssertFalse(harness.engine.isPlaying)
        await waitUntil { await harness.transport.staleCompletionIsHeld }
        await harness.transport.releaseStaleCompletion()
        await waitUntil { await harness.gate.releasedReservationIDs.count == 1 }
        harness.engine.stop()
    }

    func testUnguardedRecoveryRetryBehaviorRemainsAvailableForReviewDemoPath() async {
        let delegate = RecoveryDelegateProbe()
        let service = PlaybackRecoveryService()
        service.delegate = delegate

        service.retryPlayback(for: .fixture(id: "task8-recovery"))
        await waitUntil {
            delegate.resolverCount == 1
                && delegate.recoveryLoadCount == 1
                && delegate.retryStateUpdateCount == 1
        }

        XCTAssertTrue(service.hasAttemptedRetry)
        XCTAssertEqual(delegate.resumeCount, 0)
        XCTAssertEqual(delegate.nextCount, 0)
    }

    func testReviewModeCompositionNeverInstallsGuardedInnerTubePlayback() {
        let key = "feature_flags_cache"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let data = try! JSONSerialization.data(
            withJSONObject: ["review_mode_enabled": true]
        )
        UserDefaults.standard.set(data, forKey: key)
        let container = DIContainer(featureFlagManager: FeatureFlagManager())

        XCTAssertTrue(container.playerRepository is DemoPlayerRepository)
        XCTAssertFalse(container.audioEngine.hasGuardedLegacyPlaybackConfiguration)
        XCTAssertTrue(container.audioEngine.streamHeaders.isEmpty)
    }
}

private struct InitialLegacyCase {
    let name: String
    let controls: PlaybackFeatureSnapshot
    let cohortEligible: Bool
    let capability: PlaybackCapabilityStatus
    let network: NetworkSnapshot
}

@MainActor
private final class GuardedAudioEngineHarness {
    let engine: AudioEngine
    let resolver: IntegrationDescriptorResolver
    let probe: RecordingLegacyDescriptorProbe
    let gate: RecordingLegacyTransferGate
    let transport: IntegrationLegacyTransport
    let files: IntegrationLegacyFileSystem
    let network: MutableNetworkSnapshot
    let events: IntegrationLegacyEventRecorder
    let remuxer: IntegrationMediaRemuxer
    let driver: LegacyPlaybackDriver
    let host: IntegrationLegacyHostRecorder
    let artifactHost: IntegrationLegacyArtifactHost
    let remuxEffectProbe: IntegrationLegacyRemuxEffectProbe

    init(
        network initialNetwork: NetworkSnapshot,
        rangeEligible: Bool,
        phoneUIAvailable: Bool = true,
        descriptorContentLength: Int64? = 16,
        probeOutcome: RecordingLegacyDescriptorProbe.Outcome = .success(
            totalLength: 16,
            bytes: 1
        ),
        probeOutcomes: [RecordingLegacyDescriptorProbe.Outcome]? = nil,
        storageProfile: PlaybackStorageCompatibilityProfile = .fixture,
        requiredCalibrationID: String? = "task8-fixture",
        transportOutcomes: [IntegrationLegacyTransport.Outcome] = [.complete],
        remuxOutcomes: [IntegrationMediaRemuxer.Outcome] = [.success],
        holdAcceptedGateEvaluation: Bool = false,
        holdInitialGateEvaluation: Bool = false,
        holdConsentAcceptanceReturningNil: Bool = false,
        resolverOutcomes: [IntegrationDescriptorResolver.Outcome] = [.success],
        monotonicClock: (any PlaybackMonotonicClock)? = nil,
        watchdogScheduler: (any PlaybackWatchdogScheduling)? = nil
    ) {
        let capacity = FixedPlaybackCapacity(bytes: 1_000_000)
        let ledger = PlaybackStorageReservationLedger(capacityProvider: capacity)
        let storage = PlaybackStoragePolicy(
            compatibilityProfile: storageProfile,
            requiredCalibrationID: requiredCalibrationID,
            reservationLedger: ledger
        )
        gate = RecordingLegacyTransferGate(
            network: initialNetwork,
            storagePolicy: storage,
            holdAcceptedEvaluation: holdAcceptedGateEvaluation,
            holdInitialEvaluation: holdInitialGateEvaluation,
            holdConsentAcceptanceReturningNil: holdConsentAcceptanceReturningNil
        )
        probe = RecordingLegacyDescriptorProbe(
            outcomes: probeOutcomes ?? [probeOutcome]
        )
        files = IntegrationLegacyFileSystem()
        transport = IntegrationLegacyTransport(
            outcomes: transportOutcomes,
            fileSystem: files
        )
        events = IntegrationLegacyEventRecorder()
        remuxer = IntegrationMediaRemuxer(
            outcomes: remuxOutcomes,
            fileSystem: files
        )
        host = IntegrationLegacyHostRecorder()
        artifactHost = IntegrationLegacyArtifactHost()
        remuxEffectProbe = IntegrationLegacyRemuxEffectProbe()
        self.network = MutableNetworkSnapshot(initialNetwork)
        let events = self.events
        let audioEngine = AudioEngine()
        engine = audioEngine
        let guardedAudioEngine = audioEngine
        driver = LegacyPlaybackDriver(
            transport: transport,
            remuxer: remuxer,
            fileSystem: files,
            clock: IntegrationLegacyClock(),
            tokenValidator: { [weak guardedAudioEngine] tokens in
                guardedAudioEngine?.acceptsGuardedLegacyTokens(tokens) ?? false
            },
            eventSink: { event in
                await events.record(event)
            }
        )
        let descriptor = StreamDescriptor.fixture(contentLength: descriptorContentLength)
        resolver = IntegrationDescriptorResolver(
            descriptor: descriptor,
            outcomes: resolverOutcomes
        )
        let integrationResolver = resolver
        let mutableNetwork = self.network
        engine.installGuardedLegacyPlayback(
            GuardedLegacyPlaybackConfiguration(
                descriptorResolver: { _ in try await integrationResolver.resolve() },
                descriptorQualifier: LegacyDescriptorQualifier(probe: probe),
                transferGate: gate,
                legacyDriver: driver,
                initialNetworkSnapshot: initialNetwork,
                currentNetworkSnapshot: { await mutableNetwork.current },
                isRangeEligible: { _ in rangeEligible },
                legacyRemuxWillBegin: { [remuxEffectProbe] attempt in
                    remuxEffectProbe.record(attempt)
                },
                artifactHost: artifactHost,
                disposeCompletedArtifactSynchronously: { [files] resource in
                    files.disposeCompletedArtifactSynchronously(resource)
                },
                monotonicClock: monotonicClock,
                watchdogScheduler: watchdogScheduler,
                hostCommandSink: { [host] command in
                    host.record(command)
                }
            )
        )
        if phoneUIAvailable {
            engine.updateTransferConsentPresentation(
                applicationIsActive: true,
                phoneUIAvailable: true
            )
        }
    }

    func playRemoteSong(
        id: String = Song.fixture.id,
        queue: [Song] = []
    ) {
        engine.play(song: .fixture(id: id), fromQueue: queue)
    }

    func publishNetwork(
        _ snapshot: NetworkSnapshot,
        notifyEngine: Bool
    ) async {
        await network.set(snapshot)
        await gate.updateNetwork(snapshot)
        if notifyEngine {
            engine.receivePlaybackNetworkSnapshot(snapshot)
        }
    }
}

private actor MutableNetworkSnapshot {
    private(set) var current: NetworkSnapshot

    init(_ current: NetworkSnapshot) {
        self.current = current
    }

    func set(_ snapshot: NetworkSnapshot) {
        current = snapshot
    }
}

private actor RecordingLegacyTransferGate: GuardedLegacyTransferGating {
    private let gate: PlaybackFullResourceTransferGate
    private let storagePolicy: PlaybackStoragePolicy
    private(set) var requests: [FullResourceTransferRequest] = []
    private(set) var allowedReservationIDs: [StorageReservationID] = []
    private(set) var releasedReservationIDs: [StorageReservationID] = []
    private(set) var networkUpdateCount = 0
    private var shouldHoldAcceptedEvaluation: Bool
    private(set) var acceptedEvaluationIsHeld = false
    private var acceptedEvaluationContinuations: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldNetworkUpdate = false
    private(set) var networkUpdateIsHeld = false
    private var networkUpdateContinuations: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldInitialEvaluation: Bool
    private(set) var initialEvaluationIsHeld = false
    private(set) var heldInitialReservationID: StorageReservationID?
    private var initialEvaluationContinuations: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldConsentAcceptanceReturningNil: Bool
    private(set) var consentAcceptanceIsHeld = false
    private var consentAcceptanceContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        network: NetworkSnapshot,
        storagePolicy: PlaybackStoragePolicy,
        holdAcceptedEvaluation: Bool = false,
        holdInitialEvaluation: Bool = false,
        holdConsentAcceptanceReturningNil: Bool = false
    ) {
        gate = PlaybackFullResourceTransferGate(network: network, storagePolicy: storagePolicy)
        self.storagePolicy = storagePolicy
        shouldHoldAcceptedEvaluation = holdAcceptedEvaluation
        shouldHoldInitialEvaluation = holdInitialEvaluation
        self.shouldHoldConsentAcceptanceReturningNil = holdConsentAcceptanceReturningNil
    }

    var evaluationCount: Int { requests.count }
    var lastRequest: FullResourceTransferRequest? { requests.last }

    func updateNetwork(_ snapshot: NetworkSnapshot) async {
        if shouldHoldNetworkUpdate {
            shouldHoldNetworkUpdate = false
            networkUpdateIsHeld = true
            await withCheckedContinuation { continuation in
                networkUpdateContinuations.append(continuation)
            }
            networkUpdateIsHeld = false
        }
        await gate.updateNetwork(snapshot)
        networkUpdateCount += 1
    }

    func evaluate(
        _ request: FullResourceTransferRequest,
        consentGrant: FullTransferConsentGrant?
    ) async -> FullResourceTransferDecision {
        requests.append(request)
        let decision = await gate.evaluate(request, consentGrant: consentGrant)
        if consentGrant == nil, shouldHoldInitialEvaluation {
            shouldHoldInitialEvaluation = false
            if case .allow(let reservationID) = decision {
                heldInitialReservationID = reservationID
            }
            initialEvaluationIsHeld = true
            await withCheckedContinuation { continuation in
                initialEvaluationContinuations.append(continuation)
            }
            initialEvaluationIsHeld = false
        }
        if consentGrant != nil, shouldHoldAcceptedEvaluation {
            shouldHoldAcceptedEvaluation = false
            acceptedEvaluationIsHeld = true
            await withCheckedContinuation { continuation in
                acceptedEvaluationContinuations.append(continuation)
            }
            acceptedEvaluationIsHeld = false
        }
        if case .allow(let reservationID) = decision {
            allowedReservationIDs.append(reservationID)
        }
        return decision
    }

    func acceptConsent(
        _ challenge: FullTransferConsentChallenge
    ) async -> FullTransferConsentGrant? {
        let grant = await gate.acceptConsent(challenge)
        if shouldHoldConsentAcceptanceReturningNil {
            shouldHoldConsentAcceptanceReturningNil = false
            consentAcceptanceIsHeld = true
            await withCheckedContinuation { continuation in
                consentAcceptanceContinuations.append(continuation)
            }
            consentAcceptanceIsHeld = false
            return nil
        }
        return grant
    }

    func releaseReservation(_ reservationID: StorageReservationID) async {
        releasedReservationIDs.append(reservationID)
        await storagePolicy.release(reservationID)
    }

    func holdNextNetworkUpdate() {
        shouldHoldNetworkUpdate = true
    }

    func releaseNetworkUpdate() {
        let continuations = networkUpdateContinuations
        networkUpdateContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseAcceptedEvaluation() {
        let continuations = acceptedEvaluationContinuations
        acceptedEvaluationContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseInitialEvaluation() {
        let continuations = initialEvaluationContinuations
        initialEvaluationContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseConsentAcceptance() {
        let continuations = consentAcceptanceContinuations
        consentAcceptanceContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor IntegrationDescriptorResolver {
    enum Outcome {
        case success
        case holdThenFailureIgnoringCancellation
    }

    private let descriptor: StreamDescriptor
    private var outcomes: [Outcome]
    private(set) var invocationCount = 0
    private(set) var heldFailureCount = 0
    private var failureContinuations: [CheckedContinuation<Void, Never>] = []

    init(descriptor: StreamDescriptor, outcomes: [Outcome]) {
        self.descriptor = descriptor
        self.outcomes = outcomes
    }

    func resolve() async throws -> StreamDescriptor {
        invocationCount += 1
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        switch outcome {
        case .success:
            return descriptor
        case .holdThenFailureIgnoringCancellation:
            heldFailureCount += 1
            await withCheckedContinuation { continuation in
                failureContinuations.append(continuation)
            }
            heldFailureCount -= 1
            throw URLError(.timedOut)
        }
    }

    func releaseNextFailure() {
        guard !failureContinuations.isEmpty else { return }
        failureContinuations.removeFirst().resume()
    }
}

private actor RecordingLegacyDescriptorProbe: LegacyDescriptorProbing {
    enum Outcome {
        case success(totalLength: Int64, bytes: Int64)
        case mismatchedScope(totalLength: Int64, bytes: Int64)
        case mismatchedSource(totalLength: Int64, bytes: Int64)
        case failure
        case holdThenFailureIgnoringCancellation
    }

    private var outcomes: [Outcome]
    private let fallbackOutcome: Outcome
    private(set) var invocationCount = 0
    private(set) var responseBodyBytes: Int64 = 0
    private(set) var responseBodyBytesByInvocation: [Int64] = []
    private(set) var lastResult: LegacyDescriptorProbeResult?
    private(set) var heldFailureCount = 0
    private var failureContinuations: [CheckedContinuation<Void, Never>] = []

    init(outcomes: [Outcome]) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
        fallbackOutcome = outcomes.last!
    }

    func probe(
        descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> LegacyDescriptorProbeResult {
        invocationCount += 1
        let outcome = outcomes.isEmpty ? fallbackOutcome : outcomes.removeFirst()
        switch outcome {
        case .success(let totalLength, let bytes):
            responseBodyBytes += bytes
            responseBodyBytesByInvocation.append(bytes)
            let result = LegacyDescriptorProbeResult(
                generationScope: .attemptOnly(
                    sessionID: tokens.sessionID,
                    sourceAttemptID: tokens.currentSourceAttempt.id,
                    totalLength: totalLength
                ),
                responseBodyBytes: bytes
            )
            lastResult = result
            return result
        case .mismatchedScope(let totalLength, let bytes):
            responseBodyBytes += bytes
            responseBodyBytesByInvocation.append(bytes)
            let staleTokens = ActivePlaybackTokens.freshSession(
                source: .legacyDownloadRemux
            )
            let result = LegacyDescriptorProbeResult(
                generationScope: .attemptOnly(
                    sessionID: staleTokens.sessionID,
                    sourceAttemptID: staleTokens.currentSourceAttempt.id,
                    totalLength: totalLength
                ),
                responseBodyBytes: bytes
            )
            lastResult = result
            return result
        case .mismatchedSource(let totalLength, let bytes):
            responseBodyBytes += bytes
            responseBodyBytesByInvocation.append(bytes)
            let result = LegacyDescriptorProbeResult(
                generationScope: .attemptOnly(
                    sessionID: tokens.sessionID,
                    sourceAttemptID: .fresh(),
                    totalLength: totalLength
                ),
                responseBodyBytes: bytes
            )
            lastResult = result
            return result
        case .failure:
            throw URLError(.timedOut)
        case .holdThenFailureIgnoringCancellation:
            heldFailureCount += 1
            await withCheckedContinuation { continuation in
                failureContinuations.append(continuation)
            }
            heldFailureCount -= 1
            throw URLError(.timedOut)
        }
    }

    func releaseNextFailure() {
        guard !failureContinuations.isEmpty else { return }
        failureContinuations.removeFirst().resume()
    }
}

private actor IntegrationLegacyTransport: LegacyMediaDownloading {
    enum Outcome {
        case complete
        case oneByteThenWaitForCancellation
        case secondByteWhenReleasedThenWaitForCancellation
        case oneByteThenIgnoreCancellationUntilReleased
        case staleSecondByteAfterCancellationWhenReleased
        case oneByteThenFailIgnoringCancellationWhenReleased
        case oneByteThenCompleteWhenReleased
        case oneByteThenFailWhenReleased
        case oneByteThenFailAndRetainProgress
    }

    private var outcomes: [Outcome]
    private let fileSystem: IntegrationLegacyFileSystem
    private(set) var invocationCount = 0
    private(set) var responseBodyBytes: Int64 = 0
    private(set) var cancellationCount = 0
    private(set) var requests: [LegacyPlaybackRequest] = []
    private(set) var staleProgressEmissionCount = 0
    private var failureContinuations: [CheckedContinuation<Void, Never>] = []
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []
    private var secondProgressContinuations: [CheckedContinuation<Void, Never>] = []
    private var staleProgressContinuations: [CheckedContinuation<Void, Never>] = []
    private var staleCompletionContinuations: [CheckedContinuation<Void, Never>] = []
    private var staleFailureContinuations: [CheckedContinuation<Void, Never>] = []
    private var retainedStaleProgressSinks: [
        @Sendable (Int64) async -> Void
    ] = []
    private var mayFail = false
    private var mayComplete = false

    init(outcomes: [Outcome], fileSystem: IntegrationLegacyFileSystem) {
        self.outcomes = outcomes
        self.fileSystem = fileSystem
    }

    func download(
        _ request: LegacyPlaybackRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        invocationCount += 1
        requests.append(request)
        let outcome = outcomes.isEmpty ? .complete : outcomes.removeFirst()
        switch outcome {
        case .complete:
            let length = request.descriptor.contentLength ?? 16
            responseBodyBytes += length
            await fileSystem.setFileSize(length, for: destination)
            await progress(length)
        case .oneByteThenWaitForCancellation:
            responseBodyBytes += 1
            await progress(1)
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                cancellationCount += 1
                throw CancellationError()
            }
        case .secondByteWhenReleasedThenWaitForCancellation:
            responseBodyBytes += 1
            await progress(1)
            await withCheckedContinuation { continuation in
                secondProgressContinuations.append(continuation)
            }
            responseBodyBytes += 1
            await progress(2)
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                cancellationCount += 1
                throw CancellationError()
            }
        case .oneByteThenIgnoreCancellationUntilReleased:
            responseBodyBytes += 1
            await progress(1)
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                cancellationCount += 1
            }
            await withCheckedContinuation { continuation in
                staleCompletionContinuations.append(continuation)
            }
        case .staleSecondByteAfterCancellationWhenReleased:
            responseBodyBytes += 1
            await progress(1)
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                cancellationCount += 1
            }
            await withCheckedContinuation { continuation in
                staleProgressContinuations.append(continuation)
            }
            responseBodyBytes += 1
            staleProgressEmissionCount += 1
            await progress(2)
            throw CancellationError()
        case .oneByteThenFailIgnoringCancellationWhenReleased:
            responseBodyBytes += 1
            await progress(1)
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                cancellationCount += 1
            }
            await withCheckedContinuation { continuation in
                staleFailureContinuations.append(continuation)
            }
            throw URLError(.networkConnectionLost)
        case .oneByteThenCompleteWhenReleased:
            responseBodyBytes += 1
            await progress(1)
            mayComplete = true
            await withCheckedContinuation { continuation in
                completionContinuations.append(continuation)
            }
            let length = request.descriptor.contentLength ?? 16
            responseBodyBytes += max(0, length - 1)
            await fileSystem.setFileSize(length, for: destination)
            await progress(length)
        case .oneByteThenFailWhenReleased:
            responseBodyBytes += 1
            await progress(1)
            mayFail = true
            await withCheckedContinuation { continuation in
                failureContinuations.append(continuation)
            }
            throw URLError(.networkConnectionLost)
        case .oneByteThenFailAndRetainProgress:
            responseBodyBytes += 1
            await progress(1)
            retainedStaleProgressSinks.append(progress)
            throw URLError(.networkConnectionLost)
        }
    }

    func emitRetainedStaleProgress(totalBytes: Int64) async {
        let sinks = retainedStaleProgressSinks
        retainedStaleProgressSinks.removeAll()
        for sink in sinks {
            staleProgressEmissionCount += 1
            await sink(totalBytes)
        }
    }

    func releaseFailure() {
        guard mayFail else { return }
        mayFail = false
        let continuations = failureContinuations
        failureContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseSecondProgressByte() {
        let continuations = secondProgressContinuations
        secondProgressContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseStaleProgress() {
        let continuations = staleProgressContinuations
        staleProgressContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseCompletion() {
        guard mayComplete else { return }
        mayComplete = false
        let continuations = completionContinuations
        completionContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    var completionIsHeld: Bool {
        mayComplete && !completionContinuations.isEmpty
    }

    var secondProgressIsHeld: Bool {
        !secondProgressContinuations.isEmpty
    }

    var staleProgressIsHeld: Bool {
        !staleProgressContinuations.isEmpty
    }

    var staleCompletionIsHeld: Bool {
        !staleCompletionContinuations.isEmpty
    }

    var failureIsHeld: Bool {
        mayFail && !failureContinuations.isEmpty
    }

    var staleFailureIsHeld: Bool {
        !staleFailureContinuations.isEmpty
    }

    func releaseStaleCompletion() {
        let continuations = staleCompletionContinuations
        staleCompletionContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func releaseStaleFailure() {
        let continuations = staleFailureContinuations
        staleFailureContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor IntegrationLegacyEventRecorder {
    private(set) var events: [LegacyPlaybackEvent] = []

    var kinds: [LegacyPlaybackEvent.Kind] {
        events.map(\.kind)
    }

    var containsDownloadCompletion: Bool {
        events.contains { event in
            if case .downloadCompleted = event.kind { return true }
            return false
        }
    }

    var containsNeutralRawArtifact: Bool {
        events.contains { event in
            if case .rawArtifactPrepared = event.kind { return true }
            return false
        }
    }

    var preparedSeekTargets: [TimeInterval] {
        events.compactMap { event in
            guard case .localSeekPrepared(_, let targetSeconds) = event.kind else {
                return nil
            }
            return targetSeconds
        }
    }

    func record(_ event: LegacyPlaybackEvent) {
        events.append(event)
    }
}

@MainActor
private final class IntegrationLegacyHostRecorder {
    private(set) var commands: [GuardedLegacyHostCommand] = []
    private(set) var remuxInstallStopHookInvocationCount = 0
    private var remuxInstallStopHook: (() -> Void)?

    func stopEngineOnNextRemuxInstall(_ hook: @escaping () -> Void) {
        remuxInstallStopHook = hook
    }

    func record(_ command: GuardedLegacyHostCommand) {
        commands.append(command)
        guard command == .installRemuxedArtifact,
            let hook = remuxInstallStopHook
        else {
            return
        }
        remuxInstallStopHook = nil
        remuxInstallStopHookInvocationCount += 1
        hook()
    }
}

@MainActor
private final class IntegrationLegacyRemuxEffectProbe {
    private(set) var attempts: [FallbackAttempt] = []
    private var stopHook: (() -> Void)?

    var invocationCount: Int { attempts.count }

    func stopEngineOnNextEntry(_ hook: @escaping () -> Void) {
        stopHook = hook
    }

    func record(_ attempt: FallbackAttempt) {
        attempts.append(attempt)
        guard let stopHook else { return }
        self.stopHook = nil
        stopHook()
    }
}

@MainActor
private final class IntegrationLegacyArtifactHost: GuardedLegacyArtifactHosting {
    enum Event: Equatable {
        case installRaw
        case installRemuxed
        case seek(targetSeconds: TimeInterval)
        case play
        case pause
    }

    private(set) var events: [Event] = []
    private(set) var currentPosition: TimeInterval = 0
    private var shouldHoldNextSeek = false
    private var seekContinuations: [CheckedContinuation<TimeInterval?, Never>] = []
    private(set) var seekIsHeld = false

    func installArtifact(
        _ url: URL,
        song: Song,
        isRaw: Bool
    ) {
        events.append(isRaw ? .installRaw : .installRemuxed)
        if !isRaw {
            currentPosition = 0
        }
    }

    func seek(to targetSeconds: TimeInterval) async -> TimeInterval? {
        events.append(.seek(targetSeconds: targetSeconds))
        if shouldHoldNextSeek {
            shouldHoldNextSeek = false
            seekIsHeld = true
            let confirmed = await withCheckedContinuation { continuation in
                seekContinuations.append(continuation)
            }
            seekIsHeld = false
            if let confirmed {
                currentPosition = confirmed
            }
            return confirmed
        }
        currentPosition = targetSeconds
        return targetSeconds
    }

    func play() {
        events.append(.play)
    }

    func pause() {
        events.append(.pause)
    }

    func holdNextSeek() {
        shouldHoldNextSeek = true
    }

    func releaseHeldSeek(confirmedPosition: TimeInterval?) {
        let continuations = seekContinuations
        seekContinuations.removeAll()
        continuations.forEach { $0.resume(returning: confirmedPosition) }
    }

    func setCurrentPosition(_ position: TimeInterval) {
        currentPosition = position
    }
}

private extension Array where Element == GuardedLegacyHostCommand {
    var rawPlayCount: Int {
        filter { command in
            if case .playRawArtifact = command { return true }
            return false
        }.count
    }

    var containsRawPlay: Bool {
        rawPlayCount > 0
    }

    var preparedSeekTarget: TimeInterval? {
        compactMap { command in
            guard case .seekLocalArtifact(let targetSeconds) = command else {
                return nil
            }
            return targetSeconds
        }.last
    }
}

private final class LockedURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor IntegrationLegacyFileSystem: LegacyPlaybackFileManaging {
    nonisolated private let synchronousRemovalRecorder = LockedURLRecorder()
    private var fileSizes: [URL: Int64] = [:]
    var removedURLs: [URL] { synchronousRemovalRecorder.values }
    private(set) var lastArtifacts: LegacyPlaybackArtifacts?

    func artifacts(for request: LegacyPlaybackRequest) async throws -> LegacyPlaybackArtifacts {
        let base = URL(fileURLWithPath: "/tmp/task8-\(request.tokens.sessionID.rawValue)")
        let artifacts = LegacyPlaybackArtifacts(
            rawURL: base.appendingPathExtension("raw.m4a"),
            remuxedURL: base.appendingPathExtension("remuxed.m4a")
        )
        lastArtifacts = artifacts
        return artifacts
    }

    func removeIfPresent(_ url: URL) async {
        synchronousRemovalRecorder.record(url)
        fileSizes.removeValue(forKey: url)
    }

    nonisolated func disposeCompletedArtifactSynchronously(
        _ resource: LegacyDownloadedResource
    ) {
        synchronousRemovalRecorder.record(resource.rawURL)
        synchronousRemovalRecorder.record(resource.remuxedURL)
    }

    func fileSize(_ url: URL) async throws -> Int64 {
        return fileSizes[url] ?? 0
    }

    func setFileSize(_ byteCount: Int64, for url: URL) {
        fileSizes[url] = byteCount
    }
}

private actor IntegrationMediaRemuxer: MediaRemuxing {
    enum Outcome {
        case success
        case failure
        case holdThenSuccess
        case holdThenFailureIgnoringCancellation
        case holdThenLateWriteFailureIgnoringCancellation
    }

    private var outcomes: [Outcome]
    private let fileSystem: IntegrationLegacyFileSystem
    private(set) var invocationCount = 0
    private(set) var isHeld = false
    private var holdContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        outcomes: [Outcome],
        fileSystem: IntegrationLegacyFileSystem
    ) {
        self.outcomes = outcomes
        self.fileSystem = fileSystem
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
            break
        case .failure:
            throw URLError(.cannotDecodeContentData)
        case .holdThenSuccess:
            isHeld = true
            await withCheckedContinuation { continuation in
                holdContinuations.append(continuation)
            }
            isHeld = false
        case .holdThenFailureIgnoringCancellation:
            isHeld = true
            await withCheckedContinuation { continuation in
                holdContinuations.append(continuation)
            }
            isHeld = false
            throw URLError(.cannotDecodeContentData)
        case .holdThenLateWriteFailureIgnoringCancellation:
            isHeld = true
            await withCheckedContinuation { continuation in
                holdContinuations.append(continuation)
            }
            isHeld = false
            await fileSystem.setFileSize(1, for: destination)
            throw URLError(.cannotDecodeContentData)
        }
        await progress(1)
    }

    func releaseHeldRemux() {
        let continuations = holdContinuations
        holdContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private struct IntegrationLegacyClock: LegacyPlaybackMonotonicClock {
    var now: TimeInterval { 1 }
}

@MainActor
private final class IntegrationPlaybackClock: PlaybackMonotonicClock {
    private(set) var now: TimeInterval = 0

    func advance(by interval: TimeInterval) {
        now += interval
    }
}

@MainActor
private final class IntegrationPlaybackWatchdogScheduler: PlaybackWatchdogScheduling {
    private(set) var startedSleeps = 0
    private(set) var completedSleeps = 0
    private(set) var activeSleeps = 0

    func sleep(
        until deadline: TimeInterval,
        clock: any PlaybackMonotonicClock
    ) async throws {
        startedSleeps += 1
        activeSleeps += 1
        defer { activeSleeps -= 1 }
        while clock.now < deadline {
            try Task.checkCancellation()
            await Task.yield()
        }
        completedSleeps += 1
    }

    func drainUntilQuiescent() async {
        while activeSleeps > 0 {
            await Task.yield()
        }
        await withCheckedContinuation { continuation in
            Task { @MainActor in continuation.resume() }
        }
    }
}

private actor FixedPlaybackCapacity: PlaybackCapacityProviding {
    let bytes: Int64

    init(bytes: Int64) {
        self.bytes = bytes
    }

    func volumeAvailableCapacityForImportantUsage() async throws -> Int64 {
        bytes
    }
}

@MainActor
private final class RecoveryDelegateProbe: PlaybackRecoveryDelegate {
    var isPlaying = true
    var isBuffering = false
    var currentTime: TimeInterval = 12
    var duration: TimeInterval = 180
    var currentTrackID: String? = "task8-recovery"
    private(set) var resumeCount = 0
    private(set) var nextCount = 0
    private(set) var resolverCount = 0
    private(set) var recoveryLoadCount = 0
    private(set) var retryStateUpdateCount = 0

    lazy var streamURLResolver: (
        (String) async throws -> (url: String, contentLength: Int64?)
    )? = { [weak self] _ in
        await MainActor.run { self?.resolverCount += 1 }
        return ("https://example.test", 16)
    }

    func resumePlayer() {
        resumeCount += 1
    }

    func next() {
        nextCount += 1
    }

    func performRecoveryLoadAndPlay(song: Song) {
        recoveryLoadCount += 1
    }

    func updateRetryState(
        song: Song,
        streamURL: String,
        contentLength: Int64?
    ) {
        retryStateUpdateCount += 1
    }
}

@MainActor
private final class IntegrationRecoveryClock: PlaybackRecoveryClock {
    private(set) var now: TimeInterval = 0

    func advance(by interval: TimeInterval) {
        now += interval
    }
}

@MainActor
private final class IntegrationRecoveryScheduler: PlaybackRecoveryScheduling {
    private var repeatingCheck: (@MainActor () -> Void)?
    private var sleepContinuations: [CheckedContinuation<Void, Error>] = []

    func scheduleRepeating(
        every interval: TimeInterval,
        _ check: @escaping @MainActor () -> Void
    ) {
        repeatingCheck = check
    }

    func cancelRepeating() {
        repeatingCheck = nil
    }

    func sleep(for interval: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleepContinuations.append(continuation)
        }
    }

    func fireRepeatingCheck() {
        repeatingCheck?()
    }

    func resumeAllSleeps() {
        let continuations = sleepContinuations
        sleepContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func drainMainActor() async {
        await withCheckedContinuation { continuation in
            Task { @MainActor in continuation.resume() }
        }
    }
}

private extension PlaybackStorageCompatibilityProfile {
    static let fixture = Self(
        legacyPeakMultiplier: StoragePeakMultiplier(numerator: 2, denominator: 1),
        legacySafetyMarginBytes: 8,
        minimumFreeSpaceReserveBytes: 32,
        storageCalibrationID: "task8-fixture",
        calibratedContentLengthEnvelope: 1...1_024
    )
}

private extension StreamDescriptor {
    static func fixture(contentLength: Int64?) -> Self {
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
            requestHeaders: ["Origin": "https://music.youtube.com"],
            provisionalResourceKey: ProvisionalResourceKey(
                videoID: "video",
                itag: 140,
                codec: "mp4a.40.2",
                declaredTotalLength: contentLength
            )
        )
    }
}

private extension Song {
    static let fixture = fixture(id: "task8-video")

    static func fixture(id: String) -> Song {
        Song(
            id: id,
            title: "Task 8",
            artistName: "Fixture",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
    }
}

private func featureSnapshot(
    rangeEnabled: Bool,
    killSwitch: Bool
) -> PlaybackFeatureSnapshot {
    PlaybackFeatureSnapshot(
        rangeStreamingV1: rangeEnabled,
        cohortPercent: 100,
        boundedPreloadV1: false,
        killSwitch: killSwitch,
        killSwitchEpoch: 1,
        loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
        headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
    )
}

@MainActor
private func waitUntil(
    attempts: Int = 5_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @MainActor () async -> Bool
) async {
    for _ in 0..<attempts {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail(
        "Timed out waiting for guarded playback condition",
        file: file,
        line: line
    )
}

@MainActor
private func drainGuardedMainActorQueue() async {
    await withCheckedContinuation { continuation in
        Task { @MainActor in continuation.resume() }
    }
}
