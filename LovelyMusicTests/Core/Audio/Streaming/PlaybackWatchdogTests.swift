import Foundation
import XCTest

@testable import LovelyMusic

@MainActor
final class PlaybackWatchdogTests: XCTestCase {
    func testTerminalMappingCoversEveryNormativePhaseWithoutDefaultCounter() {
        assertMapping(
            .resolver,
            network: .wifiUnconstrained,
            counter: .resolverRetry,
            category: .resolution,
            timing: .onExpiry
        )
        assertMapping(
            .initialRangePrepare,
            network: .wifiUnconstrained,
            counter: .rangeTransportRetry,
            category: .transport,
            timing: .onExpiry
        )
        assertMapping(
            .activeRangePlayback,
            network: .cellular,
            counter: .rangeTransportRetry,
            category: .transport,
            timing: .onExpiry
        )
        assertMapping(
            .seekUpstream,
            network: .constrained,
            counter: .rangeTransportRetry,
            category: .transport,
            timing: .onExpiry
        )
        assertMapping(
            .seekVerification,
            network: .wifiUnconstrained,
            counter: .rangeToLegacyDowngrade,
            category: .seekVerification,
            timing: .whenLegacyCommits
        )
        assertMapping(
            .legacyDownload,
            network: .wifiUnconstrained,
            counter: .legacyWiFiTransportRetry,
            category: .transport,
            timing: .onExpiry
        )
        for network in [PlaybackNetworkClass.cellular, .constrained, .offline] {
            assertMapping(
                .legacyDownload,
                network: network,
                counter: .legacyMeteredTransportRetry,
                category: .transport,
                timing: .onExpiry
            )
        }
        assertMapping(
            .legacyRemux(trackDurationSeconds: 240),
            network: .wifiUnconstrained,
            counter: .legacyRemuxRetry,
            category: .remux,
            timing: .onExpiry
        )
    }

    func testDeadlinesCoverEveryNormativePhaseAndOfflineEdges() {
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(for: .resolver, networkClass: .wifiUnconstrained),
            .init(noProgress: nil, absolute: 30)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(
                for: .initialRangePrepare,
                networkClass: .wifiUnconstrained
            ),
            .init(noProgress: 10, absolute: 30)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(for: .seekUpstream, networkClass: .cellular),
            .init(noProgress: 15, absolute: 30)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(
                for: .activeRangePlayback,
                networkClass: .constrained
            ),
            .init(noProgress: 15, absolute: nil)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(
                for: .seekVerification,
                networkClass: .wifiUnconstrained
            ),
            .init(noProgress: nil, absolute: 5)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(
                for: .seekVerification,
                networkClass: .cellular
            ),
            .init(noProgress: nil, absolute: 8)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(
                for: .legacyDownload,
                networkClass: .wifiUnconstrained
            ),
            .init(noProgress: 15, absolute: 300)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(
                for: .legacyDownload,
                networkClass: .constrained
            ),
            .init(noProgress: 15, absolute: 600)
        )
        XCTAssertEqual(
            PlaybackWatchdog.deadlines(
                for: .legacyRemux(trackDurationSeconds: 240),
                networkClass: .wifiUnconstrained
            ),
            .init(noProgress: 15, absolute: 120)
        )

