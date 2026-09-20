import Foundation
import XCTest

@testable import LovelyMusic

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    func testSourceRouterPrefersExplicitDownloadOverAllOtherSources() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)

        let effects = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(
                    hasExplicitDownload: true,
                    hasValidLocalRemux: true,
                    rangeEligible: true
                )
            )
        )

        let attempt = try XCTUnwrap(effects.startedSourceAttempt)
        XCTAssertEqual(attempt.source, .explicitDownload)
        XCTAssertEqual(state.selectedSource, .explicitDownload)
        XCTAssertEqual(state.phase, .preparing(attempt))
    }

    func testSourceRouterPrefersValidLocalRemuxOverEligibleRange() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)

        let effects = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(
                    hasExplicitDownload: false,
                    hasValidLocalRemux: true,
                    rangeEligible: true
                )
            )
        )

        let attempt = try XCTUnwrap(effects.startedSourceAttempt)
        XCTAssertEqual(attempt.source, .remuxCache)
        XCTAssertEqual(state.selectedSource, .remuxCache)
    }

    func testSourceRouterChoosesEligibleGuardedRange() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)

        let effects = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: true)
            )
        )

        let attempt = try XCTUnwrap(effects.startedSourceAttempt)
        XCTAssertEqual(attempt.source, .rangeStream)
        XCTAssertEqual(state.selectedSource, .rangeStream)
        XCTAssertEqual(state.phase, .preparing(attempt))
    }

    func testInitialLegacySelectionRequestsGateInsteadOfStartingDriver() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)

        let effects = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )

        let request = try XCTUnwrap(effects.transferGateRequest)
        XCTAssertEqual(request.sourceAttempt.source, .legacyDownloadRemux)
        XCTAssertEqual(request.intent, .playing)
        XCTAssertEqual(request.targetSeconds, 0)
        XCTAssertEqual(state.phase, .awaitingTransferConsent(request))
        XCTAssertNil(state.selectedSource)
        XCTAssertFalse(effects.containsLegacyTransferStart)
    }

    func testInitialGateCommitStartsLegacyWithoutConsumingDowngradeAllowance() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)
        let gateEffects = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gateAttempt = try XCTUnwrap(gateEffects.transferGateAttempt)
        let request = gateAttempt.request
        let reservationID = StorageReservationID(rawValue: UUID())

        let effects = state.reduce(
            .fullTransferGateAllowed(gateAttempt, reservationID: reservationID)
        )

        let fallback = try XCTUnwrap(effects.startedLegacyAttempt)
        XCTAssertEqual(fallback.sourceAttempt.source, .legacyDownloadRemux)
        XCTAssertEqual(fallback.reservationID, reservationID)
        XCTAssertEqual(state.phase, .legacyDownloading(fallback))
        XCTAssertEqual(state.selectedSource, .legacyDownloadRemux)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
    }

    func testDuplicateAllowedCallbackCannotReleaseCommittedReservation() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: false)
                )
            ).transferGateAttempt
        )
        let reservationID = StorageReservationID(rawValue: UUID())
        let commitEffects = state.reduce(
            .fullTransferGateAllowed(
                gateAttempt,
                reservationID: reservationID
            )
        )
        let fallback = try XCTUnwrap(commitEffects.startedLegacyAttempt)
        let committedState = state

        let replayEffects = state.reduce(
            .fullTransferGateAllowed(
                gateAttempt,
                reservationID: reservationID
            )
        )

        XCTAssertTrue(replayEffects.isEmpty)
        XCTAssertEqual(state, committedState)
        XCTAssertEqual(state.phase, .legacyDownloading(fallback))
    }

    func testDuplicateConsentAcceptanceCannotReleaseCommittedReservation() throws {
        var state = try makePlayingRangeState()
        let rangeAttempt = try XCTUnwrap(state.activeSourceAttempt)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(
                    sourceAttempt: rangeAttempt,
                    token: .fixture(sessionID: rangeAttempt.sessionID)
                )
            ).transferGateAttempt
        )
        _ = state.reduce(.fullTransferGateRequiresConsent(gateAttempt))
        let reservationID = StorageReservationID(rawValue: UUID())
        let commitEffects = state.reduce(
            .transferConsentAccepted(
                gateAttempt,
                reservationID: reservationID
            )
        )
        let fallback = try XCTUnwrap(commitEffects.startedLegacyAttempt)
        let committedState = state

        let replayEffects = state.reduce(
            .transferConsentAccepted(
                gateAttempt,
                reservationID: reservationID
            )
        )

        XCTAssertTrue(replayEffects.isEmpty)
        XCTAssertEqual(state, committedState)
        XCTAssertEqual(state.phase, .legacyDownloading(fallback))
    }

    func testRangeFallbackConsumesDowngradeOnlyWhenLegacyIsCommitted() throws {
        var state = try makePlayingRangeState()
        let rangeAttempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = FailedActionToken.fixture(
            sessionID: rangeAttempt.sessionID,
            category: .seekVerification
        )

        let gateEffects = state.reduce(
            .requestLegacyFallback(sourceAttempt: rangeAttempt, token: token)
        )
        let gateAttempt = try XCTUnwrap(gateEffects.transferGateAttempt)
        let request = gateAttempt.request
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
        XCTAssertEqual(state.selectedSource, .rangeStream)

        let consentEffects = state.reduce(
            .fullTransferGateRequiresConsent(gateAttempt)
        )
        XCTAssertEqual(
            consentEffects,
            [.presentFullTransferConsent(gateAttempt)]
        )
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
        XCTAssertEqual(state.selectedSource, .rangeStream)
        XCTAssertFalse(consentEffects.containsLegacyTransferStart)

        let reservationID = StorageReservationID(rawValue: UUID())
        let commitEffects = state.reduce(
            .transferConsentAccepted(gateAttempt, reservationID: reservationID)
        )
        let fallback = try XCTUnwrap(commitEffects.startedLegacyAttempt)
        XCTAssertEqual(fallback.sourceAttempt.source, .legacyDownloadRemux)
        XCTAssertEqual(state.selectedSource, .legacyDownloadRemux)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 0)
    }

    func testDuplicateLegacyFallbackPreservesPresentedConsentAndOriginalAcceptance() throws {
        var state = try makePlayingRangeState()
        let rangeAttempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = FailedActionToken.fixture(sessionID: rangeAttempt.sessionID)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(
                    sourceAttempt: rangeAttempt,
                    token: token
                )
            ).transferGateAttempt
        )
        XCTAssertEqual(
            state.reduce(.fullTransferGateRequiresConsent(gateAttempt)),
            [.presentFullTransferConsent(gateAttempt)]
        )
        let promptedState = state

        let replayEffects = state.reduce(
            .requestLegacyFallback(
                sourceAttempt: rangeAttempt,
                token: token
            )
        )

        XCTAssertTrue(replayEffects.isEmpty)
        XCTAssertEqual(state, promptedState)
        XCTAssertEqual(state.pendingTransferGateAttempt, gateAttempt)
        XCTAssertEqual(state.consumedConsentTokens, [token])

        let reservationID = StorageReservationID(rawValue: UUID())
        let acceptedEffects = state.reduce(
            .transferConsentAccepted(
                gateAttempt,
                reservationID: reservationID
            )
        )

        let fallback = try XCTUnwrap(acceptedEffects.startedLegacyAttempt)
        XCTAssertEqual(fallback.reservationID, reservationID)
        XCTAssertEqual(state.phase, .legacyDownloading(fallback))
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 0)
    }

    func testCommittedLegacySourceCannotRouteBackToRangeInSameSession() throws {
        var state = try makePlayingRangeState()
        let rangeAttempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = FailedActionToken.fixture(sessionID: rangeAttempt.sessionID)
        let gateEffects = state.reduce(
            .requestLegacyFallback(sourceAttempt: rangeAttempt, token: token)
        )
        let gateAttempt = try XCTUnwrap(gateEffects.transferGateAttempt)
        _ = state.reduce(
            .fullTransferGateAllowed(
                gateAttempt,
                reservationID: StorageReservationID(rawValue: UUID())
            )
        )
        let committedState = state

        let effects = state.reduce(
            .descriptorResolved(
                sessionID: rangeAttempt.sessionID,
                sources: .fixture(rangeEligible: true)
            )
        )

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state, committedState)
        XCTAssertEqual(state.selectedSource, .legacyDownloadRemux)
    }

    func testStaleAttemptCannotPublishPlaying() throws {
        let sessionID = PlaybackSessionID.fresh()
        let stale = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .rangeStream
        )
        let current = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .legacyDownloadRemux
        )
        var state = PlaybackSessionState(
            phase: .preparing(current),
            selectedSource: .legacyDownloadRemux,
            desiredPlaybackIntent: .playing,
            latestRequestedTarget: nil,
            lastConfirmedPosition: 0,
            sessionBudget: .initial,
            consumedConsentTokens: [],
            resourceGenerationFingerprint: .fixture
        )

        let effects = state.reduce(.sourceBecamePlayable(stale))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.phase, .preparing(current))
    }

    func testSessionReplacementRejectsOldCallbackAndResetsSessionBudget() throws {
        var state = try makePlayingRangeState()
        let staleAttempt = try XCTUnwrap(state.activeSourceAttempt)
        XCTAssertTrue(state.sessionBudget.consume(.resolverRetry))
        let replacementID = PlaybackSessionID.fresh()

        let effects = state.reduce(
            .replaceSession(
                sessionID: replacementID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )

        XCTAssertEqual(effects, [.cancelAllEffects, .resolveDescriptor(replacementID)])
        XCTAssertEqual(state.phase, .resolving(replacementID))
        XCTAssertEqual(state.sessionBudget.resolverRetries, 1)
        XCTAssertTrue(state.reduce(.sourceBecamePlayable(staleAttempt)).isEmpty)
        XCTAssertEqual(state.phase, .resolving(replacementID))
    }

    func testRapidSeekIsLastWinsAndDoesNotConsumeTransportRetry() throws {
        var state = try makePlayingRangeState()
        let initialRetries = state.sessionBudget.rangeTransportRetries

        let firstEffects = state.reduce(.requestSeek(targetSeconds: 12.25))
        let firstSeek = try XCTUnwrap(firstEffects.startedSeekAttempt)
        XCTAssertEqual(
            firstEffects,
            [
                .cancelActiveRangeMonitor(firstSeek.sourceAttempt.id),
                .startSeek(firstSeek),
            ]
        )
        let latestEffects = state.reduce(.requestSeek(targetSeconds: 91.5))
        let latestSeek = try XCTUnwrap(latestEffects.startedSeekAttempt)

        XCTAssertNotEqual(firstSeek.id, latestSeek.id)
        XCTAssertEqual(
            latestEffects,
            [.cancelSeekEffects(firstSeek.id), .startSeek(latestSeek)]
        )
        XCTAssertEqual(state.phase, .seeking(latestSeek))
        XCTAssertEqual(state.latestRequestedTarget, 91.5)
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, initialRetries)
        XCTAssertTrue(state.reduce(.seekPrepared(firstSeek)).isEmpty)
        XCTAssertEqual(state.phase, .seeking(latestSeek))
    }

    func testPausedSeekPreservesIntentAndStagesWithoutVerification() throws {
        var state = try makePlayingRangeState(intent: .paused)

        let seekEffects = state.reduce(.requestSeek(targetSeconds: 42))
        let seek = try XCTUnwrap(seekEffects.startedSeekAttempt)
        let preparedEffects = state.reduce(.seekPrepared(seek))

        XCTAssertTrue(preparedEffects.isEmpty)
        XCTAssertEqual(state.desiredPlaybackIntent, .paused)
        XCTAssertEqual(state.phase, .seekPreparedWhilePaused(seek))
        XCTAssertEqual(state.latestRequestedTarget, 42)
        XCTAssertEqual(state.lastConfirmedPosition, 0)
    }

    func testPauseDuringVerificationDefersWithoutFallbackOrCounterConsumption() throws {
        var state = try makePlayingRangeState()
        let seek = try XCTUnwrap(
            state.reduce(.requestSeek(targetSeconds: 30)).startedSeekAttempt
        )
        XCTAssertEqual(state.reduce(.seekPrepared(seek)), [.startSeekVerification(seek)])
        let downgradeAllowance = state.sessionBudget.rangeToLegacyDowngrades
        let transportRetries = state.sessionBudget.rangeTransportRetries

        let effects = state.reduce(.userPaused)

        XCTAssertEqual(effects, [.cancelSeekEffects(seek.id)])
        XCTAssertEqual(state.phase, .seekPreparedWhilePaused(seek))
        XCTAssertEqual(state.desiredPlaybackIntent, .paused)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, downgradeAllowance)
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, transportRetries)
        XCTAssertNil(effects.transferGateRequest)
    }

    func testPlayAfterPausedPreparationStartsFreshVerification() throws {
        var state = try makePlayingRangeState(intent: .paused)
        let seek = try XCTUnwrap(
            state.reduce(.requestSeek(targetSeconds: 64)).startedSeekAttempt
        )
        _ = state.reduce(.seekPrepared(seek))

        let effects = state.reduce(.userPlayed)

        XCTAssertEqual(effects, [.startSeekVerification(seek)])
        XCTAssertEqual(state.phase, .verifyingSeek(seek))
        XCTAssertEqual(state.desiredPlaybackIntent, .playing)
        XCTAssertEqual(state.lastConfirmedPosition, 0)
    }

    func testSeekVerificationPublishesOnlyLatestConfirmedPosition() throws {
        var state = try makePlayingRangeState()
        let firstSeek = try XCTUnwrap(
            state.reduce(.requestSeek(targetSeconds: 10)).startedSeekAttempt
        )
        let latestSeek = try XCTUnwrap(
            state.reduce(.requestSeek(targetSeconds: 80)).startedSeekAttempt
        )
        _ = state.reduce(.seekPrepared(latestSeek))

        XCTAssertTrue(
            state.reduce(
                .seekVerified(firstSeek, confirmedPosition: firstSeek.targetSeconds)
            ).isEmpty
        )
        XCTAssertEqual(state.lastConfirmedPosition, 0)

        XCTAssertEqual(
            state.reduce(
                .seekVerified(latestSeek, confirmedPosition: latestSeek.targetSeconds)
            ),
            [.monitorActiveRange(latestSeek.sourceAttempt)]
        )
        XCTAssertEqual(state.lastConfirmedPosition, 80)
        XCTAssertEqual(state.phase, .playing(latestSeek.sourceAttempt))
    }

    func testConsentTokenIsConsumedOnceAndNewSeekUpdatesPendingTarget() throws {
        var state = try makePlayingRangeState()
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = FailedActionToken.fixture(sessionID: attempt.sessionID)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(sourceAttempt: attempt, token: token)
            ).transferGateAttempt
        )
        let request = gateAttempt.request

        XCTAssertEqual(
            state.reduce(.fullTransferGateRequiresConsent(gateAttempt)),
            [.presentFullTransferConsent(gateAttempt)]
        )
        XCTAssertTrue(
            state.reduce(.fullTransferGateRequiresConsent(gateAttempt)).isEmpty
        )
        XCTAssertEqual(state.consumedConsentTokens, [token])

        XCTAssertTrue(state.reduce(.requestSeek(targetSeconds: 99)).isEmpty)
        let updatedRequest = try XCTUnwrap(state.pendingFallbackRequest)
        XCTAssertEqual(updatedRequest.targetSeconds, 99)
        XCTAssertEqual(updatedRequest.token, token)
        XCTAssertEqual(state.consumedConsentTokens, [token])
    }

    func testSeekWhileGateIsEvaluatingMergesNewestTargetIntoOldGateCallback() throws {
        var state = try makePlayingRangeState()
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = FailedActionToken.fixture(sessionID: attempt.sessionID)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(sourceAttempt: attempt, token: token)
            ).transferGateAttempt
        )
        let originalRequest = gateAttempt.request

        XCTAssertTrue(state.reduce(.requestSeek(targetSeconds: 88)).isEmpty)
        let effects = state.reduce(
            .fullTransferGateAllowed(
                gateAttempt,
                reservationID: StorageReservationID(rawValue: UUID())
            )
        )

        let fallback = try XCTUnwrap(effects.startedLegacyAttempt)
        XCTAssertEqual(fallback.targetSeconds, 88)
        XCTAssertEqual(fallback.intent, .playing)
        XCTAssertEqual(state.selectedSource, .legacyDownloadRemux)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 0)
    }

    func testSeekWhileConsentIsPresentedMergesNewestTargetIntoOldAcceptCallback() throws {
        var state = try makePlayingRangeState(intent: .paused)
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = FailedActionToken.fixture(sessionID: attempt.sessionID)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(sourceAttempt: attempt, token: token)
            ).transferGateAttempt
        )
        let originalRequest = gateAttempt.request
        XCTAssertEqual(
            state.reduce(.fullTransferGateRequiresConsent(gateAttempt)),
            [.presentFullTransferConsent(gateAttempt)]
        )

        XCTAssertTrue(state.reduce(.requestSeek(targetSeconds: 101)).isEmpty)
        _ = state.reduce(.userPlayed)
        let effects = state.reduce(
            .transferConsentAccepted(
                gateAttempt,
                reservationID: StorageReservationID(rawValue: UUID())
            )
        )

        let fallback = try XCTUnwrap(effects.startedLegacyAttempt)
        XCTAssertEqual(fallback.targetSeconds, 101)
        XCTAssertEqual(fallback.intent, .playing)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 0)
    }

    func testConsentAcceptBeforePromptCannotStartLegacyTransfer() throws {
        var state = try makePlayingRangeState()
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(
                    sourceAttempt: attempt,
                    token: .fixture(sessionID: attempt.sessionID)
                )
            ).transferGateAttempt
        )
        let pendingState = state

        let reservationID = StorageReservationID(rawValue: UUID())
        let effects = state.reduce(
            .transferConsentAccepted(
                gateAttempt,
                reservationID: reservationID
            )
        )

        XCTAssertEqual(effects, [.releaseStorageReservation(reservationID)])
        XCTAssertEqual(state.phase, pendingState.phase)
        XCTAssertEqual(
            state.pendingTransferGateAttempt,
            pendingState.pendingTransferGateAttempt
        )
        XCTAssertEqual(state.sessionBudget, pendingState.sessionBudget)
        XCTAssertEqual(state.selectedSource, .rangeStream)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
    }

    func testInitialLegacyGateDenialCancelsGateAndBecomesTypedFailure() throws {
        var state = makeResolvingState(position: 7)
        let sessionID = try XCTUnwrap(state.activeSessionID)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: false)
                )
            ).transferGateAttempt
        )
        let denial = PlaybackTransferGateDenial(category: .storage)

        let effects = state.reduce(
            .fullTransferGateDenied(gateAttempt, denial: denial)
        )

        XCTAssertEqual(effects, [.cancelTransferGate(gateAttempt.id)])
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: .storage,
                    isRecoverable: true,
                    lastConfirmedPosition: 7
                )
            )
        )
        XCTAssertNil(state.selectedSource)
        XCTAssertFalse(effects.containsLegacyTransferStart)
    }

    func testRangeFallbackGateDenialRejectsStaleTokenThenFailsCurrentRequest() throws {
        var state = try makePlayingRangeState()
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(
                    sourceAttempt: attempt,
                    token: .fixture(sessionID: attempt.sessionID)
                )
            ).transferGateAttempt
        )
        let request = gateAttempt.request
        let staleRequest = FallbackRequest(
            sourceAttempt: request.sourceAttempt,
            targetSeconds: request.targetSeconds,
            intent: request.intent,
            token: .fixture(sessionID: attempt.sessionID)
        )
        let staleGateAttempt = PlaybackTransferGateAttempt(
            id: gateAttempt.id,
            request: staleRequest,
            networkClass: gateAttempt.networkClass
        )
        let pendingState = state

        XCTAssertTrue(
            state.reduce(
                .fullTransferGateDenied(
                    staleGateAttempt,
                    denial: PlaybackTransferGateDenial(category: .transport)
                )
            ).isEmpty
        )
        XCTAssertEqual(state, pendingState)

        let effects = state.reduce(
            .fullTransferGateDenied(
                gateAttempt,
                denial: PlaybackTransferGateDenial(category: .transport)
            )
        )
        XCTAssertEqual(effects, [.cancelTransferGate(gateAttempt.id)])
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: .transport,
                    isRecoverable: true,
                    lastConfirmedPosition: 0
                )
            )
        )
        XCTAssertEqual(state.selectedSource, .rangeStream)
        XCTAssertFalse(effects.containsLegacyTransferStart)
    }

    func testLegacyRemuxSuccessAtZeroPreparesLocalSourceForPlayingAndPausedIntent() throws {
        for intent in [DesiredPlaybackIntent.playing, .paused] {
            let fallback = FallbackAttempt.fixture(
                targetSeconds: 0,
                intent: intent
            )
            var state = makeLegacyRemuxState(fallback: fallback)

            let effects = state.reduce(.legacyRemuxSucceeded(fallback))
            let localAttempt = try XCTUnwrap(effects.startedSourceAttempt)

            XCTAssertEqual(
                effects,
                [
                    .releaseStorageReservation(fallback.reservationID),
                    .startSource(localAttempt),
                ]
            )
            XCTAssertEqual(localAttempt.source, .remuxCache)
            XCTAssertEqual(localAttempt.sessionID, fallback.sourceAttempt.sessionID)
            XCTAssertNil(state.latestRequestedTarget)
            XCTAssertEqual(state.selectedSource, .remuxCache)
            XCTAssertEqual(state.phase, .preparing(localAttempt))
            XCTAssertTrue(state.reduce(.legacyRemuxSucceeded(fallback)).isEmpty)

            XCTAssertTrue(state.reduce(.sourceBecamePlayable(localAttempt)).isEmpty)
            XCTAssertEqual(
                state.phase,
                intent == .playing
                    ? .playing(localAttempt)
                    : .paused(localAttempt)
            )
        }
    }

    func testLegacyRemuxSuccessAtOffsetStartsExactLocalSeekAndPreservesPausedIntent() throws {
        for intent in [DesiredPlaybackIntent.playing, .paused] {
            let fallback = FallbackAttempt.fixture(
                targetSeconds: 93.5,
                intent: intent
            )
            var state = makeLegacyRemuxState(fallback: fallback)

            let effects = state.reduce(.legacyRemuxSucceeded(fallback))
            let seek = try XCTUnwrap(effects.startedSeekAttempt)

            XCTAssertEqual(
                effects,
                [
                    .releaseStorageReservation(fallback.reservationID),
                    .startSeek(seek),
                ]
            )
            XCTAssertEqual(seek.sourceAttempt.source, .remuxCache)
            XCTAssertEqual(seek.targetSeconds, 93.5)
            XCTAssertEqual(state.selectedSource, .remuxCache)
            XCTAssertEqual(state.phase, .seeking(seek))
            XCTAssertTrue(state.reduce(.legacyRemuxSucceeded(fallback)).isEmpty)

            let preparedEffects = state.reduce(.seekPrepared(seek))
            if intent == .playing {
                XCTAssertEqual(preparedEffects, [.startSeekVerification(seek)])
                XCTAssertEqual(state.phase, .verifyingSeek(seek))
            } else {
                XCTAssertTrue(preparedEffects.isEmpty)
                XCTAssertEqual(state.phase, .seekPreparedWhilePaused(seek))
                XCTAssertEqual(state.desiredPlaybackIntent, .paused)
                XCTAssertEqual(
                    state.reduce(.userPlayed),
                    [.startSeekVerification(seek)]
                )
            }
        }
    }

    func testLegacyRemuxSuccessRejectsStaleAttemptOrReservationIdentity() {
        let current = FallbackAttempt.fixture(targetSeconds: 12, intent: .playing)
        var state = makeLegacyRemuxState(fallback: current)
        let staleReservation = FallbackAttempt(
            sourceAttempt: current.sourceAttempt,
            targetSeconds: current.targetSeconds,
            intent: current.intent,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        let staleAttempt = FallbackAttempt(
            sourceAttempt: SourceAttempt(
                sessionID: current.sourceAttempt.sessionID,
                id: .fresh(),
                source: .legacyDownloadRemux
            ),
            targetSeconds: current.targetSeconds,
            intent: current.intent,
            reservationID: current.reservationID
        )
        let originalState = state

        XCTAssertTrue(state.reduce(.legacyRemuxSucceeded(staleReservation)).isEmpty)
        XCTAssertEqual(state, originalState)
        XCTAssertTrue(state.reduce(.legacyRemuxSucceeded(staleAttempt)).isEmpty)
        XCTAssertEqual(state, originalState)
    }

    func testLegacyRemuxSuccessUsesLatestTargetIntentAndFreshLocalIdentity() throws {
        for latestTarget in [0.0, 84.25] {
            let original = FallbackAttempt.fixture(
                targetSeconds: 12,
                intent: .playing
            )
            var state = makeLegacyRemuxState(fallback: original)

            XCTAssertTrue(
                state.reduce(.requestSeek(targetSeconds: latestTarget)).isEmpty
            )
            XCTAssertTrue(state.reduce(.userPaused).isEmpty)

            let effects = state.reduce(.legacyRemuxSucceeded(original))
            XCTAssertEqual(state.selectedSource, .remuxCache)
            XCTAssertEqual(state.latestRequestedTarget, latestTarget)
            XCTAssertEqual(state.desiredPlaybackIntent, .paused)

            let seek = try XCTUnwrap(effects.startedSeekAttempt)
            XCTAssertEqual(
                effects,
                [
                    .releaseStorageReservation(original.reservationID),
                    .startSeek(seek),
                ]
            )
            XCTAssertEqual(seek.targetSeconds, latestTarget)
            XCTAssertEqual(seek.sourceAttempt.source, .remuxCache)
            XCTAssertNotEqual(seek.sourceAttempt.id, original.sourceAttempt.id)
            XCTAssertTrue(state.reduce(.seekPrepared(seek)).isEmpty)
            XCTAssertEqual(state.phase, .seekPreparedWhilePaused(seek))
            XCTAssertEqual(
                state.reduce(.userPlayed),
                [.startSeekVerification(seek)]
            )
        }
    }

    func testCoordinatorHostsExactOnceRemuxSuccessReleaseForEveryTargetAndIntent() async {
        for target in [0.0, 93.5] {
            for intent in [DesiredPlaybackIntent.playing, .paused] {
                let fallback = FallbackAttempt.fixture(
                    targetSeconds: target,
                    intent: intent
                )
                let probe = EffectCancellationProbe()
                let coordinator = PlaybackCoordinator(
                    initialState: makeLegacyRemuxState(fallback: fallback),
                    effectOperation: probe.operation
                )

                coordinator.send(.legacyRemuxSucceeded(fallback))
                await yieldUntil {
                    probe.startedEffects.contains(
                        .releaseStorageReservation(fallback.reservationID)
                    )
                        && (target == 0
                            ? probe.startedEffects.contains { effect in
                                if case .startSource = effect { return true }
                                return false
                            }
                            : probe.startedEffects.contains { effect in
                                if case .startSeek = effect { return true }
                                return false
                            })
                }

                coordinator.send(.legacyRemuxSucceeded(fallback))
                await Task.yield()
                XCTAssertEqual(
                    probe.startedEffects.filter {
                        $0 == .releaseStorageReservation(fallback.reservationID)
                    }.count,
                    1
                )
                coordinator.shutdown()
            }
        }
    }

    func testStopReturnsIdleAndCancelsEveryEffect() throws {
        var state = try makePlayingRangeState()

        let effects = state.reduce(.stop)

        XCTAssertEqual(effects, [.cancelAllEffects])
        XCTAssertEqual(state, .idle)
    }

    func testCoordinatorSessionReplacementAcknowledgesCancellationAndRejectsLateCallback() async {
        let probe = EffectCancellationProbe()
        let coordinator = PlaybackCoordinator(effectOperation: probe.operation)
        let oldSession = PlaybackSessionID.fresh()
        let oldEffect = PlaybackEffect.resolveDescriptor(oldSession)
        coordinator.send(
            .replaceSession(
                sessionID: oldSession,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil { probe.startedEffects.contains(oldEffect) }

        let replacement = PlaybackSessionID.fresh()
        let replacementEffect = PlaybackEffect.resolveDescriptor(replacement)
        coordinator.send(
            .replaceSession(
                sessionID: replacement,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.cancelledEffects.contains(oldEffect)
                && probe.startedEffects.contains(replacementEffect)
        }
        let replacementState = coordinator.state

        XCTAssertEqual(coordinator.activeEffectIDs, [.resolution(replacement)])
        XCTAssertEqual(coordinator.state.phase, .resolving(replacement))
        coordinator.send(
            .descriptorResolved(
                sessionID: oldSession,
                sources: .fixture(rangeEligible: true)
            )
        )
        XCTAssertEqual(coordinator.state, replacementState)
        XCTAssertEqual(coordinator.state.sessionBudget, replacementState.sessionBudget)
        coordinator.shutdown()
    }

    func testCoordinatorUserSkipAcknowledgesCancellationAndRejectsLateCallback() async {
        let probe = EffectCancellationProbe()
        let coordinator = PlaybackCoordinator(effectOperation: probe.operation)
        let oldSession = PlaybackSessionID.fresh()
        let oldEffect = PlaybackEffect.resolveDescriptor(oldSession)
        coordinator.send(
            .replaceSession(
                sessionID: oldSession,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil { probe.startedEffects.contains(oldEffect) }

        let skippedToSession = PlaybackSessionID.fresh()
        let skippedEffect = PlaybackEffect.resolveDescriptor(skippedToSession)
        coordinator.send(
            .userSkipped(
                to: skippedToSession,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.cancelledEffects.contains(oldEffect)
                && probe.startedEffects.contains(skippedEffect)
        }
        let skippedState = coordinator.state

        XCTAssertEqual(coordinator.activeEffectIDs, [.resolution(skippedToSession)])
        XCTAssertEqual(coordinator.state.phase, .resolving(skippedToSession))
        coordinator.send(
            .descriptorResolved(
                sessionID: oldSession,
                sources: .fixture(rangeEligible: true)
            )
        )
        XCTAssertEqual(coordinator.state, skippedState)
        XCTAssertEqual(coordinator.state.sessionBudget, skippedState.sessionBudget)
        coordinator.shutdown()
    }

    func testCoordinatorNewSeekAcknowledgesCancellationAndRejectsLateCallback() async throws {
        let initialState = try makePlayingRangeState()
        let probe = EffectCancellationProbe()
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation
        )

        coordinator.send(.requestSeek(targetSeconds: 10))
        let firstSeek = try XCTUnwrap(coordinator.state.activeSeekAttempt)
        let firstEffect = PlaybackEffect.startSeek(firstSeek)
        let firstToken = try XCTUnwrap(coordinator.activeWatchdogTokens.first)
        await yieldUntil { probe.startedEffects.contains(firstEffect) }

        coordinator.send(.requestSeek(targetSeconds: 75))
        let latestSeek = try XCTUnwrap(coordinator.state.activeSeekAttempt)
        let latestEffect = PlaybackEffect.startSeek(latestSeek)
        await yieldUntil {
            probe.cancelledEffects.contains(firstEffect)
                && probe.startedEffects.contains(latestEffect)
        }
        let latestState = coordinator.state

        XCTAssertNotEqual(firstSeek.id, latestSeek.id)
        XCTAssertEqual(coordinator.activeEffectIDs, [.seekUpstream(latestSeek.id)])
        XCTAssertFalse(coordinator.activeWatchdogTokens.contains(firstToken))
        XCTAssertEqual(
            coordinator.state.sessionBudget.rangeTransportRetries,
            initialState.sessionBudget.rangeTransportRetries
        )
        coordinator.send(.seekPrepared(firstSeek))
        coordinator.receiveWatchdogSignal(.upstreamError, token: firstToken)
        coordinator.receiveWatchdogSignal(.completed, token: firstToken)
        await Task.yield()
        XCTAssertEqual(coordinator.state, latestState)
        XCTAssertEqual(
            coordinator.state.sessionBudget.rangeTransportRetries,
            initialState.sessionBudget.rangeTransportRetries
        )
        coordinator.shutdown()
    }

    func testCoordinatorGateDenialAcknowledgesCancellationAndRejectsLateGateCallback() async throws {
        let probe = EffectCancellationProbe()
        let initialState = makeResolvingState()
        let sessionID = try XCTUnwrap(initialState.activeSessionID)
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation
        )

        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gateAttempt = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        let gateEffect = PlaybackEffect.evaluateFullResourceTransferGate(
            gateAttempt
        )
        await yieldUntil { probe.startedEffects.contains(gateEffect) }

        coordinator.send(
            .fullTransferGateDenied(
                gateAttempt,
                denial: PlaybackTransferGateDenial(category: .storage)
            )
        )
        await yieldUntil { probe.cancelledEffects.contains(gateEffect) }
        let deniedState = coordinator.state

        XCTAssertTrue(coordinator.activeEffectIDs.isEmpty)
        XCTAssertEqual(
            coordinator.state.phase,
            .failed(
                PlaybackFailure(
                    category: .storage,
                    isRecoverable: true,
                    lastConfirmedPosition: 0
                )
            )
        )
        let lateReservation = StorageReservationID(rawValue: UUID())
        coordinator.send(
            .fullTransferGateAllowed(
                gateAttempt,
                reservationID: lateReservation
            )
        )
        await yieldUntil {
            probe.startedEffects.contains(
                .releaseStorageReservation(lateReservation)
            )
        }
        XCTAssertEqual(coordinator.state.phase, deniedState.phase)
        XCTAssertEqual(
            coordinator.state.sessionBudget,
            deniedState.sessionBudget
        )
        XCTAssertEqual(probe.startedLegacyTransfers.count, 0)
        coordinator.shutdown()
    }

    func testCancelledGateOperationReturningReservationReleasesItAfterNetworkRegate() async throws {
        let probe = CancelledGateReservationProbe(
            callbackMode: .allowedWhenEvaluationIsCancelled
        )
        let initialState = makeResolvingState()
        let sessionID = try XCTUnwrap(initialState.activeSessionID)
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            networkClass: .wifiUnconstrained
        )

        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let wifiAttempt = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        await yieldUntil {
            probe.startedEffects.contains(
                .evaluateFullResourceTransferGate(wifiAttempt)
            )
        }
        let orphanedReservation = try XCTUnwrap(
            probe.reservation(for: wifiAttempt.id)
        )

        coordinator.send(.networkClassChanged(.cellular))
        let cellularAttempt = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        await yieldUntil {
            probe.cancelledGateAttemptIDs.contains(wifiAttempt.id)
                && probe.startedEffects.contains(
                    .releaseStorageReservation(orphanedReservation)
                )
        }

        XCTAssertNotEqual(cellularAttempt.id, wifiAttempt.id)
        XCTAssertEqual(cellularAttempt.networkClass, .cellular)
        XCTAssertEqual(
            coordinator.state.phase,
            .awaitingTransferConsent(cellularAttempt.request)
        )
        XCTAssertEqual(
            probe.releasedReservations.filter { $0 == orphanedReservation }.count,
            1
        )
        XCTAssertTrue(probe.startedLegacyTransfers.isEmpty)
        coordinator.shutdown()
    }

    func testShutdownCleansReservationReturnedByCancelledConsentOperation() async throws {
        let probe = CancelledGateReservationProbe(
            callbackMode: .acceptedWhenConsentIsCancelled
        )
        let initialState = makeResolvingState()
        let sessionID = try XCTUnwrap(initialState.activeSessionID)
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            networkClass: .cellular
        )

        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gateAttempt = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        await yieldUntil {
            probe.startedEffects.contains(
                .evaluateFullResourceTransferGate(gateAttempt)
            )
        }
        coordinator.send(.fullTransferGateRequiresConsent(gateAttempt))
        await yieldUntil {
            probe.startedEffects.contains(
                .presentFullTransferConsent(gateAttempt)
            )
        }
        let orphanedReservation = try XCTUnwrap(
            probe.reservation(for: gateAttempt.id)
        )

        coordinator.shutdown()
        await yieldUntil {
            probe.cancelledGateAttemptIDs.contains(gateAttempt.id)
                && probe.startedEffects.contains(
                    .releaseStorageReservation(orphanedReservation)
                )
        }

        XCTAssertEqual(coordinator.state.phase, .idle)
        XCTAssertEqual(coordinator.state.networkClass, .cellular)
        XCTAssertEqual(
            probe.releasedReservations.filter { $0 == orphanedReservation }.count,
            1
        )
        XCTAssertTrue(probe.startedLegacyTransfers.isEmpty)
        coordinator.shutdown()
    }

    func testConsentPromptRejectsLateAllowedResultUntilUserAccepts() throws {
        var state = try makePlayingRangeState()
        let rangeAttempt = try XCTUnwrap(state.activeSourceAttempt)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(
                    sourceAttempt: rangeAttempt,
                    token: .fixture(sessionID: rangeAttempt.sessionID)
                )
            ).transferGateAttempt
        )
        XCTAssertEqual(
            state.reduce(.fullTransferGateRequiresConsent(gateAttempt)),
            [.presentFullTransferConsent(gateAttempt)]
        )
        let promptedState = state
        let reservation = StorageReservationID(rawValue: UUID())

        let lateAllowed = state.reduce(
            .fullTransferGateAllowed(gateAttempt, reservationID: reservation)
        )

        XCTAssertEqual(lateAllowed, [.releaseStorageReservation(reservation)])
        XCTAssertEqual(state.phase, promptedState.phase)
        XCTAssertEqual(
            state.pendingTransferGateAttempt,
            promptedState.pendingTransferGateAttempt
        )
        XCTAssertEqual(state.sessionBudget, promptedState.sessionBudget)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
        XCTAssertFalse(lateAllowed.containsLegacyTransferStart)

        let acceptedReservation = StorageReservationID(rawValue: UUID())
        let accepted = state.reduce(
            .transferConsentAccepted(
                gateAttempt,
                reservationID: acceptedReservation
            )
        )
        XCTAssertTrue(accepted.containsLegacyTransferStart)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 0)
    }

    func testNetworkChangeInvalidatesInflightGateAndRejectsOldAllowedResult() async throws {
        let probe = EffectCancellationProbe()
        let initialState = makeResolvingState()
        let sessionID = try XCTUnwrap(initialState.activeSessionID)
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            networkClass: .wifiUnconstrained
        )
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let wifiGate = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        let wifiEffect = PlaybackEffect.evaluateFullResourceTransferGate(wifiGate)
        await yieldUntil { probe.startedEffects.contains(wifiEffect) }

        coordinator.send(.networkClassChanged(.cellular))
        await yieldUntil { probe.cancelledEffects.contains(wifiEffect) }
        let cellularGate = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        let cellularEffect = PlaybackEffect.evaluateFullResourceTransferGate(
            cellularGate
        )
        await yieldUntil { probe.startedEffects.contains(cellularEffect) }

        XCTAssertNotEqual(
            cellularGate.id,
            wifiGate.id
        )
        XCTAssertEqual(cellularGate.request.token, wifiGate.request.token)
        XCTAssertEqual(
            cellularGate.request.sourceAttempt,
            wifiGate.request.sourceAttempt
        )
        XCTAssertEqual(
            cellularGate.request.targetSeconds,
            wifiGate.request.targetSeconds
        )
        XCTAssertEqual(cellularGate.request.intent, wifiGate.request.intent)
        XCTAssertEqual(cellularGate.networkClass, .cellular)
        XCTAssertEqual(coordinator.state.networkClass, .cellular)
        let cellularState = coordinator.state

        let staleReservation = StorageReservationID(rawValue: UUID())
        coordinator.send(
            .fullTransferGateAllowed(
                wifiGate,
                reservationID: staleReservation
            )
        )
        await yieldUntil {
            probe.startedEffects.contains(
                .releaseStorageReservation(staleReservation)
            )
        }
        XCTAssertEqual(coordinator.state.phase, cellularState.phase)
        XCTAssertEqual(
            coordinator.state.pendingTransferGateAttempt,
            cellularState.pendingTransferGateAttempt
        )
        XCTAssertEqual(
            coordinator.state.sessionBudget,
            cellularState.sessionBudget
        )
        XCTAssertEqual(probe.startedLegacyTransfers.count, 0)
        coordinator.shutdown()
    }

    func testNetworkChangeAfterPromptCannotMintOrPresentSecondConsent() throws {
        var state = try makePlayingRangeState()
        let rangeAttempt = try XCTUnwrap(state.activeSourceAttempt)
        let gateAttempt = try XCTUnwrap(
            state.reduce(
                .requestLegacyFallback(
                    sourceAttempt: rangeAttempt,
                    token: .fixture(sessionID: rangeAttempt.sessionID)
                )
            ).transferGateAttempt
        )
        let request = gateAttempt.request
        XCTAssertEqual(
            state.reduce(.fullTransferGateRequiresConsent(gateAttempt)),
            [.presentFullTransferConsent(gateAttempt)]
        )
        XCTAssertEqual(state.consumedConsentTokens, [request.token])

        let networkEffects = state.reduce(.networkClassChanged(.cellular))

        XCTAssertTrue(networkEffects.containsTransferGateCancellation)
        XCTAssertFalse(networkEffects.containsTransferGateEvaluation)
        XCTAssertFalse(networkEffects.containsConsentPresentation)
        XCTAssertEqual(state.consumedConsentTokens, [request.token])
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: request.token.failureCategory,
                    isRecoverable: true,
                    lastConfirmedPosition: 0
                )
            )
        )
        let staleReservation = StorageReservationID(rawValue: UUID())
        XCTAssertEqual(
            state.reduce(
                .transferConsentAccepted(
                    gateAttempt,
                    reservationID: staleReservation
                )
            ),
            [.releaseStorageReservation(staleReservation)]
        )
    }

    func testSameNetworkClassUpdateDoesNotInvalidatePendingGate() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)
        _ = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let pendingState = state

        XCTAssertTrue(
            state.reduce(.networkClassChanged(.wifiUnconstrained)).isEmpty
        )
        XCTAssertEqual(state, pendingState)
    }

    func testCoordinatorOwnedResolverWatchdogCancelsIOBeforeSingleExpiry() async {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = EffectCancellationProbe()
        let coordinator = PlaybackCoordinator(
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        let sessionID = PlaybackSessionID.fresh()

        coordinator.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        let expiredToken = try! XCTUnwrap(coordinator.activeWatchdogTokens.first)
        XCTAssertEqual(coordinator.activeWatchdogTokens.count, 1)
        XCTAssertEqual(coordinator.state.sessionBudget.resolverRetries, 1)

        clock.advance(by: 30)
        await yieldUntil {
            coordinator.state.sessionBudget.resolverRetries == 0
                && probe.cancelledEffects.count == 1
        }

        XCTAssertEqual(coordinator.state.sessionBudget.resolverRetries, 0)
        XCTAssertEqual(probe.cancelledEffects, [.resolveDescriptor(sessionID)])
        XCTAssertEqual(coordinator.state.phase, .resolving(sessionID))
        XCTAssertFalse(coordinator.activeWatchdogTokens.contains(expiredToken))

        coordinator.receiveWatchdogSignal(.completed, token: expiredToken)
        await Task.yield()
        XCTAssertEqual(coordinator.state.sessionBudget.resolverRetries, 0)
        XCTAssertEqual(probe.cancelledEffects.count, 1)
    }

    func testResolverWatchdogDoesNotAwaitCancellationIgnoringEffect() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = CancellationIgnoringResolverProbe()
        let coordinator = PlaybackCoordinator(
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        let sessionID = PlaybackSessionID.fresh()
        coordinator.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.resolverInvocationCount == 1
                && coordinator.activeWatchdogTokens.count == 1
        }

        clock.advance(by: 30)
        await yieldUntil {
            probe.resolverInvocationCount == 2
                && coordinator.state.sessionBudget.resolverRetries == 0
        }
        let stateAfterRetry = coordinator.state

        probe.resumeResolver(invocation: 1)
        await yieldUntil { probe.completedResolverInvocations.contains(1) }

        XCTAssertEqual(coordinator.state, stateAfterRetry)
        XCTAssertEqual(coordinator.state.phase, .resolving(sessionID))
        XCTAssertEqual(coordinator.state.sessionBudget.resolverRetries, 0)
        coordinator.send(.stop)
        probe.resumeAllResolvers()
        await Task.yield()
    }

    func testInitialRangeWatchdogDoesNotAwaitCancellationIgnoringEffect() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = CancellationIgnoringRangeProbe()
        let coordinator = PlaybackCoordinator(
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        let sessionID = PlaybackSessionID.fresh()
        coordinator.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.initialRangeInvocationCount == 1
                && coordinator.activeWatchdogTokens.count == 1
        }
        let sourceAttempt = try XCTUnwrap(coordinator.state.activeSourceAttempt)

        clock.advance(by: 30)
        await yieldUntil {
            probe.rangeRetryInvocationCount == 1
                && coordinator.state.sessionBudget.rangeTransportRetries == 1
        }
        let stateAfterRetry = coordinator.state

        probe.resumeInitialRange()
        await yieldUntil { probe.initialRangeCompleted }

        XCTAssertEqual(coordinator.state, stateAfterRetry)
        XCTAssertEqual(coordinator.state.phase, .preparing(sourceAttempt))
        XCTAssertEqual(coordinator.state.sessionBudget.rangeTransportRetries, 1)
        coordinator.send(.stop)
        probe.resumeRangeRetry()
        await Task.yield()
    }

    func testSeekWatchdogDoesNotAwaitCancellationIgnoringEffect() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = CancellationIgnoringSeekProbe()
        let initialState = try makePlayingRangeState()
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        coordinator.send(.requestSeek(targetSeconds: 64))
        let seekAttempt = try XCTUnwrap(coordinator.state.activeSeekAttempt)
        await yieldUntil {
            probe.initialSeekInvocationCount == 1
                && coordinator.activeWatchdogTokens.count == 1
        }

        clock.advance(by: 30)
        await yieldUntil {
            probe.seekRetryInvocationCount == 1
                && coordinator.state.sessionBudget.rangeTransportRetries == 1
        }
        let stateAfterRetry = coordinator.state

        probe.resumeInitialSeek()
        await yieldUntil { probe.initialSeekCompleted }

        XCTAssertEqual(coordinator.state, stateAfterRetry)
        XCTAssertEqual(coordinator.state.phase, .seeking(seekAttempt))
        XCTAssertEqual(coordinator.state.sessionBudget.rangeTransportRetries, 1)
        coordinator.send(.stop)
        probe.resumeSeekRetry()
        await Task.yield()
    }

    func testActiveLegacyPathRevalidationUsesFreshAttemptAndReleasesOldReservation() throws {
        var state = makeResolvingState()
        let sessionID = try XCTUnwrap(state.activeSessionID)
        _ = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let initialGate = try XCTUnwrap(state.pendingTransferGateAttempt)
        let initialRequest = initialGate.request
        let oldReservation = StorageReservationID(rawValue: UUID())
        _ = state.reduce(
            .fullTransferGateAllowed(
                initialGate,
                reservationID: oldReservation
            )
        )
        let oldFallback = try XCTUnwrap(state.legacyDownloadingAttempt)

        let revalidationEffects = state.reduce(
            .networkSnapshotChanged(
                .cellular(constrained: false, pathVersion: 2)
            )
        )
        let retryGate = try XCTUnwrap(state.pendingTransferGateAttempt)
        let retryRequest = retryGate.request
        XCTAssertEqual(
            revalidationEffects,
            [
                .releaseReservationAndEvaluateFullResourceTransferGate(
                    oldReservationID: oldReservation,
                    attempt: retryGate
                )
            ]
        )

        XCTAssertEqual(
            retryRequest.sourceAttempt.sessionID,
            oldFallback.sourceAttempt.sessionID
        )
        XCTAssertEqual(retryRequest.sourceAttempt.source, .legacyDownloadRemux)
        XCTAssertNotEqual(
            retryRequest.sourceAttempt.id,
            oldFallback.sourceAttempt.id
        )
        XCTAssertEqual(
            retryGate.replacedLegacySourceAttemptID,
            oldFallback.sourceAttempt.id
        )
        XCTAssertEqual(retryRequest.targetSeconds, oldFallback.targetSeconds)
        XCTAssertEqual(retryRequest.intent, oldFallback.intent)
        XCTAssertEqual(retryRequest.token.intent, initialRequest.token.intent)
        XCTAssertEqual(retryRequest.token.actionID, initialRequest.token.actionID)
        XCTAssertEqual(state.sessionBudget.legacyMeteredTransportRetries, 0)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)

        XCTAssertEqual(
            state.reduce(.fullTransferGateRequiresConsent(retryGate)),
            [.presentFullTransferConsent(retryGate)]
        )
        let newReservation = StorageReservationID(rawValue: UUID())
        let acceptedEffects = state.reduce(
            .transferConsentAccepted(
                retryGate,
                reservationID: newReservation
            )
        )
        let newFallback = try XCTUnwrap(state.legacyDownloadingAttempt)
        XCTAssertEqual(acceptedEffects, [.startLegacyTransfer(newFallback)])
        XCTAssertNotEqual(newFallback.sourceAttempt.id, oldFallback.sourceAttempt.id)
        XCTAssertEqual(newFallback.reservationID, newReservation)
        XCTAssertNotEqual(newFallback.reservationID, oldReservation)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
    }

    func testLegacyExpiryWaitsForDriverCancellationAcknowledgementBeforeRegate() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = LegacyCancellationBarrierProbe()
        let initialState = makeResolvingState()
        let sessionID = try XCTUnwrap(initialState.activeSessionID)
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )

        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gateAttempt = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        let reservation = StorageReservationID(rawValue: UUID())
        coordinator.send(
            .fullTransferGateAllowed(gateAttempt, reservationID: reservation)
        )
        let fallback = try XCTUnwrap(coordinator.state.legacyDownloadingAttempt)
        await yieldUntil {
            probe.startedEffects.contains(.startLegacyTransfer(fallback))
                && !coordinator.activeWatchdogTokens.isEmpty
        }

        clock.advance(by: 15)
        await yieldUntil { probe.legacyCancellationObserved }

        XCTAssertFalse(probe.compoundGateStarted)
        XCTAssertEqual(coordinator.state.phase, .legacyDownloading(fallback))

        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil {
            probe.legacyCancellationAcknowledged
                && probe.compoundGateStarted
        }

        XCTAssertTrue(probe.compoundStartedAfterCancellationAcknowledgement)
        let retryRequest = try XCTUnwrap(coordinator.state.pendingFallbackRequest)
        XCTAssertEqual(probe.compoundOldReservationID, reservation)
        XCTAssertEqual(
            probe.compoundOldSourceAttemptID,
            fallback.sourceAttempt.id
        )
        XCTAssertEqual(probe.compoundRequest, retryRequest)
        XCTAssertEqual(
            probe.startedEffects.filter { effect in
                if case .releaseReservationAndEvaluateFullResourceTransferGate(
                    oldReservationID: reservation,
                    attempt: _
                ) = effect { return true }
                return false
            }.count,
            1
        )
        coordinator.shutdown()
    }

    func testLegacyCancellationAcknowledgementTimeoutFailsClosedWithoutReleasingCapacity() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = LegacyCancellationBarrierProbe()
        let initialState = makeResolvingState()
        let sessionID = try XCTUnwrap(initialState.activeSessionID)
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )

        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gateAttempt = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        let reservation = StorageReservationID(rawValue: UUID())
        coordinator.send(
            .fullTransferGateAllowed(gateAttempt, reservationID: reservation)
        )
        let fallback = try XCTUnwrap(coordinator.state.legacyDownloadingAttempt)
        await yieldUntil {
            probe.startedEffects.contains(.startLegacyTransfer(fallback))
                && !coordinator.activeWatchdogTokens.isEmpty
        }

        clock.advance(by: 15)
        await yieldUntil { probe.legacyCancellationObserved }
        XCTAssertEqual(coordinator.state.phase, .legacyDownloading(fallback))

        clock.advance(by: 5)
        await yieldUntil {
            coordinator.state.phase
                == .failed(
                    PlaybackFailure(
                        category: .transport,
                        isRecoverable: true,
                        lastConfirmedPosition: 0
                    )
                )
        }

        XCTAssertFalse(probe.compoundGateStarted)
        XCTAssertFalse(
            probe.startedEffects.contains(.releaseStorageReservation(reservation))
        )
        XCTAssertEqual(coordinator.state.sessionBudget.legacyWiFiTransportRetries, 0)
        XCTAssertEqual(coordinator.state.sessionBudget.rangeToLegacyDowngrades, 1)
        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil {
            probe.legacyCancellationAcknowledged
                && probe.startedEffects.contains(
                    .releaseStorageReservation(reservation)
                )
        }
        XCTAssertFalse(probe.compoundGateStarted)
        XCTAssertEqual(
            probe.startedEffects.filter {
                $0 == .releaseStorageReservation(reservation)
            }.count,
            1
        )
        XCTAssertEqual(
            coordinator.state.phase,
            .failed(
                PlaybackFailure(
                    category: .transport,
                    isRecoverable: true,
                    lastConfirmedPosition: 0
                )
            )
        )
        XCTAssertEqual(coordinator.state.sessionBudget.legacyWiFiTransportRetries, 0)
        coordinator.shutdown()
    }

    func testShutdownIsIdempotentCancelsEffectAndWatchdogAndRejectsLaterEvents() async {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = CancellationAcknowledgingWatchdogScheduler()
        let probe = EffectCancellationProbe()
        let coordinator = PlaybackCoordinator(
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        let sessionID = PlaybackSessionID.fresh()
        let resolver = PlaybackEffect.resolveDescriptor(sessionID)
        coordinator.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.startedEffects.contains(resolver)
                && scheduler.startedSleeps == 1
        }

        coordinator.shutdown()
        await yieldUntil {
            probe.cancelledEffects.contains(resolver)
                && scheduler.cancelledSleeps == 1
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.activeEffectIDs.isEmpty)
        XCTAssertTrue(coordinator.activeWatchdogTokens.isEmpty)
        let startedCount = probe.startedEffects.count
        let cancelledCount = probe.cancelledEffects.count

        coordinator.shutdown()
        coordinator.send(
            .replaceSession(
                sessionID: .fresh(),
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: true)
            )
        )
        await Task.yield()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(probe.startedEffects.count, startedCount)
        XCTAssertEqual(probe.cancelledEffects.count, cancelledCount)
        XCTAssertEqual(scheduler.cancelledSleeps, 1)
    }

    func testOrdinaryStopRemainsReusableAndPreservesCurrentNetworkClass() async {
        let probe = EffectCancellationProbe()
        let coordinator = PlaybackCoordinator(
            effectOperation: probe.operation,
            networkClass: .cellular
        )

        coordinator.send(.stop)
        let replacementSession = PlaybackSessionID.fresh()
        let resolver = PlaybackEffect.resolveDescriptor(replacementSession)
        coordinator.send(
            .replaceSession(
                sessionID: replacementSession,
                desiredIntent: .playing,
                initialPosition: 4
            )
        )
        await yieldUntil { probe.startedEffects.contains(resolver) }

        XCTAssertEqual(coordinator.state.phase, .resolving(replacementSession))
        XCTAssertEqual(coordinator.state.networkClass, .cellular)
        XCTAssertEqual(coordinator.activeEffectIDs, [.resolution(replacementSession)])
        coordinator.shutdown()
    }

    func testDeinitCancelsOwnedEffectAndWatchdogTasks() async {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = CancellationAcknowledgingWatchdogScheduler()
        let probe = EffectCancellationProbe()
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        weak var weakCoordinator = coordinator
        let sessionID = PlaybackSessionID.fresh()
        let resolver = PlaybackEffect.resolveDescriptor(sessionID)
        coordinator?.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.startedEffects.contains(resolver)
                && scheduler.startedSleeps == 1
        }

        coordinator = nil
        await yieldUntil {
            weakCoordinator == nil
                && probe.cancelledEffects.contains(resolver)
                && scheduler.cancelledSleeps == 1
        }

        XCTAssertNil(weakCoordinator)
        XCTAssertEqual(probe.cancelledEffects, [resolver])
        XCTAssertEqual(scheduler.cancelledSleeps, 1)
    }

    func testDeinitCleansReservationReturnedByCancelledGateWithoutRetainingOwner() async throws {
        let probe = CancelledGateReservationProbe(
            callbackMode: .allowedWhenEvaluationIsCancelled
        )
        let initialState = makeResolvingState()
        let sessionID = try XCTUnwrap(initialState.activeSessionID)
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            networkClass: .wifiUnconstrained
        )
        weak var weakCoordinator = coordinator

        coordinator?.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gateAttempt = try XCTUnwrap(
            coordinator?.state.pendingTransferGateAttempt
        )
        await yieldUntil {
            probe.startedEffects.contains(
                .evaluateFullResourceTransferGate(gateAttempt)
            )
        }
        let orphanedReservation = try XCTUnwrap(
            probe.reservation(for: gateAttempt.id)
        )

        coordinator = nil
        await yieldUntil {
            weakCoordinator == nil
                && probe.cancelledGateAttemptIDs.contains(gateAttempt.id)
                && probe.startedEffects.contains(
                    .releaseStorageReservation(orphanedReservation)
                )
        }

        XCTAssertNil(weakCoordinator)
        XCTAssertEqual(
            probe.releasedReservations.filter { $0 == orphanedReservation }.count,
            1
        )
        XCTAssertTrue(probe.startedLegacyTransfers.isEmpty)
    }

    func testCoordinatorColdRangeStartArmsActiveWatchdogAndRejectsLateOldSignals() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = ColdRangeLifecycleProbe()
        let coordinator = PlaybackCoordinator(
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        let sessionID = PlaybackSessionID.fresh()

        coordinator.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            if case .playing = coordinator.state.phase {
                guard let attempt = coordinator.state.activeSourceAttempt else {
                    return false
                }
                return coordinator.activeWatchdogTokens.count == 1
                    && probe.startedEffects.contains(.monitorActiveRange(attempt))
            }
            return false
        }
        let attempt = try XCTUnwrap(coordinator.state.activeSourceAttempt)
        let expiredToken = try XCTUnwrap(coordinator.activeWatchdogTokens.first)
        XCTAssertEqual(coordinator.activeEffectIDs, [.source(attempt.id)])
        XCTAssertTrue(
            probe.startedEffects.contains(.monitorActiveRange(attempt))
        )

        clock.advance(by: 10)
        await yieldUntil {
            coordinator.state.sessionBudget.rangeTransportRetries == 1
                && !coordinator.activeWatchdogTokens.contains(expiredToken)
        }

        coordinator.receiveWatchdogSignal(
            .validatedResponseBodyBytes(totalUniqueBytes: 1),
            token: expiredToken
        )
        coordinator.receiveWatchdogSignal(.upstreamError, token: expiredToken)
        coordinator.receiveWatchdogSignal(.completed, token: expiredToken)
        await Task.yield()

        XCTAssertEqual(coordinator.state.sessionBudget.rangeTransportRetries, 1)
        XCTAssertEqual(coordinator.activeWatchdogTokens.count, 1)
        coordinator.send(.stop)
    }

    func testCoordinatorLocalSeeksNeverArmRangeUpstreamWatchdogOrConsumeRetry() throws {
        for source in [PlaybackSource.explicitDownload, .remuxCache] {
            let initialState = makePlayingLocalState(source: source)
            let coordinator = PlaybackCoordinator(
                initialState: initialState,
                effectOperation: longRunningOperation
            )

            coordinator.send(.requestSeek(targetSeconds: 45))
            let seek = try XCTUnwrap(coordinator.state.activeSeekAttempt)

            XCTAssertEqual(coordinator.activeEffectIDs, [.seekUpstream(seek.id)])
            XCTAssertTrue(coordinator.activeWatchdogTokens.isEmpty)
            XCTAssertEqual(
                coordinator.state.sessionBudget.rangeTransportRetries,
                initialState.sessionBudget.rangeTransportRetries
            )
            coordinator.send(.stop)
        }
    }

    func testCoordinatorOwnedRemuxUsesTrackDurationForInitialAndRetryDeadline() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = EffectCancellationProbe()
        let sourceAttempt = SourceAttempt(
            sessionID: .fresh(),
            id: .fresh(),
            source: .legacyDownloadRemux
        )
        let fallback = FallbackAttempt(
            sourceAttempt: sourceAttempt,
            targetSeconds: 0,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        let initialState = PlaybackSessionState(
            phase: .legacyDownloading(fallback),
            selectedSource: .legacyDownloadRemux,
            desiredPlaybackIntent: .playing,
            latestRequestedTarget: 0,
            lastConfirmedPosition: 0,
            sessionBudget: .initial,
            consumedConsentTokens: [],
            resourceGenerationFingerprint: .fixture
        )
        let coordinator = PlaybackCoordinator(
            initialState: initialState,
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )

        coordinator.send(
            .legacyTransferCompleted(
                fallback,
                trackDurationSeconds: 240
            )
        )
        await yieldUntil {
            probe.startedEffects.contains(
                .startLegacyRemux(fallback, trackDurationSeconds: 240)
            ) && coordinator.activeWatchdogTokens.count == 1
        }
        let initialToken = try XCTUnwrap(coordinator.activeWatchdogTokens.first)

        for outputBytes in Int64(1)...8 {
            clock.advance(by: 14.9)
            coordinator.receiveWatchdogSignal(
                .remuxOutputBytes(totalBytes: outputBytes),
                token: initialToken
            )
            await Task.yield()
        }
        XCTAssertEqual(coordinator.state.sessionBudget.legacyRemuxRetries, 1)

        clock.advance(by: 0.8)
        await yieldUntil {
            coordinator.state.sessionBudget.legacyRemuxRetries == 0
                && probe.startedEffects.contains(
                    .retryLegacyRemux(
                        fallback,
                        trackDurationSeconds: 240
                    )
                )
        }

        XCTAssertFalse(coordinator.activeWatchdogTokens.contains(initialToken))
        XCTAssertEqual(coordinator.activeWatchdogTokens.count, 1)
        coordinator.send(.stop)
    }

    func testRangeSeekCancelsOldMonitorAndRearmsFreshMonitorAfterLatestVerification() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = ColdRangeLifecycleProbe()
        let coordinator = PlaybackCoordinator(
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkClass: .wifiUnconstrained
        )
        let sessionID = PlaybackSessionID.fresh()
        coordinator.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            coordinator.activeWatchdogTokens.count == 1
                && probe.startedEffects.contains { effect in
                    if case .monitorActiveRange = effect { return true }
                    return false
                }
        }
        let sourceAttempt = try XCTUnwrap(coordinator.state.activeSourceAttempt)
        let preSeekToken = try XCTUnwrap(coordinator.activeWatchdogTokens.first)
        let initialRetries = coordinator.state.sessionBudget.rangeTransportRetries

        coordinator.send(.requestSeek(targetSeconds: 10))
        let firstSeek = try XCTUnwrap(coordinator.state.activeSeekAttempt)
        XCTAssertFalse(coordinator.activeWatchdogTokens.contains(preSeekToken))
        XCTAssertEqual(
            coordinator.state.sessionBudget.rangeTransportRetries,
            initialRetries
        )

        coordinator.send(.requestSeek(targetSeconds: 85))
        let latestSeek = try XCTUnwrap(coordinator.state.activeSeekAttempt)
        XCTAssertNotEqual(firstSeek.id, latestSeek.id)
        await yieldUntil {
            coordinator.state.phase == .playing(sourceAttempt)
                && coordinator.activeWatchdogTokens.count == 1
                && !coordinator.activeWatchdogTokens.contains(preSeekToken)
                && probe.startedEffects.filter { effect in
                    if case .monitorActiveRange = effect { return true }
                    return false
                }.count == 2
        }

        coordinator.receiveWatchdogSignal(
            .validatedResponseBodyBytes(totalUniqueBytes: 1),
            token: preSeekToken
        )
        coordinator.receiveWatchdogSignal(.upstreamError, token: preSeekToken)
        coordinator.receiveWatchdogSignal(.completed, token: preSeekToken)
        await Task.yield()

        XCTAssertEqual(coordinator.state.latestRequestedTarget, 85)
        XCTAssertEqual(coordinator.state.lastConfirmedPosition, 85)
        XCTAssertEqual(
            coordinator.state.sessionBudget.rangeTransportRetries,
            initialRetries
        )
        XCTAssertTrue(
            probe.cancelledEffects.contains(.monitorActiveRange(sourceAttempt))
        )
        coordinator.send(.stop)
    }

    func testActiveLegacyPolicyChangeWaitsForCancellationAcknowledgementBeforeRegate() async throws {
        let probe = LegacyPolicyChangeProbe()
        let initialSnapshot = NetworkSnapshot.wifi(
            expensive: false,
            constrained: false,
            pathVersion: 1
        )
        let coordinator = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            networkSnapshot: initialSnapshot
        )
        let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let initialGate = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        let originalToken = initialGate.request.token
        let reservation = StorageReservationID(rawValue: UUID())
        coordinator.send(
            .fullTransferGateAllowed(initialGate, reservationID: reservation)
        )
        let originalFallback = try XCTUnwrap(
            coordinator.state.legacyDownloadingAttempt
        )
        await yieldUntil {
            probe.legacyBodyBytes == 1
                && probe.startedLegacyTransfers == 1
        }
        coordinator.send(.requestSeek(targetSeconds: 93))

        let expensiveSnapshot = NetworkSnapshot.wifi(
            expensive: true,
            constrained: false,
            pathVersion: 2
        )
        coordinator.send(.networkSnapshotChanged(expensiveSnapshot))
        await yieldUntil { probe.legacyCancellationObserved }

        XCTAssertFalse(probe.compoundGateStarted)
        XCTAssertEqual(probe.releasedReservations, [])
        XCTAssertEqual(probe.legacyBodyBytes, 1)
        XCTAssertEqual(coordinator.state.networkSnapshot, expensiveSnapshot)

        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil {
            probe.legacyCancellationAcknowledged
                && probe.compoundGateStarted
        }

        let retryGate = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        XCTAssertTrue(probe.compoundStartedAfterCancellationAcknowledgement)
        XCTAssertEqual(probe.compoundOldReservationID, reservation)
        XCTAssertEqual(
            probe.compoundOldSourceAttemptID,
            originalFallback.sourceAttempt.id
        )
        XCTAssertEqual(retryGate.request.token, originalToken)
        XCTAssertEqual(
            retryGate.request.sourceAttempt.sessionID,
            originalFallback.sourceAttempt.sessionID
        )
        XCTAssertEqual(
            retryGate.request.sourceAttempt.source,
            .legacyDownloadRemux
        )
        XCTAssertNotEqual(
            retryGate.request.sourceAttempt.id,
            originalFallback.sourceAttempt.id
        )
        XCTAssertEqual(retryGate.request.targetSeconds, 93)
        XCTAssertEqual(retryGate.networkPathVersion, expensiveSnapshot.pathVersion)
        XCTAssertEqual(retryGate.networkClass, .wifiUnconstrained)
        XCTAssertEqual(probe.startedLegacyTransfers, 1)
        XCTAssertEqual(probe.legacyBodyBytes, 1)
        let freshReservation = StorageReservationID(rawValue: UUID())
        coordinator.send(
            .fullTransferGateAllowed(
                retryGate,
                reservationID: freshReservation
            )
        )
        await yieldUntil { probe.startedLegacyTransfers == 2 }
        let revalidatedFallback = try XCTUnwrap(
            coordinator.state.legacyDownloadingAttempt
        )
        XCTAssertEqual(probe.startedLegacyTransfers, 2)
        XCTAssertEqual(
            revalidatedFallback.sourceAttempt,
            retryGate.request.sourceAttempt
        )
        coordinator.shutdown()
    }

    func testPolicyChangeCancellationTimeoutFailsClosedThenLateAckReleasesOnce() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = LegacyPolicyChangeProbe()
        let coordinator = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkSnapshot: .wifi(
                expensive: false,
                constrained: false,
                pathVersion: 1
            )
        )
        let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
        let reservation = StorageReservationID(rawValue: UUID())
        coordinator.send(.fullTransferGateAllowed(gate, reservationID: reservation))
        await yieldUntil { probe.legacyBodyBytes == 1 }

        coordinator.send(
            .networkSnapshotChanged(
                .wifi(expensive: true, constrained: false, pathVersion: 2)
            )
        )
        await yieldUntil { probe.legacyCancellationObserved }
        clock.advance(by: 5)
        await yieldUntil {
            if case .failed = coordinator.state.phase { return true }
            return false
        }

        XCTAssertFalse(probe.compoundGateStarted)
        XCTAssertTrue(probe.releasedReservations.isEmpty)
        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil { probe.releasedReservations == [reservation] }
        XCTAssertEqual(probe.releasedReservations, [reservation])
        coordinator.shutdown()
    }

    func testStopDuringPolicyCancellationBarrierWaitsForAckThenReleasesOnce() async throws {
        let probe = LegacyPolicyChangeProbe()
        let coordinator = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            networkSnapshot: .wifi(
                expensive: false,
                constrained: false,
                pathVersion: 1
            )
        )
        let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
        let reservation = StorageReservationID(rawValue: UUID())
        coordinator.send(.fullTransferGateAllowed(gate, reservationID: reservation))
        await yieldUntil { probe.legacyBodyBytes == 1 }
        coordinator.send(
            .networkSnapshotChanged(
                .wifi(expensive: true, constrained: false, pathVersion: 2)
            )
        )
        await yieldUntil { probe.legacyCancellationObserved }

        coordinator.send(.stop)
        XCTAssertEqual(coordinator.state.phase, .idle)
        XCTAssertTrue(probe.releasedReservations.isEmpty)
        XCTAssertFalse(probe.compoundGateStarted)

        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil { probe.releasedReservations == [reservation] }
        XCTAssertEqual(probe.releasedReservations, [reservation])
        XCTAssertFalse(probe.compoundGateStarted)
        coordinator.shutdown()
    }

    func testDeinitDuringActiveLegacyWaitsForCancellationAckBeforeRelease() async throws {
        let probe = LegacyPolicyChangeProbe()
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation
        )
        let reservation = StorageReservationID(rawValue: UUID())
        weak var weakCoordinator: PlaybackCoordinator?
        do {
            let active = try XCTUnwrap(coordinator)
            weakCoordinator = active
            let sessionID = try XCTUnwrap(active.state.activeSessionID)
            active.send(
                .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: false)
                )
            )
            let gate = try XCTUnwrap(active.state.pendingTransferGateAttempt)
            active.send(.fullTransferGateAllowed(gate, reservationID: reservation))
        }
        await yieldUntil { probe.legacyBodyBytes == 1 }

        coordinator = nil
        await yieldUntil { probe.legacyCancellationObserved }
        XCTAssertTrue(probe.releasedReservations.isEmpty)
        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil { probe.releasedReservations == [reservation] }
        XCTAssertNil(weakCoordinator)
        XCTAssertEqual(probe.releasedReservations, [reservation])
    }

    func testActiveLegacyStopAndReplaceReleaseOnlyAfterCancellationAck() async throws {
        for replacesSession in [false, true] {
            let probe = LegacyPolicyChangeProbe()
            let coordinator = PlaybackCoordinator(
                initialState: makeResolvingState(),
                effectOperation: probe.operation
            )
            let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
            coordinator.send(
                .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: false)
                )
            )
            let gate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
            let reservation = StorageReservationID(rawValue: UUID())
            coordinator.send(.fullTransferGateAllowed(gate, reservationID: reservation))
            await yieldUntil { probe.legacyBodyBytes == 1 }

            if replacesSession {
                coordinator.send(
                    .replaceSession(
                        sessionID: .fresh(),
                        desiredIntent: .playing,
                        initialPosition: 0
                    )
                )
            } else {
                coordinator.send(.stop)
            }
            await yieldUntil { probe.legacyCancellationObserved }
            XCTAssertTrue(probe.releasedReservations.isEmpty)
            XCTAssertEqual(probe.startedLegacyTransfers, 1)

            probe.allowLegacyCancellationAcknowledgement()
            await yieldUntil { probe.releasedReservations == [reservation] }
            XCTAssertEqual(probe.releasedReservations, [reservation])
            XCTAssertEqual(probe.startedLegacyTransfers, 1)
            if !replacesSession {
                XCTAssertEqual(coordinator.state.phase, .idle)
            }
            coordinator.shutdown()
        }
    }

    func testDeinitDuringPolicyBarrierPreservesOldReservationUntilLateAck() async throws {
        let probe = LegacyPolicyChangeProbe()
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            networkSnapshot: .wifi(
                expensive: false,
                constrained: false,
                pathVersion: 1
            )
        )
        let reservation = StorageReservationID(rawValue: UUID())
        do {
            let active = try XCTUnwrap(coordinator)
            let sessionID = try XCTUnwrap(active.state.activeSessionID)
            active.send(
                .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: false)
                )
            )
            let gate = try XCTUnwrap(active.state.pendingTransferGateAttempt)
            active.send(.fullTransferGateAllowed(gate, reservationID: reservation))
            await yieldUntil { probe.legacyBodyBytes == 1 }
            active.send(
                .networkSnapshotChanged(
                    .wifi(expensive: true, constrained: false, pathVersion: 2)
                )
            )
        }
        await yieldUntil { probe.legacyBodyBytes == 1 }
        await yieldUntil { probe.legacyCancellationObserved }

        coordinator = nil
        XCTAssertTrue(probe.releasedReservations.isEmpty)
        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil { probe.releasedReservations == [reservation] }
        XCTAssertEqual(probe.releasedReservations, [reservation])
        XCTAssertFalse(probe.compoundGateStarted)
    }

    func testActiveLegacyRegatesForEveryPolicyRelevantMeteredTransition() async throws {
        let snapshots: [NetworkSnapshot] = [
            .wifi(expensive: true, constrained: false, pathVersion: 2),
            .wifi(expensive: false, constrained: true, pathVersion: 2),
            .cellular(constrained: false, pathVersion: 2),
        ]

        for snapshot in snapshots {
            let probe = LegacyPolicyChangeProbe(autoAcknowledgeCancellation: true)
            let coordinator = PlaybackCoordinator(
                initialState: makeResolvingState(),
                effectOperation: probe.operation,
                networkSnapshot: .wifi(
                    expensive: false,
                    constrained: false,
                    pathVersion: 1
                )
            )
            let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
            coordinator.send(
                .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: false)
                )
            )
            let gate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
            coordinator.send(
                .fullTransferGateAllowed(
                    gate,
                    reservationID: StorageReservationID(rawValue: UUID())
                )
            )
            await yieldUntil { probe.legacyBodyBytes == 1 }

            coordinator.send(.networkSnapshotChanged(snapshot))
            await yieldUntil { probe.compoundGateStarted }

            XCTAssertTrue(probe.compoundStartedAfterCancellationAcknowledgement)
            XCTAssertEqual(probe.legacyBodyBytes, 1)
            XCTAssertEqual(coordinator.state.networkSnapshot, snapshot)
            XCTAssertNotNil(coordinator.state.pendingTransferGateAttempt)
            coordinator.shutdown()
        }
    }

    func testPolicyChangeAfterConsumedConsentMintsFreshPromptToken() async throws {
        let probe = LegacyPolicyChangeProbe(autoAcknowledgeCancellation: true)
        let coordinator = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            networkSnapshot: .cellular(constrained: false, pathVersion: 1)
        )
        let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let initialGate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
        coordinator.send(.fullTransferGateRequiresConsent(initialGate))
        let initialToken = initialGate.request.token
        coordinator.send(
            .transferConsentAccepted(
                initialGate,
                reservationID: StorageReservationID(rawValue: UUID())
            )
        )
        await yieldUntil { probe.legacyBodyBytes == 1 }

        coordinator.send(
            .networkSnapshotChanged(
                .cellular(constrained: true, pathVersion: 2)
            )
        )
        await yieldUntil { probe.compoundGateStarted }

        let refreshedGate = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt
        )
        XCTAssertNotEqual(refreshedGate.request.token, initialToken)
        let promptCountBefore = probe.startedEffects.filter { effect in
            if case .presentFullTransferConsent = effect { return true }
            return false
        }.count
        coordinator.send(.fullTransferGateRequiresConsent(refreshedGate))
        await yieldUntil {
            probe.startedEffects.filter { effect in
                if case .presentFullTransferConsent = effect { return true }
                return false
            }.count == promptCountBefore + 1
        }
        XCTAssertEqual(probe.startedLegacyTransfers, 1)
        XCTAssertEqual(probe.legacyBodyBytes, 1)
        coordinator.send(
            .transferConsentAccepted(
                refreshedGate,
                reservationID: StorageReservationID(rawValue: UUID())
            )
        )
        await yieldUntil { probe.startedLegacyTransfers == 2 }
        XCTAssertEqual(probe.startedLegacyTransfers, 2)
        coordinator.shutdown()
    }

    func testExpensiveWiFiLegacyFailureHasZeroAutomaticRetry() throws {
        var state = makeResolvingState()
        let expensive = NetworkSnapshot.wifi(
            expensive: true,
            constrained: false,
            pathVersion: 1
        )
        _ = state.reduce(.networkSnapshotChanged(expensive))
        let sessionID = try XCTUnwrap(state.activeSessionID)
        _ = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gate = try XCTUnwrap(state.pendingTransferGateAttempt)
        let reservation = StorageReservationID(rawValue: UUID())
        _ = state.reduce(.fullTransferGateRequiresConsent(gate))
        _ = state.reduce(
            .transferConsentAccepted(gate, reservationID: reservation)
        )
        guard case .legacyDownloading(let attempt) = state.phase else {
            return XCTFail("Expected active metered legacy transfer")
        }

        let effects = state.reduce(
            .legacyTransferFailed(
                attempt,
                currentNetwork: expensive,
                failure: .transport
            )
        )

        guard case .failed(let failure) = state.phase else {
            return XCTFail("Expected fail-closed metered transport state")
        }
        XCTAssertEqual(failure.category, .transport)
        XCTAssertNil(state.pendingTransferGateAttempt)
        XCTAssertEqual(effects, [.releaseStorageReservation(reservation)])
    }

    func testRapidPolicyRevisionsUseLatestGateAtOriginalCancellationDeadline() async throws {
        let clock = FakeCoordinatorMonotonicClock()
        let scheduler = YieldingPlaybackWatchdogScheduler()
        let probe = LegacyPolicyChangeProbe()
        let coordinator = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            monotonicClock: clock,
            watchdogScheduler: scheduler,
            networkSnapshot: .wifi(
                expensive: false,
                constrained: false,
                pathVersion: 1
            )
        )
        let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
        coordinator.send(
            .fullTransferGateAllowed(
                gate,
                reservationID: StorageReservationID(rawValue: UUID())
            )
        )
        await yieldUntil { probe.legacyBodyBytes == 1 }
        coordinator.send(
            .networkSnapshotChanged(
                .wifi(expensive: true, constrained: false, pathVersion: 2)
            )
        )
        await yieldUntil { probe.legacyCancellationObserved }
        let firstRevalidationGateID = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt?.id
        )
        clock.advance(by: 4)
        coordinator.send(
            .networkSnapshotChanged(
                .wifi(expensive: false, constrained: true, pathVersion: 3)
            )
        )
        let latestGateID = try XCTUnwrap(
            coordinator.state.pendingTransferGateAttempt?.id
        )

        XCTAssertNotEqual(latestGateID, firstRevalidationGateID)
        clock.advance(by: 1)
        await yieldUntil {
            if case .failed = coordinator.state.phase { return true }
            return false
        }
        XCTAssertFalse(probe.compoundGateStarted)
        XCTAssertNotEqual(latestGateID, gate.id)
        probe.allowLegacyCancellationAcknowledgement()
        coordinator.shutdown()
    }

    func testReplaceDuringPolicyBarrierStartsNewResolverAndReleasesOldOnlyAfterAck() async throws {
        let probe = LegacyPolicyChangeProbe()
        let coordinator = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            networkSnapshot: .wifi(
                expensive: false,
                constrained: false,
                pathVersion: 1
            )
        )
        let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
        let reservation = StorageReservationID(rawValue: UUID())
        coordinator.send(.fullTransferGateAllowed(gate, reservationID: reservation))
        await yieldUntil { probe.legacyBodyBytes == 1 }
        coordinator.send(
            .networkSnapshotChanged(
                .wifi(expensive: true, constrained: false, pathVersion: 2)
            )
        )
        await yieldUntil { probe.legacyCancellationObserved }

        let replacementSession = PlaybackSessionID.fresh()
        coordinator.send(
            .replaceSession(
                sessionID: replacementSession,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.startedEffects.contains(.resolveDescriptor(replacementSession))
        }
        XCTAssertEqual(
            coordinator.state.phase,
            .resolving(replacementSession)
        )
        XCTAssertTrue(probe.releasedReservations.isEmpty)
        XCTAssertFalse(probe.compoundGateStarted)

        probe.allowLegacyCancellationAcknowledgement()
        await yieldUntil { probe.releasedReservations == [reservation] }
        XCTAssertEqual(probe.releasedReservations, [reservation])
        XCTAssertFalse(probe.compoundGateStarted)
        coordinator.shutdown()
    }

    func testDuplicateOrBenignNetworkRevisionDoesNotCancelActiveLegacy() async throws {
        let initialSnapshot = NetworkSnapshot.wifi(
            expensive: false,
            constrained: false,
            pathVersion: 7
        )
        let probe = LegacyPolicyChangeProbe()
        let coordinator = PlaybackCoordinator(
            initialState: makeResolvingState(),
            effectOperation: probe.operation,
            networkSnapshot: initialSnapshot
        )
        let sessionID = try XCTUnwrap(coordinator.state.activeSessionID)
        coordinator.send(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: false)
            )
        )
        let gate = try XCTUnwrap(coordinator.state.pendingTransferGateAttempt)
        coordinator.send(
            .fullTransferGateAllowed(
                gate,
                reservationID: StorageReservationID(rawValue: UUID())
            )
        )
        await yieldUntil { probe.legacyBodyBytes == 1 }

        coordinator.send(.networkSnapshotChanged(initialSnapshot))
        coordinator.send(
            .networkSnapshotChanged(
                .wifi(expensive: false, constrained: false, pathVersion: 8)
            )
        )
        let checkpoint = probe.observationCheckpointCount + 1
        probe.requestObservationCheckpoint()
        await yieldUntil {
            probe.observationCheckpointCount >= checkpoint
        }

        XCTAssertFalse(probe.legacyCancellationObserved)
        XCTAssertFalse(probe.compoundGateStarted)
        XCTAssertNil(coordinator.state.pendingTransferGateAttempt)
        XCTAssertEqual(probe.startedLegacyTransfers, 1)
        coordinator.shutdown()
    }

    func testDescriptorQualificationFailureRetriesThenTerminatesWithoutLegacyBytes() async throws {
        let probe = DescriptorQualificationFailureProbe()
        let coordinator = PlaybackCoordinator(effectOperation: probe.operation)
        let sessionID = PlaybackSessionID.fresh()

        coordinator.send(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        await yieldUntil {
            probe.resolutionAttempts == 2
                && {
                    if case .failed = coordinator.state.phase { return true }
                    return false
                }()
        }

        guard case .failed(let failure) = coordinator.state.phase else {
            return XCTFail("Expected terminal recoverable resolution failure")
        }
        XCTAssertEqual(failure.category, .resolution)
        XCTAssertTrue(failure.isRecoverable)
        XCTAssertEqual(probe.legacyInvocations, 0)
        XCTAssertEqual(probe.legacyResponseBodyBytes, 0)

        let terminalState = coordinator.state
        coordinator.send(
            .descriptorResolutionFailed(
                sessionID: PlaybackSessionID.fresh(),
                category: .resolution
            )
        )
        XCTAssertEqual(coordinator.state, terminalState)
        coordinator.shutdown()
    }

    func testValidatedLegacyTokenFactoriesRequireCoordinatorOwnedLegacyIdentity() throws {
        let sessionID = PlaybackSessionID.fresh()
        let sourceAttempt = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .legacyDownloadRemux
        )
        let token = FailedActionToken(
            sessionID: sessionID,
            actionID: .fresh(),
            generationFingerprint: LocalGenerationFingerprint(digest: "generation"),
            failureCategory: .transport,
            intent: .initialPlayback
        )
        let gateAttempt = PlaybackTransferGateAttempt(
            id: .fresh(),
            request: FallbackRequest(
                sourceAttempt: sourceAttempt,
                targetSeconds: 0,
                intent: .playing,
                token: token
            ),
            networkClass: .wifiUnconstrained
        )

        let qualificationTokens = try XCTUnwrap(
            ActivePlaybackTokens.validatedLegacyGateAttempt(gateAttempt)
        )
        XCTAssertEqual(qualificationTokens.sessionID, sessionID)
        XCTAssertEqual(qualificationTokens.currentSourceAttempt, sourceAttempt)
        XCTAssertNil(qualificationTokens.latestSeekAttempt)

        let fallback = FallbackAttempt(
            sourceAttempt: sourceAttempt,
            targetSeconds: 0,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        let fallbackTokens = try XCTUnwrap(
            ActivePlaybackTokens.validatedLegacyFallback(fallback)
        )
        XCTAssertEqual(fallbackTokens.sessionID, sessionID)
        XCTAssertEqual(fallbackTokens.currentSourceAttempt, sourceAttempt)
        XCTAssertNil(fallbackTokens.latestSeekAttempt)

        let rangeAttempt = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .rangeStream
        )
        let rangeGate = PlaybackTransferGateAttempt(
            id: .fresh(),
            request: FallbackRequest(
                sourceAttempt: rangeAttempt,
                targetSeconds: 0,
                intent: .playing,
                token: token
            ),
            networkClass: .wifiUnconstrained
        )
        XCTAssertNil(ActivePlaybackTokens.validatedLegacyGateAttempt(rangeGate))
        XCTAssertNil(
            ActivePlaybackTokens.validatedLegacyFallback(
                FallbackAttempt(
                    sourceAttempt: rangeAttempt,
                    targetSeconds: 0,
                    intent: .playing,
                    reservationID: StorageReservationID(rawValue: UUID())
                )
            )
        )

        let mismatchedSessionGate = PlaybackTransferGateAttempt(
            id: .fresh(),
            request: FallbackRequest(
                sourceAttempt: sourceAttempt,
                targetSeconds: 0,
                intent: .playing,
                token: FailedActionToken(
                    sessionID: .fresh(),
                    actionID: .fresh(),
                    generationFingerprint: token.generationFingerprint,
                    failureCategory: token.failureCategory,
                    intent: token.intent
                )
            ),
            networkClass: .wifiUnconstrained
        )
        XCTAssertNil(
            ActivePlaybackTokens.validatedLegacyGateAttempt(mismatchedSessionGate)
        )
    }

    private func makeResolvingState(
        intent: DesiredPlaybackIntent = .playing,
        position: TimeInterval = 0
    ) -> PlaybackSessionState {
        var state = PlaybackSessionState.idle
        _ = state.reduce(
            .replaceSession(
                sessionID: .fresh(),
                desiredIntent: intent,
                initialPosition: position
            )
        )
        return state
    }

    private func makePlayingRangeState(
        intent: DesiredPlaybackIntent = .playing
    ) throws -> PlaybackSessionState {
        var state = makeResolvingState(intent: intent)
        let sessionID = try XCTUnwrap(state.activeSessionID)
        let effects = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: true)
            )
        )
        let attempt = try XCTUnwrap(effects.startedSourceAttempt)
        _ = state.reduce(.sourceBecamePlayable(attempt))
        return state
    }

    private func makePlayingLocalState(
        source: PlaybackSource
    ) -> PlaybackSessionState {
        precondition(source == .explicitDownload || source == .remuxCache)
        let attempt = SourceAttempt(
            sessionID: .fresh(),
            id: .fresh(),
            source: source
        )
        return PlaybackSessionState(
            phase: .playing(attempt),
            selectedSource: source,
            desiredPlaybackIntent: .playing,
            latestRequestedTarget: nil,
            lastConfirmedPosition: 0,
            sessionBudget: .initial,
            consumedConsentTokens: [],
            resourceGenerationFingerprint: .fixture
        )
    }

    private func makeLegacyRemuxState(
        fallback: FallbackAttempt
    ) -> PlaybackSessionState {
        PlaybackSessionState(
            phase: .legacyRemuxing(fallback),
            selectedSource: .legacyDownloadRemux,
            desiredPlaybackIntent: fallback.intent,
            latestRequestedTarget: nil,
            lastConfirmedPosition: 0,
            sessionBudget: .initial,
            consumedConsentTokens: [],
            resourceGenerationFingerprint: .fixture
        )
    }

    private var longRunningOperation: PlaybackCoordinator.EffectOperation {
        { _ in
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                return nil
            }
            return nil
        }
    }

    private func yieldUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic coordinator work")
    }
}

