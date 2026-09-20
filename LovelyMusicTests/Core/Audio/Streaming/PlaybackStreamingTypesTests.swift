import Foundation
import XCTest

@testable import LovelyMusic

final class PlaybackStreamingTypesTests: XCTestCase {
    func testFreshSessionsDistinguishReplayWithTypedIdentity() {
        let firstPlayback = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let replay = ActivePlaybackTokens.freshSession(source: .rangeStream)

        XCTAssertNotEqual(firstPlayback.sessionID, replay.sessionID)
        XCTAssertNotEqual(
            firstPlayback.currentSourceAttempt.id,
            replay.currentSourceAttempt.id
        )
        XCTAssertTrue(firstPlayback.accepts(firstPlayback.currentSourceAttempt))
        XCTAssertFalse(firstPlayback.accepts(replay.currentSourceAttempt))
    }

    func testStaleSessionAndRefreshedSourceAttemptsAreRejected() {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let originalSource = tokens.currentSourceAttempt
        let otherSession = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let forgedCrossSessionAttempt = SourceAttempt(
            sessionID: otherSession.sessionID,
            id: originalSource.id,
            source: originalSource.source
        )

        XCTAssertFalse(tokens.accepts(forgedCrossSessionAttempt))

        let replacementSource = tokens.refreshCurrentSourceAttempt()

        XCTAssertFalse(tokens.accepts(originalSource))
        XCTAssertTrue(tokens.accepts(replacementSource))
    }

    func testEveryNewSeekMintsTokenAndOnlyLatestTargetIsAccepted() throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let firstSeek = try XCTUnwrap(tokens.beginSeek(targetSeconds: 12.25))
        let latestSeek = try XCTUnwrap(tokens.beginSeek(targetSeconds: 91.5))

