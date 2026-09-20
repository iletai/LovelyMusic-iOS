import Foundation
import XCTest

@testable import LovelyMusic

final class PlaybackSessionFailureBudgetTests: XCTestCase {
    func testEverySessionCounterIsConsumedExactlyWithoutReset() {
        var budget = PlaybackSessionFailureBudget.initial

        XCTAssertTrue(budget.consume(.resolverRetry))
        XCTAssertFalse(budget.consume(.resolverRetry))
        XCTAssertEqual(budget.resolverRetries, 0)

        XCTAssertTrue(budget.consume(.signedURLRefresh))
        XCTAssertFalse(budget.consume(.signedURLRefresh))
        XCTAssertEqual(budget.signedURLRefreshes, 0)

        XCTAssertTrue(budget.consume(.rangeTransportRetry))
        XCTAssertTrue(budget.consume(.rangeTransportRetry))
        XCTAssertFalse(budget.consume(.rangeTransportRetry))
        XCTAssertEqual(budget.rangeTransportRetries, 0)

        XCTAssertTrue(budget.consume(.rangeToLegacyDowngrade))
        XCTAssertFalse(budget.consume(.rangeToLegacyDowngrade))
        XCTAssertEqual(budget.rangeToLegacyDowngrades, 0)

        XCTAssertTrue(budget.consume(.legacyWiFiTransportRetry))
        XCTAssertFalse(budget.consume(.legacyWiFiTransportRetry))
        XCTAssertEqual(budget.legacyWiFiTransportRetries, 0)

        XCTAssertFalse(budget.consume(.legacyMeteredTransportRetry))
        XCTAssertEqual(budget.legacyMeteredTransportRetries, 0)

        XCTAssertTrue(budget.consume(.legacyRemuxRetry))
        XCTAssertFalse(budget.consume(.legacyRemuxRetry))
        XCTAssertEqual(budget.legacyRemuxRetries, 0)
    }

    func testSameBudgetValueRemainsConsumedAcrossSourceAttemptRefresh() {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        var budget = PlaybackSessionFailureBudget.initial

        XCTAssertTrue(budget.consume(.rangeTransportRetry))
        XCTAssertEqual(budget.rangeTransportRetries, 1)

        let priorSource = tokens.currentSourceAttempt
        let nextSource = tokens.refreshCurrentSourceAttempt()

        XCTAssertNotEqual(priorSource.id, nextSource.id)
        XCTAssertEqual(priorSource.sessionID, nextSource.sessionID)
        XCTAssertEqual(budget.rangeTransportRetries, 1)
        XCTAssertTrue(budget.consume(.rangeTransportRetry))
        XCTAssertFalse(budget.consume(.rangeTransportRetry))
    }

    func testConsentPromptIsAllowedOncePerFailedActionToken() {
        let playback = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let generation = LocalGenerationFingerprint(digest: "generation-a")
        let originalAction = FullTransferActionID.fresh()
        let explicitRetryAction = FullTransferActionID.fresh()
        let firstToken = FailedActionToken(
            sessionID: playback.sessionID,
            actionID: originalAction,
            generationFingerprint: generation,
            failureCategory: .transport,
            intent: .sourceFallback
        )
        let explicitRetryToken = FailedActionToken(
            sessionID: playback.sessionID,
            actionID: explicitRetryAction,
            generationFingerprint: generation,
            failureCategory: .transport,
            intent: .sourceFallback
        )
        var budget = PlaybackSessionFailureBudget.initial

        XCTAssertTrue(budget.consume(.consentPrompt(firstToken)))
        XCTAssertFalse(budget.consume(.consentPrompt(firstToken)))
        XCTAssertTrue(budget.consume(.consentPrompt(explicitRetryToken)))
        XCTAssertEqual(budget.consentPromptsByToken, [firstToken, explicitRetryToken])
    }

    func testCanonicalByteAndSeekParametersUseExactUnits() {
        XCTAssertEqual(PlaybackPolicyParameters.sharedTransientBytes, 200 * 1024 * 1024)
        XCTAssertEqual(PlaybackPolicyParameters.speculativePreloadCeilingBytes, 512 * 1024)
        XCTAssertEqual(PlaybackPolicyParameters.byteBudgetOverhead, 0.10)
        XCTAssertEqual(PlaybackPolicyParameters.coreSeekToleranceSeconds, 0.750)
        XCTAssertEqual(PlaybackPolicyParameters.decodedEvidenceSeconds, 0.500)
        XCTAssertEqual(PlaybackPolicyParameters.decodedEvidenceMinimumBuffers, 3)
    }