@MainActor
private final class FakeCoordinatorMonotonicClock: PlaybackMonotonicClock {
    private(set) var now: TimeInterval = 0

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        now += interval
    }
}

@MainActor
private final class YieldingPlaybackWatchdogScheduler: PlaybackWatchdogScheduling {
    func sleep(
        until deadline: TimeInterval,
        clock: any PlaybackMonotonicClock
    ) async throws {
        while clock.now < deadline {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
private final class CancellationAcknowledgingWatchdogScheduler:
    PlaybackWatchdogScheduling
{
    private(set) var startedSleeps = 0
    private(set) var cancelledSleeps = 0

    func sleep(
        until deadline: TimeInterval,
        clock: any PlaybackMonotonicClock
    ) async throws {
        startedSleeps += 1
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch {
            cancelledSleeps += 1
            throw error
        }
    }
}

@MainActor
private final class EffectCancellationProbe {
    private(set) var startedEffects: [PlaybackEffect] = []
    private(set) var cancelledEffects: [PlaybackEffect] = []

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            self?.startedEffects.append(effect)
            do {
                while true {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch {
                self?.cancelledEffects.append(effect)
                return nil
            }
        }
    }

    var startedLegacyTransfers: [FallbackAttempt] {
        startedEffects.compactMap { effect in
            guard case .startLegacyTransfer(let attempt) = effect else {
                return nil
            }
            return attempt
        }
    }
}

@MainActor
private final class CancelledGateReservationProbe {
    enum CallbackMode: Equatable {
        case allowedWhenEvaluationIsCancelled
        case acceptedWhenConsentIsCancelled
    }

    private(set) var startedEffects: [PlaybackEffect] = []
    private(set) var cancelledGateAttemptIDs: [PlaybackTransferGateAttemptID] = []
    private(set) var releasedReservations: [StorageReservationID] = []
    private(set) var startedLegacyTransfers: [FallbackAttempt] = []
    private let callbackMode: CallbackMode
    private var reservations: [PlaybackTransferGateAttemptID: StorageReservationID] = [:]

    init(callbackMode: CallbackMode) {
        self.callbackMode = callbackMode
    }

    func reservation(
        for attemptID: PlaybackTransferGateAttemptID
    ) -> StorageReservationID? {
        reservations[attemptID]
    }

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            guard let self else { return nil }
            startedEffects.append(effect)

            switch effect {
            case .evaluateFullResourceTransferGate(let attempt):
                let reservation = reservationForAttempt(attempt.id)
                do {
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } catch {
                    recordGateCancellation(attempt.id)
                    guard callbackMode == .allowedWhenEvaluationIsCancelled else {
                        return nil
                    }
                    return .fullTransferGateAllowed(
                        attempt,
                        reservationID: reservation
                    )
                }

            case .presentFullTransferConsent(let attempt):
                let reservation = reservationForAttempt(attempt.id)
                do {
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } catch {
                    recordGateCancellation(attempt.id)
                    guard callbackMode == .acceptedWhenConsentIsCancelled else {
                        return nil
                    }
                    return .transferConsentAccepted(
                        attempt,
                        reservationID: reservation
                    )
                }

            case .releaseStorageReservation(let reservationID):
                releasedReservations.append(reservationID)
                return nil

            case .startLegacyTransfer(let attempt):
                startedLegacyTransfers.append(attempt)
                return nil

            default:
                return nil
            }
        }
    }

    private func reservationForAttempt(
        _ attemptID: PlaybackTransferGateAttemptID
    ) -> StorageReservationID {
        if let existing = reservations[attemptID] {
            return existing
        }
        let reservation = StorageReservationID(rawValue: UUID())
        reservations[attemptID] = reservation
        return reservation
    }

    private func recordGateCancellation(
        _ attemptID: PlaybackTransferGateAttemptID
    ) {
        if !cancelledGateAttemptIDs.contains(attemptID) {
            cancelledGateAttemptIDs.append(attemptID)
        }
    }
}

@MainActor
private final class CancellationIgnoringResolverProbe {
    private(set) var resolverInvocationCount = 0
    private(set) var completedResolverInvocations: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            guard let self,
                case .resolveDescriptor(let sessionID) = effect
            else {
                return nil
            }
            resolverInvocationCount += 1
            let invocation = resolverInvocationCount
            await withCheckedContinuation { continuation in
                self.continuations[invocation] = continuation
            }
            completedResolverInvocations.insert(invocation)
            guard invocation == 1 else { return nil }
            return .descriptorResolved(
                sessionID: sessionID,
                sources: .fixture(rangeEligible: true)
            )
        }
    }

    func resumeResolver(invocation: Int) {
        continuations.removeValue(forKey: invocation)?.resume()
    }

    func resumeAllResolvers() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