        XCTAssertNotEqual(firstSeek.id, latestSeek.id)
        XCTAssertFalse(tokens.accepts(firstSeek))
        XCTAssertTrue(tokens.accepts(latestSeek))
        XCTAssertEqual(tokens.latestSeekAttempt, latestSeek)
        XCTAssertEqual(tokens.latestSeekAttempt?.targetSeconds, 91.5)
    }

    func testSeekAcceptsZeroAndPositiveTargets() throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)

        let zeroSeek: SeekAttempt? = tokens.beginSeek(targetSeconds: 0)
        let positiveSeek: SeekAttempt? = tokens.beginSeek(targetSeconds: 1.25)

        XCTAssertEqual(try XCTUnwrap(zeroSeek).targetSeconds, 0)
        XCTAssertEqual(try XCTUnwrap(positiveSeek).targetSeconds, 1.25)
        XCTAssertTrue(tokens.accepts(try XCTUnwrap(positiveSeek)))
    }

    func testInvalidSeekTargetsDoNotMintOrReplaceLatestToken() throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let acceptedSeek = try XCTUnwrap(tokens.beginSeek(targetSeconds: 25))

        for invalidTarget in [-1.0, .nan, .infinity, -.infinity] {
            let rejectedSeek: SeekAttempt? = tokens.beginSeek(
                targetSeconds: invalidTarget
            )

            XCTAssertNil(rejectedSeek)
            XCTAssertEqual(tokens.latestSeekAttempt, acceptedSeek)
        }
    }

    func testForgedSameSeekIDWithDifferentTargetIsRejected() throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let currentSeek = try XCTUnwrap(tokens.beginSeek(targetSeconds: 30))
        let forgedSeek = SeekAttempt(
            sourceAttempt: currentSeek.sourceAttempt,
            id: currentSeek.id,
            targetSeconds: 31
        )

        XCTAssertFalse(tokens.accepts(forgedSeek))
        XCTAssertTrue(tokens.accepts(currentSeek))
    }

    func testRefreshingSourceKeepsSourceAndSessionButInvalidatesSeek() throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let priorSource = tokens.currentSourceAttempt
        let staleSeek = try XCTUnwrap(tokens.beginSeek(targetSeconds: 42))

        let refreshedSource = tokens.refreshCurrentSourceAttempt()

        XCTAssertEqual(refreshedSource.sessionID, priorSource.sessionID)
        XCTAssertEqual(refreshedSource.source, priorSource.source)
        XCTAssertNotEqual(refreshedSource.id, priorSource.id)
        XCTAssertEqual(tokens.currentSourceAttempt, refreshedSource)
        XCTAssertNil(tokens.latestSeekAttempt)
        XCTAssertFalse(tokens.accepts(staleSeek))
        XCTAssertTrue(tokens.accepts(refreshedSource))
    }

    func testRemoteSourceLockAndTokensAuthorizeOneMonotonicDowngrade() throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let initialRange = tokens.currentSourceAttempt
        var sourceLock = try XCTUnwrap(
            PlaybackSourceLock(initialRangeAttempt: initialRange)
        )
        let staleSeek = try XCTUnwrap(tokens.beginSeek(targetSeconds: 42))

        let legacyAttempt = try XCTUnwrap(
            tokens.downgradeToLegacy(using: &sourceLock)
        )

        XCTAssertEqual(legacyAttempt.sessionID, tokens.sessionID)
        XCTAssertEqual(legacyAttempt.source, .legacyDownloadRemux)
        XCTAssertNotEqual(legacyAttempt.id, initialRange.id)
        XCTAssertEqual(tokens.currentSourceAttempt, legacyAttempt)
        XCTAssertEqual(sourceLock.selectedRemoteSource, .legacyDownloadRemux)
        XCTAssertNil(tokens.latestSeekAttempt)
        XCTAssertFalse(tokens.accepts(staleSeek))

        let committedTokens = tokens
        let committedLock = sourceLock
        XCTAssertNil(tokens.downgradeToLegacy(using: &sourceLock))
        XCTAssertEqual(tokens, committedTokens)
        XCTAssertEqual(sourceLock, committedLock)
    }

    func testRefreshingRangeAttemptKeepsSessionScopedLockAndCanDowngrade() throws {
        var tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let initialRange = tokens.currentSourceAttempt
        var sourceLock = try XCTUnwrap(
            PlaybackSourceLock(initialRangeAttempt: initialRange)
        )
        let refreshedRange = tokens.refreshCurrentSourceAttempt()

        XCTAssertEqual(refreshedRange.sessionID, initialRange.sessionID)
        XCTAssertEqual(refreshedRange.source, .rangeStream)
        XCTAssertNotEqual(refreshedRange.id, initialRange.id)
        XCTAssertEqual(sourceLock.sessionID, tokens.sessionID)
        XCTAssertEqual(sourceLock.selectedRemoteSource, .rangeStream)

        let legacyAttempt = try XCTUnwrap(
            tokens.downgradeToLegacy(using: &sourceLock)
        )
        XCTAssertEqual(legacyAttempt.source, .legacyDownloadRemux)
        XCTAssertEqual(tokens.currentSourceAttempt, legacyAttempt)
        XCTAssertEqual(sourceLock.selectedRemoteSource, .legacyDownloadRemux)
    }

    func testRemoteDowngradeRejectsWrongSessionWithoutMutation() throws {
        var playback = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let otherPlayback = ActivePlaybackTokens.freshSession(source: .rangeStream)
        var otherSessionLock = try XCTUnwrap(
            PlaybackSourceLock(
                initialRangeAttempt: otherPlayback.currentSourceAttempt
            )
        )
        let originalPlayback = playback
        let originalLock = otherSessionLock

        XCTAssertNil(playback.downgradeToLegacy(using: &otherSessionLock))
        XCTAssertEqual(playback, originalPlayback)
        XCTAssertEqual(otherSessionLock, originalLock)
    }

    func testRemoteSourceLockRejectsInvalidInitialSources() {
        for source in [
            PlaybackSource.explicitDownload,
            .remuxCache,
            .legacyDownloadRemux,
        ] {
            let playback = ActivePlaybackTokens.freshSession(source: source)

            XCTAssertNil(
                PlaybackSourceLock(
                    initialRangeAttempt: playback.currentSourceAttempt
                )
            )
        }
    }
}