        for kind in [
            PlaybackWatchdogKind.resolver,
            .initialRangePrepare,
            .activeRangePlayback,
            .seekUpstream,
            .seekVerification,
            .legacyDownload,
        ] {
            let deadlines = PlaybackWatchdog.deadlines(for: kind, networkClass: .offline)
            XCTAssertTrue(deadlines.noProgress == nil || deadlines.noProgress == 0)
            XCTAssertTrue(deadlines.absolute == nil || deadlines.absolute == 0)
        }
    }

    func testResolverExpiresAtAbsoluteThirtySecondsAndConsumesOneRetry() {
        let clock = FakeMonotonicClock()
        let sessionID = PlaybackSessionID.fresh()
        let token = PlaybackWatchdogToken.fresh(sessionID: sessionID)
        let watchdog = PlaybackWatchdog(
            kind: .resolver,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        var state = PlaybackSessionState.resolvingFixture(sessionID: sessionID)
        _ = state.reduce(.watchdogStarted(kind: .resolver, token: token))

        clock.advance(by: 29.999)
        XCTAssertNil(watchdog.receive(.poll, token: token))
        clock.advance(by: 0.001)
        let expiry = try! XCTUnwrap(watchdog.receive(.poll, token: token).expiry)

        XCTAssertEqual(expiry.reason, .absoluteDeadline)
        XCTAssertEqual(state.reduce(.watchdogExpired(expiry)), [.resolveDescriptor(sessionID)])
        XCTAssertEqual(state.sessionBudget.resolverRetries, 0)
        XCTAssertNil(watchdog.receive(.completed, token: token))
        XCTAssertEqual(state.sessionBudget.resolverRetries, 0)
    }

    func testInitialRangeTrickleCannotExtendAbsoluteDeadlineOrDoubleConsume() throws {
        let clock = FakeMonotonicClock()
        var state = try PlaybackSessionState.playingRangeFixture(phase: .preparing)
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .initialRangePrepare,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .initialRangePrepare, token: token))

        for byteCount in 1...3 {
            clock.advance(by: 9.9)
            XCTAssertNil(
                watchdog.receive(
                    .validatedResponseBodyBytes(totalUniqueBytes: Int64(byteCount)),
                    token: token
                )
            )
            XCTAssertNil(watchdog.receive(.poll, token: token))
        }
        clock.advance(by: 0.3)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)

        XCTAssertEqual(clock.now, 30, accuracy: 0.0001)
        XCTAssertEqual(expiry.reason, .absoluteDeadline)
        XCTAssertEqual(
            state.reduce(.watchdogExpired(expiry)),
            [.retryRangeTransport(attempt)]
        )
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
        XCTAssertNil(watchdog.receive(.upstreamError, token: token))
        XCTAssertNil(watchdog.receive(.completed, token: token))
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
    }

    func testSeekUpstreamTrickleCannotExtendAbsoluteDeadlineOrDoubleConsume() throws {
        let clock = FakeMonotonicClock()
        var state = try PlaybackSessionState.playingRangeFixture(phase: .playing)
        let seek = try XCTUnwrap(
            state.reduce(.requestSeek(targetSeconds: 77)).startedSeekAttempt
        )
        let token = PlaybackWatchdogToken.fresh(seekAttempt: seek)
        let watchdog = PlaybackWatchdog(
            kind: .seekUpstream,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .seekUpstream, token: token))

        for byteCount in 1...3 {
            clock.advance(by: 9.9)
            XCTAssertNil(
                watchdog.receive(
                    .validatedResponseBodyBytes(totalUniqueBytes: Int64(byteCount)),
                    token: token
                )
            )
        }
        clock.advance(by: 0.3)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)

        XCTAssertEqual(expiry.reason, .absoluteDeadline)
        XCTAssertEqual(
            state.reduce(.watchdogExpired(expiry)),
            [.retrySeekUpstream(seek)]
        )
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
        XCTAssertNil(watchdog.receive(.poll, token: token))
        XCTAssertNil(watchdog.receive(.upstreamError, token: token))
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
    }

    func testActiveRangeNoProgressHandlesExpiryBeforeLateByteErrorAndCompletion() throws {
        let clock = FakeMonotonicClock()
        var state = try PlaybackSessionState.playingRangeFixture(phase: .playing)
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .activeRangePlayback,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .activeRangePlayback, token: token))

        clock.advance(by: 9.9)
        XCTAssertNil(
            watchdog.receive(
                .validatedResponseBodyBytes(totalUniqueBytes: 1),
                token: token
            )
        )
        clock.advance(by: 10.001)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)
        let effects = state.reduce(.watchdogExpired(expiry))

        XCTAssertEqual(expiry.reason, .noProgressDeadline)
        XCTAssertEqual(effects, [.retryRangeTransport(attempt)])
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
        XCTAssertNil(
            watchdog.receive(
                .validatedResponseBodyBytes(totalUniqueBytes: 2),
                token: token
            )
        )
        XCTAssertNil(watchdog.receive(.upstreamError, token: token))
        XCTAssertNil(watchdog.receive(.completed, token: token))
        XCTAssertTrue(watchdog.isHandled)
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
    }

    func testOnlyValidatedStrictlyNewResponseBodyBytesResetNetworkNoProgress() {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .rangeStream)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .activeRangePlayback,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        clock.advance(by: 5)
        XCTAssertNil(watchdog.receive(.responseHeaders, token: token))
        XCTAssertEqual(watchdog.lastProgressInstant, 0)
        XCTAssertNil(
            watchdog.receive(
                .unvalidatedResponseBodyBytes(totalBytes: 100),
                token: token
            )
        )
        XCTAssertEqual(watchdog.lastProgressInstant, 0)
        XCTAssertNil(
            watchdog.receive(
                .validatedResponseBodyBytes(totalUniqueBytes: 10),
                token: token
            )
        )
        XCTAssertEqual(watchdog.lastProgressInstant, 5)

        clock.advance(by: 5)
        XCTAssertNil(
            watchdog.receive(
                .validatedResponseBodyBytes(totalUniqueBytes: 10),
                token: token
            )
        )
        XCTAssertEqual(watchdog.lastProgressInstant, 5)
        clock.advance(by: 5)
        XCTAssertEqual(
            watchdog.receive(.poll, token: token).expiry?.reason,
            .noProgressDeadline
        )
    }

    func testLateValidatedByteExpiresBeforeItCanResetNoProgressDeadline() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .rangeStream)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .activeRangePlayback,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        clock.advance(by: 10.001)
        let outcome = watchdog.receive(
            .validatedResponseBodyBytes(totalUniqueBytes: 1),
            token: token
        )
        let expiry = try XCTUnwrap(outcome.expiry)

        XCTAssertEqual(expiry.reason, .noProgressDeadline)
        XCTAssertEqual(watchdog.lastProgressInstant, 0)
        XCTAssertTrue(watchdog.isHandled)
    }

    func testLateCompletionExpiresBeforeItCanBeatAbsoluteDeadline() throws {
        let clock = FakeMonotonicClock()
        let sessionID = PlaybackSessionID.fresh()
        let token = PlaybackWatchdogToken.fresh(sessionID: sessionID)
        let watchdog = PlaybackWatchdog(
            kind: .resolver,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        clock.advance(by: 31)
        let outcome = watchdog.receive(.completed, token: token)
        let expiry = try XCTUnwrap(outcome.expiry)

        XCTAssertEqual(expiry.reason, .absoluteDeadline)
        XCTAssertNotEqual(outcome, .completed(token))
        XCTAssertTrue(watchdog.isHandled)
    }

    func testLegacyDownloadUsesSnapshotCounterAndBothDeadlines() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let fallback = FallbackAttempt(
            sourceAttempt: attempt,
            targetSeconds: 0,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        var state = PlaybackSessionState.legacyFixture(fallback: fallback)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyDownload,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .legacyDownload, token: token))

        clock.advance(by: 14.9)
        XCTAssertNil(
            watchdog.receive(
                .validatedResponseBodyBytes(totalUniqueBytes: 1),
                token: token
            )
        )
        clock.advance(by: 15.001)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)

        XCTAssertEqual(expiry.mapping.counter, .legacyWiFiTransportRetry)
        let effects = state.reduce(.watchdogExpired(expiry))
        let releaseAndGate = try XCTUnwrap(effects.releaseAndGate)
        XCTAssertEqual(releaseAndGate.oldReservationID, fallback.reservationID)
        XCTAssertEqual(releaseAndGate.request.sourceAttempt, fallback.sourceAttempt)
        XCTAssertEqual(releaseAndGate.request.token.intent, .transportRetry)
        XCTAssertEqual(
            state.phase,
            .awaitingTransferConsent(releaseAndGate.request)
        )
        XCTAssertFalse(effects.containsLegacyTransferStart)
        XCTAssertEqual(state.sessionBudget.legacyWiFiTransportRetries, 0)
    }

    func testMeteredLegacyDownloadMapsToNonMintedMeteredCounter() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let fallback = FallbackAttempt(
            sourceAttempt: attempt,
            targetSeconds: 0,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        var state = PlaybackSessionState.legacyFixture(fallback: fallback)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyDownload,
            networkClass: .cellular,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .legacyDownload, token: token))

        clock.advance(by: 15)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)
        let effects = state.reduce(.watchdogExpired(expiry))

        XCTAssertEqual(expiry.mapping.counter, .legacyMeteredTransportRetry)
        XCTAssertEqual(
            effects,
            [.releaseStorageReservation(fallback.reservationID)]
        )
        XCTAssertEqual(state.sessionBudget.legacyMeteredTransportRetries, 0)
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
    }

    func testLegacyRetryGateFailsSafelyWhenItReturnsReleasedReservation() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let fallback = FallbackAttempt(
            sourceAttempt: attempt,
            targetSeconds: 22,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        var state = PlaybackSessionState.legacyFixture(fallback: fallback)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyDownload,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .legacyDownload, token: token))
        clock.advance(by: 15)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)
        let retryEffects = state.reduce(.watchdogExpired(expiry))
        let retryGate = try XCTUnwrap(retryEffects.releaseAndGate?.attempt)

        let invalidGateEffects = state.reduce(
            .fullTransferGateAllowed(
                retryGate,
                reservationID: fallback.reservationID
            )
        )

        XCTAssertEqual(
            invalidGateEffects,
            [.cancelTransferGate(retryGate.id)]
        )
        XCTAssertFalse(invalidGateEffects.containsLegacyTransferStart)
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: .storage,
                    isRecoverable: true,
                    lastConfirmedPosition: 0
                )
            )
        )
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
        XCTAssertTrue(
            state.reduce(
                .fullTransferGateAllowed(
                    retryGate,
                    reservationID: fallback.reservationID
                )
            ).isEmpty
        )
    }

    func testNetworkRegatePreservesReleasedReservationExclusion() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let fallback = FallbackAttempt(
            sourceAttempt: attempt,
            targetSeconds: 44,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        var state = PlaybackSessionState.legacyFixture(fallback: fallback)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyDownload,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .legacyDownload, token: token))
        clock.advance(by: 15)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)
        let retryEffects = state.reduce(.watchdogExpired(expiry))
        let wifiGate = try XCTUnwrap(retryEffects.releaseAndGate?.attempt)

        let networkEffects = state.reduce(.networkClassChanged(.cellular))
        let cellularGate = try XCTUnwrap(state.pendingTransferGateAttempt)
        XCTAssertTrue(networkEffects.containsTransferGateCancellation)
        XCTAssertTrue(networkEffects.containsTransferGateEvaluation)
        XCTAssertEqual(cellularGate.request.token, wifiGate.request.token)
        XCTAssertNotEqual(cellularGate.id, wifiGate.id)

        let invalidGateEffects = state.reduce(
            .fullTransferGateAllowed(
                cellularGate,
                reservationID: fallback.reservationID
            )
        )
        XCTAssertEqual(
            invalidGateEffects,
            [.cancelTransferGate(cellularGate.id)]
        )
        XCTAssertFalse(invalidGateEffects.containsLegacyTransferStart)
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: .storage,
                    isRecoverable: true,
                    lastConfirmedPosition: 0
                )
            )
        )
    }

    func testLegacyAbsoluteDeadlineWinsDespiteValidatedTrickle() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyDownload,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )

        for second in stride(from: 14.9, through: 298, by: 14.9) {
            clock.set(second)
            XCTAssertNil(
                watchdog.receive(
                    .validatedResponseBodyBytes(totalUniqueBytes: Int64(second * 10)),
                    token: token
                )
            )
        }
        clock.set(300)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)

        XCTAssertEqual(expiry.reason, .absoluteDeadline)
        XCTAssertEqual(expiry.mapping.counter, .legacyWiFiTransportRetry)
    }

    func testRemuxProgressUsesOutputBytesAndStillHonorsAbsoluteDeadline() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyRemux(trackDurationSeconds: 240),
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        clock.advance(by: 10)
        XCTAssertNil(
            watchdog.receive(
                .validatedResponseBodyBytes(totalUniqueBytes: 1),
                token: token
            )
        )
        XCTAssertEqual(watchdog.lastProgressInstant, 0)
        XCTAssertNil(watchdog.receive(.remuxOutputBytes(totalBytes: 1), token: token))
        XCTAssertEqual(watchdog.lastProgressInstant, 10)
        var outputBytes: Int64 = 2
        for instant in stride(from: 24.9, through: 114.3, by: 14.9) {
            clock.set(instant)
            XCTAssertNil(
                watchdog.receive(
                    .remuxOutputBytes(totalBytes: outputBytes),
                    token: token
                )
            )
            outputBytes += 1
        }
        clock.set(120)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)

        XCTAssertEqual(expiry.reason, .absoluteDeadline)
        XCTAssertEqual(expiry.mapping.counter, .legacyRemuxRetry)
    }

    func testRemuxNoProgressExpiresAndConsumesOnlyRemuxRetry() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let fallback = FallbackAttempt(
            sourceAttempt: attempt,
            targetSeconds: 0,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        var state = PlaybackSessionState.remuxFixture(fallback: fallback)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyRemux(trackDurationSeconds: 240),
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(
            .watchdogStarted(
                kind: .legacyRemux(trackDurationSeconds: 240),
                token: token
            )
        )

        clock.advance(by: 15)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)

        XCTAssertEqual(
            state.reduce(.watchdogExpired(expiry)),
            [.retryLegacyRemux(fallback, trackDurationSeconds: 240)]
        )
        XCTAssertEqual(state.sessionBudget.legacyRemuxRetries, 0)
        XCTAssertEqual(state.sessionBudget.legacyWiFiTransportRetries, 1)
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 2)
    }

    func testExhaustedRemuxFailureReleasesReservationExactlyOnce() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let fallback = FallbackAttempt(
            sourceAttempt: attempt,
            targetSeconds: 31,
            intent: .paused,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        var state = PlaybackSessionState.remuxFixture(fallback: fallback)
        XCTAssertTrue(state.sessionBudget.consume(.legacyRemuxRetry))
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyRemux(trackDurationSeconds: 240),
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(
            .watchdogStarted(
                kind: .legacyRemux(trackDurationSeconds: 240),
                token: token
            )
        )

        clock.advance(by: 15)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)
        let effects = state.reduce(.watchdogExpired(expiry))

        XCTAssertEqual(
            effects,
            [.releaseStorageReservation(fallback.reservationID)]
        )
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: .remux,
                    isRecoverable: true,
                    lastConfirmedPosition: 0
                )
            )
        )
        XCTAssertEqual(state.sessionBudget.legacyRemuxRetries, 0)
        XCTAssertTrue(state.reduce(.watchdogExpired(expiry)).isEmpty)
        XCTAssertEqual(state.sessionBudget.legacyRemuxRetries, 0)
    }

    func testInvalidRemuxDurationNormalizesIdentityAndExpiresExactlyOnce() throws {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .legacyDownloadRemux)
        let fallback = FallbackAttempt(
            sourceAttempt: attempt,
            targetSeconds: 18,
            intent: .playing,
            reservationID: StorageReservationID(rawValue: UUID())
        )
        var state = PlaybackSessionState.remuxFixture(fallback: fallback)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .legacyRemux(trackDurationSeconds: .nan),
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        guard case .legacyRemux(let normalizedDuration) = watchdog.kind else {
            return XCTFail("Expected normalized remux watchdog")
        }
        XCTAssertEqual(normalizedDuration, 0)
        _ = state.reduce(.watchdogStarted(kind: watchdog.kind, token: token))

        clock.set(14.9)
        XCTAssertNil(
            watchdog.receive(.remuxOutputBytes(totalBytes: 1), token: token)
        )
        clock.set(29.8)
        XCTAssertNil(
            watchdog.receive(.remuxOutputBytes(totalBytes: 2), token: token)
        )
        clock.set(30)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)
        let effects = state.reduce(.watchdogExpired(expiry))
        guard case .retryLegacyRemux(
            let retriedFallback,
            let retriedDuration
        ) = effects.first else {
            return XCTFail("Expected one normalized remux retry")
        }

        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(retriedFallback, fallback)
        XCTAssertEqual(retriedDuration, 0)
        XCTAssertEqual(state.sessionBudget.legacyRemuxRetries, 0)
        XCTAssertTrue(state.reduce(.watchdogExpired(expiry)).isEmpty)
        XCTAssertEqual(state.sessionBudget.legacyRemuxRetries, 0)
    }

    func testSeekVerificationDeadlineIsFailureWithoutPreconsumingDowngrade() throws {
        let clock = FakeMonotonicClock()
        var state = try PlaybackSessionState.playingRangeFixture(phase: .playing)
        let seek = try XCTUnwrap(
            state.reduce(.requestSeek(targetSeconds: 55)).startedSeekAttempt
        )
        _ = state.reduce(.seekPrepared(seek))
        let token = PlaybackWatchdogToken.fresh(seekAttempt: seek)
        let watchdog = PlaybackWatchdog(
            kind: .seekVerification,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )
        _ = state.reduce(.watchdogStarted(kind: .seekVerification, token: token))

        clock.advance(by: 5)
        let expiry = try XCTUnwrap(watchdog.receive(.poll, token: token).expiry)
        let effects = state.reduce(.watchdogExpired(expiry))
        let request = try XCTUnwrap(effects.transferGateRequest)

        XCTAssertEqual(expiry.mapping.failureCategory, .seekVerification)
        XCTAssertEqual(expiry.mapping.counter, .rangeToLegacyDowngrade)
        XCTAssertEqual(expiry.mapping.consumptionTiming, .whenLegacyCommits)
        XCTAssertEqual(request.token.failureCategory, .seekVerification)
        XCTAssertEqual(state.sessionBudget.rangeToLegacyDowngrades, 1)
        XCTAssertEqual(state.selectedSource, .rangeStream)
    }

    func testStaleTokenCannotResetCompleteOrExpireWatchdog() {
        let clock = FakeMonotonicClock()
        let activeAttempt = SourceAttempt.fixture(source: .rangeStream)
        let staleAttempt = SourceAttempt(
            sessionID: activeAttempt.sessionID,
            id: .fresh(),
            source: .rangeStream
        )
        let activeToken = PlaybackWatchdogToken.fresh(sourceAttempt: activeAttempt)
        let staleToken = PlaybackWatchdogToken.fresh(sourceAttempt: staleAttempt)
        let watchdog = PlaybackWatchdog(
            kind: .activeRangePlayback,
            networkClass: .wifiUnconstrained,
            token: activeToken,
            clock: clock
        )

        clock.advance(by: 9)
        XCTAssertNil(
            watchdog.receive(
                .validatedResponseBodyBytes(totalUniqueBytes: 99),
                token: staleToken
            )
        )
        XCTAssertEqual(watchdog.lastProgressInstant, 0)
        XCTAssertNil(watchdog.receive(.completed, token: staleToken))
        XCTAssertFalse(watchdog.isHandled)
        clock.advance(by: 1)
        XCTAssertEqual(
            watchdog.receive(.poll, token: activeToken).expiry?.reason,
            .noProgressDeadline
        )
    }

    func testCompletionWinsAndRejectsLateExpiryOrError() {
        let clock = FakeMonotonicClock()
        let attempt = SourceAttempt.fixture(source: .rangeStream)
        let token = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let watchdog = PlaybackWatchdog(
            kind: .activeRangePlayback,
            networkClass: .wifiUnconstrained,
            token: token,
            clock: clock
        )

        XCTAssertEqual(watchdog.receive(.completed, token: token), .completed(token))
        clock.advance(by: 20)
        XCTAssertNil(watchdog.receive(.poll, token: token))
        XCTAssertNil(watchdog.receive(.upstreamError, token: token))
        XCTAssertTrue(watchdog.isHandled)
    }

    func testExactExpiryAndOldWatchdogAfterRetryCannotConsumeBudgetTwice() throws {
        let clock = FakeMonotonicClock()
        var state = try PlaybackSessionState.playingRangeFixture(phase: .playing)
        let attempt = try XCTUnwrap(state.activeSourceAttempt)
        let oldToken = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        let oldWatchdog = PlaybackWatchdog(
            kind: .activeRangePlayback,
            networkClass: .wifiUnconstrained,
            token: oldToken,
            clock: clock
        )
        _ = state.reduce(
            .watchdogStarted(kind: .activeRangePlayback, token: oldToken)
        )
        clock.advance(by: 10)
        let oldExpiry = try XCTUnwrap(
            oldWatchdog.receive(.poll, token: oldToken).expiry
        )

        XCTAssertEqual(
            state.reduce(.watchdogExpired(oldExpiry)),
            [.retryRangeTransport(attempt)]
        )
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
        XCTAssertTrue(state.reduce(.watchdogExpired(oldExpiry)).isEmpty)
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)

        let replacementToken = PlaybackWatchdogToken.fresh(sourceAttempt: attempt)
        _ = state.reduce(
            .watchdogStarted(
                kind: .activeRangePlayback,
                token: replacementToken
            )
        )
        XCTAssertTrue(state.reduce(.watchdogExpired(oldExpiry)).isEmpty)
        XCTAssertEqual(state.sessionBudget.rangeTransportRetries, 1)
    }

    private func assertMapping(
        _ kind: PlaybackWatchdogKind,
        network: PlaybackNetworkClass,
        counter: FailureCounter,
        category: PlaybackFailureCategory,
        timing: PlaybackWatchdogCounterConsumptionTiming,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mapping = PlaybackWatchdog.terminalMapping(for: kind, networkClass: network)
        XCTAssertEqual(mapping.counter, counter, file: file, line: line)
        XCTAssertEqual(mapping.failureCategory, category, file: file, line: line)
        XCTAssertEqual(mapping.consumptionTiming, timing, file: file, line: line)
    }
}