private final class CancellationIgnoringRangeProbe {
    private(set) var initialRangeInvocationCount = 0
    private(set) var rangeRetryInvocationCount = 0
    private(set) var initialRangeCompleted = false
    private var initialRangeContinuation: CheckedContinuation<Void, Never>?
    private var rangeRetryContinuation: CheckedContinuation<Void, Never>?

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            guard let self else { return nil }
            switch effect {
            case .resolveDescriptor(let sessionID):
                return .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: true)
                )

            case .startSource(let attempt):
                initialRangeInvocationCount += 1
                await withCheckedContinuation { continuation in
                    self.initialRangeContinuation = continuation
                }
                initialRangeCompleted = true
                return .sourceBecamePlayable(attempt)

            case .retryRangeTransport:
                rangeRetryInvocationCount += 1
                await withCheckedContinuation { continuation in
                    self.rangeRetryContinuation = continuation
                }
                return nil

            default:
                return nil
            }
        }
    }

    func resumeInitialRange() {
        initialRangeContinuation?.resume()
        initialRangeContinuation = nil
    }

    func resumeRangeRetry() {
        rangeRetryContinuation?.resume()
        rangeRetryContinuation = nil
    }
}

@MainActor
private final class CancellationIgnoringSeekProbe {
    private(set) var initialSeekInvocationCount = 0
    private(set) var seekRetryInvocationCount = 0
    private(set) var initialSeekCompleted = false
    private var initialSeekContinuation: CheckedContinuation<Void, Never>?
    private var seekRetryContinuation: CheckedContinuation<Void, Never>?

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            guard let self else { return nil }
            switch effect {
            case .startSeek(let attempt):
                initialSeekInvocationCount += 1
                await withCheckedContinuation { continuation in
                    self.initialSeekContinuation = continuation
                }
                initialSeekCompleted = true
                return .seekPrepared(attempt)

            case .retrySeekUpstream:
                seekRetryInvocationCount += 1
                await withCheckedContinuation { continuation in
                    self.seekRetryContinuation = continuation
                }
                return nil

            default:
                return nil
            }
        }
    }

    func resumeInitialSeek() {
        initialSeekContinuation?.resume()
        initialSeekContinuation = nil
    }

    func resumeSeekRetry() {
        seekRetryContinuation?.resume()
        seekRetryContinuation = nil
    }
}