    func testForwardBufferSecondsCoverEveryNetworkClass() {
        XCTAssertEqual(PlaybackPolicyParameters.forwardBufferSeconds(for: .wifiUnconstrained), 15)
        XCTAssertEqual(PlaybackPolicyParameters.forwardBufferSeconds(for: .cellular), 8)
        XCTAssertEqual(PlaybackPolicyParameters.forwardBufferSeconds(for: .constrained), 5)
        XCTAssertEqual(PlaybackPolicyParameters.forwardBufferSeconds(for: .offline), 0)
    }

    func testResolverRangeAndSeekDeadlinesAreExact() {
        for networkClass in [PlaybackNetworkClass.wifiUnconstrained, .cellular, .constrained] {
            XCTAssertNil(
                PlaybackPolicyParameters.resolverNoProgressDeadlineSeconds(
                    for: networkClass
                )
            )
            XCTAssertEqual(
                PlaybackPolicyParameters.resolverAbsoluteDeadlineSeconds(for: networkClass),
                30
            )
            XCTAssertEqual(
                PlaybackPolicyParameters.rangePrepareSeekAbsoluteDeadlineSeconds(
                    for: networkClass
                ),
                30
            )
            XCTAssertNil(
                PlaybackPolicyParameters.activeRangeAbsoluteDeadlineSeconds(for: networkClass)
            )
        }

        XCTAssertEqual(
            PlaybackPolicyParameters.rangePrepareSeekNoProgressDeadlineSeconds(
                for: .wifiUnconstrained
            ),
            10
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.rangePrepareSeekNoProgressDeadlineSeconds(for: .cellular),
            15
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.rangePrepareSeekNoProgressDeadlineSeconds(for: .constrained),
            15
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.activeRangeNoProgressDeadlineSeconds(
                for: .wifiUnconstrained
            ),
            10
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.activeRangeNoProgressDeadlineSeconds(for: .cellular),
            15
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.activeRangeNoProgressDeadlineSeconds(for: .constrained),
            15
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.seekVerificationAbsoluteDeadlineSeconds(
                for: .wifiUnconstrained
            ),
            5
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.seekVerificationAbsoluteDeadlineSeconds(for: .cellular),
            8
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.seekVerificationAbsoluteDeadlineSeconds(for: .constrained),
            8
        )
    }

    func testLegacyDownloadAndRemuxDeadlinesAreExact() {
        for networkClass in [PlaybackNetworkClass.wifiUnconstrained, .cellular, .constrained] {
            XCTAssertEqual(
                PlaybackPolicyParameters.legacyFullDownloadNoProgressDeadlineSeconds(
                    for: networkClass
                ),
                15
            )
        }
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyFullDownloadAbsoluteDeadlineSeconds(
                for: .wifiUnconstrained
            ),
            300
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyFullDownloadAbsoluteDeadlineSeconds(for: .cellular),
            600
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyFullDownloadAbsoluteDeadlineSeconds(for: .constrained),
            600
        )
        XCTAssertEqual(PlaybackPolicyParameters.legacyRemuxNoProgressDeadlineSeconds, 15)
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyRemuxAbsoluteDeadlineSeconds(
                trackDurationSeconds: 10
            ),
            30
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyRemuxAbsoluteDeadlineSeconds(
                trackDurationSeconds: 240
            ),
            120
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyRemuxAbsoluteDeadlineSeconds(
                trackDurationSeconds: 1_000
            ),
            300
        )
    }

    func testInvalidRemuxDurationsUseThirtySecondFloor() {
        for invalidDuration in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(
                PlaybackPolicyParameters.legacyRemuxAbsoluteDeadlineSeconds(
                    trackDurationSeconds: invalidDuration
                ),
                30
            )
        }
    }

    func testOfflineNetworkDeadlinesFailClosed() {
        XCTAssertNil(
            PlaybackPolicyParameters.resolverNoProgressDeadlineSeconds(for: .offline)
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.resolverAbsoluteDeadlineSeconds(for: .offline),
            0
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.rangePrepareSeekNoProgressDeadlineSeconds(for: .offline),
            0
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.rangePrepareSeekAbsoluteDeadlineSeconds(for: .offline),
            0
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.activeRangeNoProgressDeadlineSeconds(for: .offline),
            0
        )
        XCTAssertNil(
            PlaybackPolicyParameters.activeRangeAbsoluteDeadlineSeconds(for: .offline)
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.seekVerificationAbsoluteDeadlineSeconds(for: .offline),
            0
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyFullDownloadNoProgressDeadlineSeconds(for: .offline),
            0
        )
        XCTAssertEqual(
            PlaybackPolicyParameters.legacyFullDownloadAbsoluteDeadlineSeconds(for: .offline),
            0
        )
    }
}