@MainActor
private final class FakeMonotonicClock: PlaybackMonotonicClock {
    private(set) var now: TimeInterval = 0

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        now += interval
    }

    func set(_ instant: TimeInterval) {
        precondition(instant >= now)
        now = instant
    }
}

private extension SourceAttempt {
    static func fixture(source: PlaybackSource) -> Self {
        Self(sessionID: .fresh(), id: .fresh(), source: source)
    }
}

private extension LocalGenerationFingerprint {
    static let watchdogFixture = Self(digest: "watchdog-generation")
}

private extension PlaybackSessionState {
    static func resolvingFixture(sessionID: PlaybackSessionID) -> Self {
        var state = Self.idle
        _ = state.reduce(
            .replaceSession(
                sessionID: sessionID,
                desiredIntent: .playing,
                initialPosition: 0
            )
        )
        return state
    }

    static func playingRangeFixture(
        phase requestedPhase: FixtureRangePhase
    ) throws -> Self {
        var state = resolvingFixture(sessionID: .fresh())
        let sessionID = try XCTUnwrap(state.activeSessionID)
        let effects = state.reduce(
            .descriptorResolved(
                sessionID: sessionID,
                sources: PlaybackSourceAvailability(
                    hasExplicitDownload: false,
                    hasValidLocalRemux: false,
                    rangeEligible: true,
                    generationFingerprint: .watchdogFixture
                )
            )
        )
        let attempt = try XCTUnwrap(effects.startedSourceAttempt)
        if requestedPhase == .playing {
            _ = state.reduce(.sourceBecamePlayable(attempt))
        }
        return state
    }