@MainActor
private final class LegacyCancellationBarrierProbe {
    private(set) var startedEffects: [PlaybackEffect] = []
    private(set) var legacyCancellationObserved = false
    private(set) var legacyCancellationAcknowledged = false
    private(set) var compoundGateStarted = false
    private(set) var compoundStartedAfterCancellationAcknowledgement = false
    private(set) var compoundOldReservationID: StorageReservationID?
    private(set) var compoundOldSourceAttemptID: SourceAttemptID?
    private(set) var compoundRequest: FallbackRequest?
    private var mayAcknowledgeLegacyCancellation = false

    func allowLegacyCancellationAcknowledgement() {
        mayAcknowledgeLegacyCancellation = true
    }

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            guard let self else { return nil }
            startedEffects.append(effect)
            if case .startLegacyTransfer = effect {
                do {
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } catch {
                    legacyCancellationObserved = true
                    while !mayAcknowledgeLegacyCancellation {
                        await Task.yield()
                    }
                    legacyCancellationAcknowledged = true
                    return nil
                }
            }
            if case .releaseReservationAndEvaluateFullResourceTransferGate(
                let oldReservationID,
                let attempt
            ) = effect {
                compoundGateStarted = true
                compoundStartedAfterCancellationAcknowledgement =
                    legacyCancellationAcknowledged
                compoundOldReservationID = oldReservationID
                compoundOldSourceAttemptID =
                    attempt.replacedLegacySourceAttemptID
                compoundRequest = attempt.request
            }
            do {
                while true {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch {
                return nil
            }
        }
    }
}

@MainActor
private final class LegacyPolicyChangeProbe {
    private(set) var startedEffects: [PlaybackEffect] = []
    private(set) var startedLegacyTransfers = 0
    private(set) var legacyBodyBytes: Int64 = 0
    private(set) var legacyCancellationObserved = false
    private(set) var legacyCancellationAcknowledged = false
    private(set) var compoundGateStarted = false
    private(set) var compoundStartedAfterCancellationAcknowledgement = false
    private(set) var compoundOldReservationID: StorageReservationID?
    private(set) var compoundOldSourceAttemptID: SourceAttemptID?
    private(set) var releasedReservations: [StorageReservationID] = []
    private(set) var observationCheckpointCount = 0
    private let autoAcknowledgeCancellation: Bool
    private var mayAcknowledgeCancellation = false
    private var observationCheckpointRequested = false

    init(autoAcknowledgeCancellation: Bool = false) {
        self.autoAcknowledgeCancellation = autoAcknowledgeCancellation
    }

    func allowLegacyCancellationAcknowledgement() {
        mayAcknowledgeCancellation = true
    }

    func requestObservationCheckpoint() {
        observationCheckpointRequested = true
    }

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            guard let self else { return nil }
            startedEffects.append(effect)
            switch effect {
            case .startLegacyTransfer:
                startedLegacyTransfers += 1
                legacyBodyBytes += 1
                do {
                    while true {
                        if observationCheckpointRequested {
                            observationCheckpointRequested = false
                            observationCheckpointCount += 1
                        }
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } catch {
                    legacyCancellationObserved = true
                    while !autoAcknowledgeCancellation
                        && !mayAcknowledgeCancellation
                    {
                        await Task.yield()
                    }
                    legacyCancellationAcknowledged = true
                    return nil
                }

            case .releaseReservationAndEvaluateFullResourceTransferGate(
                let oldReservationID,
                let attempt
            ):
                compoundGateStarted = true
                compoundStartedAfterCancellationAcknowledgement =
                    legacyCancellationAcknowledged
                compoundOldReservationID = oldReservationID
                compoundOldSourceAttemptID =
                    attempt.replacedLegacySourceAttemptID
                return nil

            case .releaseStorageReservation(let reservationID):
                releasedReservations.append(reservationID)
                return nil

            default:
                return nil
            }
        }
    }
}