    static func legacyFixture(fallback: FallbackAttempt) -> Self {
        Self(
            phase: .legacyDownloading(fallback),
            selectedSource: .legacyDownloadRemux,
            desiredPlaybackIntent: fallback.intent,
            latestRequestedTarget: fallback.targetSeconds,
            lastConfirmedPosition: 0,
            sessionBudget: .initial,
            consumedConsentTokens: [],
            resourceGenerationFingerprint: .watchdogFixture
        )
    }

    static func remuxFixture(fallback: FallbackAttempt) -> Self {
        Self(
            phase: .legacyRemuxing(fallback),
            selectedSource: .legacyDownloadRemux,
            desiredPlaybackIntent: fallback.intent,
            latestRequestedTarget: fallback.targetSeconds,
            lastConfirmedPosition: 0,
            sessionBudget: .initial,
            consumedConsentTokens: [],
            resourceGenerationFingerprint: .watchdogFixture
        )
    }
}

private enum FixtureRangePhase {
    case preparing
    case playing
}

private extension Optional where Wrapped == PlaybackWatchdogOutcome {
    var expiry: PlaybackWatchdogExpiry? {
        guard case .expired(let expiry) = self else { return nil }
        return expiry
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

    var releaseAndGate: (
        oldReservationID: StorageReservationID,
        attempt: PlaybackTransferGateAttempt,
        request: FallbackRequest
    )? {
        for effect in self {
            if case .releaseReservationAndEvaluateFullResourceTransferGate(
                let oldReservationID,
                let attempt
            ) = effect {
                return (oldReservationID, attempt, attempt.request)
            }
        }
        return nil
    }

    var containsLegacyTransferStart: Bool {
        for effect in self {
            if case .startLegacyTransfer = effect { return true }
        }
        return false
    }

    var startedSourceAttempt: SourceAttempt? {
        for effect in self {
            if case .startSource(let attempt) = effect {
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

    var transferGateRequest: FallbackRequest? {
        transferGateAttempt?.request
    }

    var transferGateAttempt: PlaybackTransferGateAttempt? {
        for effect in self {
            if case .evaluateFullResourceTransferGate(let attempt) = effect {
                return attempt
            }
            if case .releaseReservationAndEvaluateFullResourceTransferGate(
                _,
                let attempt
            ) = effect {
                return attempt
            }
        }
        return nil
    }
}