@MainActor
private final class DescriptorQualificationFailureProbe {
    private(set) var resolutionAttempts = 0
    private(set) var legacyInvocations = 0
    private(set) var legacyResponseBodyBytes: Int64 = 0

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            guard let self else { return nil }
            switch effect {
            case .resolveDescriptor(let sessionID):
                resolutionAttempts += 1
                return .descriptorResolutionFailed(
                    sessionID: sessionID,
                    category: .resolution
                )
            case .startLegacyTransfer:
                legacyInvocations += 1
                legacyResponseBodyBytes += 1
                return nil
            default:
                return nil
            }
        }
    }
}

@MainActor
private final class ColdRangeLifecycleProbe {
    private(set) var startedEffects: [PlaybackEffect] = []
    private(set) var cancelledEffects: [PlaybackEffect] = []

    var operation: PlaybackCoordinator.EffectOperation {
        { [weak self] effect in
            self?.startedEffects.append(effect)
            switch effect {
            case .resolveDescriptor(let sessionID):
                return .descriptorResolved(
                    sessionID: sessionID,
                    sources: .fixture(rangeEligible: true)
                )
            case .startSource(let attempt):
                return .sourceBecamePlayable(attempt)
            case .startSeek(let attempt):
                await Task.yield()
                guard !Task.isCancelled else { return nil }
                return .seekPrepared(attempt)
            case .startSeekVerification(let attempt):
                await Task.yield()
                guard !Task.isCancelled else { return nil }
                return .seekVerified(
                    attempt,
                    confirmedPosition: attempt.targetSeconds
                )
            default:
                do {
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } catch {
                    self?.cancelledEffects.append(effect)
                    return nil
                }
            }
        }
    }
}

private extension PlaybackSourceAvailability {
    static func fixture(
        hasExplicitDownload: Bool = false,
        hasValidLocalRemux: Bool = false,
        rangeEligible: Bool = false
    ) -> Self {
        Self(
            hasExplicitDownload: hasExplicitDownload,
            hasValidLocalRemux: hasValidLocalRemux,
            rangeEligible: rangeEligible,
            generationFingerprint: .fixture
        )
    }
}

private extension LocalGenerationFingerprint {
    static let fixture = Self(digest: "coordinator-generation")
}

private extension FailedActionToken {
    static func fixture(
        sessionID: PlaybackSessionID,
        category: PlaybackFailureCategory = .transport
    ) -> Self {
        Self(
            sessionID: sessionID,
            actionID: .fresh(),
            generationFingerprint: .fixture,
            failureCategory: category,
            intent: .sourceFallback
        )
    }
}

private extension FallbackAttempt {
    static func fixture(
        targetSeconds: TimeInterval,
        intent: DesiredPlaybackIntent
    ) -> Self {
        Self(
            sourceAttempt: SourceAttempt(
                sessionID: .fresh(),
                id: .fresh(),
                source: .legacyDownloadRemux
            ),
            targetSeconds: targetSeconds,
            intent: intent,
            reservationID: StorageReservationID(rawValue: UUID())
        )
    }
}

private extension PlaybackSessionState {
    var legacyDownloadingAttempt: FallbackAttempt? {
        guard case .legacyDownloading(let attempt) = phase else { return nil }
        return attempt
    }
}

private extension Array where Element == PlaybackEffect {
    var containsTransferGateCancellation: Bool {
        contains { effect in
            if case .cancelTransferGate = effect { return true }
            return false
        }
    }

    var containsTransferGateEvaluation: Bool {
        contains { effect in
            if case .evaluateFullResourceTransferGate = effect { return true }
            if case .releaseReservationAndEvaluateFullResourceTransferGate = effect {
                return true
            }
            return false
        }
    }

    var containsConsentPresentation: Bool {
        contains { effect in
            if case .presentFullTransferConsent = effect { return true }
            return false
        }
    }

    var startedSourceAttempt: SourceAttempt? {
        for effect in self {
            if case .startSource(let attempt) = effect {
                return attempt
            }
        }
        return nil
    }

    var transferGateRequest: FallbackRequest? {
        transferGateAttempt?.request
    }

    var transferGateAttempt: PlaybackTransferGateAttempt? {
        for effect in self {
            if case .evaluateFullResourceTransferGate(let attempt) = effect {
                return attempt
            }
        }
        return nil
    }

    var startedLegacyAttempt: FallbackAttempt? {
        for effect in self {
            if case .startLegacyTransfer(let attempt) = effect {
                return attempt
            }
        }
        return nil
    }

    var startedSeekAttempt: SeekAttempt? {
        for effect in self {
            if case .startSeek(let attempt) = effect {
                return attempt
            }
        }
        return nil
    }

    var containsLegacyTransferStart: Bool {
        startedLegacyAttempt != nil
    }
}
