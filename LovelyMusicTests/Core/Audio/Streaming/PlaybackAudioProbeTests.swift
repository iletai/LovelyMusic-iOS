import AVFoundation
import XCTest

@testable import LovelyMusic

final class PlaybackAudioProbeTests: XCTestCase {

    // MARK: - Helpers

    private func makeIdentity(
        sessionID: PlaybackSessionID = .fresh(),
        attemptID: SourceAttemptID = .fresh(),
        itemID: PlaybackAudioItemID = .fresh()
    ) -> TapContextIdentity {
        TapContextIdentity(
            sessionID: sessionID,
            sourceAttemptID: attemptID,
            itemID: itemID,
            tapID: UUID()
        )
    }

    private func makeObservation(
        identity: TapContextIdentity,
        renderOrdinal: UInt64,
        armGeneration: UInt64,
        formatGeneration: UInt32 = 1,
        startSeconds: Double = 1.0,
        durationSeconds: Double = 0.2,
        frameCount: UInt32 = 9_600
    ) -> TapObservation {
        let stamp = RenderStamp(
            renderOrdinal: renderOrdinal,
            armGeneration: armGeneration,
            formatGeneration: formatGeneration
        )
        let start = CMTime(seconds: startSeconds, preferredTimescale: 48_000)
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 48_000)
        let range = CMTimeRangeMake(start: start, duration: duration)
        return TapObservation(
            identity: identity,
            stamp: stamp,
            sourceTimeRange: range,
            frameCount: frameCount
        )
    }

    private func makeReducer(
        identity: TapContextIdentity,
        armGeneration: UInt64 = 0,
        barrierOrdinal: UInt64 = 0,
        targetSeconds: TimeInterval = 1.1,
        toleranceSeconds: TimeInterval = 0.750,
        sampleRate: Double = 48_000
    ) -> ProbeAcceptanceReducer {
        ProbeAcceptanceReducer(
            identity: identity,
            arm: ProbeArmState(armGeneration: armGeneration, barrierOrdinal: barrierOrdinal),
            targetSeconds: targetSeconds,
            toleranceSeconds: toleranceSeconds,
            sampleRate: sampleRate
        )
    }

    // MARK: - SPSCObservationSlot

    func testSPSCSlotPublishAndConsume() {
        let slot = SPSCObservationSlot()
        let identity = makeIdentity()
        let obs = makeObservation(identity: identity, renderOrdinal: 1, armGeneration: 0)

        let published = slot.tryPublish(obs)
        XCTAssertTrue(published)

        let consumed = slot.consume()
        XCTAssertNotNil(consumed)
        XCTAssertEqual(consumed?.stamp.renderOrdinal, 1)
    }

    func testSPSCSlotConsumeEmptyReturnsNil() {
        let slot = SPSCObservationSlot()
        XCTAssertNil(slot.consume())
    }

    func testSPSCSlotLatestWins() {
        let slot = SPSCObservationSlot()
        let identity = makeIdentity()

        let obs1 = makeObservation(identity: identity, renderOrdinal: 1, armGeneration: 0)
        let obs2 = makeObservation(identity: identity, renderOrdinal: 2, armGeneration: 0)

        _ = slot.tryPublish(obs1)
        _ = slot.tryPublish(obs2)

        let consumed = slot.consume()
        XCTAssertEqual(consumed?.stamp.renderOrdinal, 2, "Latest-wins: second publish should overwrite first")
    }

    func testSPSCSlotConsumeAfterConsumeReturnsNil() {
        let slot = SPSCObservationSlot()
        let identity = makeIdentity()
        let obs = makeObservation(identity: identity, renderOrdinal: 1, armGeneration: 0)

        _ = slot.tryPublish(obs)
        _ = slot.consume()
        XCTAssertNil(slot.consume())
    }

    // MARK: - ProbeAcceptanceReducer identity filtering

    func testReducerRejectsWrongSessionID() {
        let identity = makeIdentity()
        let wrongIdentity = makeIdentity()  // fresh session/attempt/item
        var reducer = makeReducer(identity: identity)

        let obs = makeObservation(identity: wrongIdentity, renderOrdinal: 1, armGeneration: 0)
        XCTAssertFalse(reducer.accept(obs))
        XCTAssertEqual(reducer.bufferCount, 0)
    }

    func testReducerRejectsWrongSourceAttemptID() {
        let sessionID = PlaybackSessionID.fresh()
        let identity = makeIdentity(sessionID: sessionID)
        let wrongAttempt = makeIdentity(sessionID: sessionID)  // same session, different attempt
        var reducer = makeReducer(identity: identity)

        let obs = makeObservation(identity: wrongAttempt, renderOrdinal: 1, armGeneration: 0)
        XCTAssertFalse(reducer.accept(obs))
    }

    func testReducerRejectsWrongItemID() {
        let sessionID = PlaybackSessionID.fresh()
        let attemptID = SourceAttemptID.fresh()
        let identity = makeIdentity(sessionID: sessionID, attemptID: attemptID)
        let wrongItem = makeIdentity(sessionID: sessionID, attemptID: attemptID)  // same session+attempt, different item
        var reducer = makeReducer(identity: identity)

        let obs = makeObservation(identity: wrongItem, renderOrdinal: 1, armGeneration: 0)
        XCTAssertFalse(reducer.accept(obs))
    }

    // MARK: - ProbeAcceptanceReducer arm generation filtering

    func testReducerRejectsStaleArmGeneration() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 2)

        // Observation with old arm generation (1) — must be rejected
        let stale = makeObservation(identity: identity, renderOrdinal: 5, armGeneration: 1)
        XCTAssertFalse(reducer.accept(stale))
        XCTAssertEqual(reducer.bufferCount, 0)
    }

    func testReducerAcceptsMatchingArmGeneration() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 3, barrierOrdinal: 0)

        let obs = makeObservation(identity: identity, renderOrdinal: 1, armGeneration: 3)
        XCTAssertTrue(reducer.accept(obs))
        XCTAssertEqual(reducer.bufferCount, 1)
    }

    func testReducerRejectsNewerArmGeneration() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 1)

        // Future arm generation is also rejected
        let future = makeObservation(identity: identity, renderOrdinal: 5, armGeneration: 2)
        XCTAssertFalse(reducer.accept(future))
    }

    // MARK: - ProbeAcceptanceReducer barrier ordinal filtering

    func testReducerRejectsOrdinalAtOrBelowBarrier() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 10)

        // Ordinal == barrier: reject
        let atBarrier = makeObservation(identity: identity, renderOrdinal: 10, armGeneration: 0)
        XCTAssertFalse(reducer.accept(atBarrier))

        // Ordinal < barrier: reject
        let below = makeObservation(identity: identity, renderOrdinal: 9, armGeneration: 0)
        XCTAssertFalse(reducer.accept(below))
    }

    func testReducerAcceptsOrdinalAboveBarrier() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 10)

        let above = makeObservation(identity: identity, renderOrdinal: 11, armGeneration: 0)
        XCTAssertTrue(reducer.accept(above))
    }

    func testReducerEnforcesStrictlyIncreasingOrdinals() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 0)

        let obs1 = makeObservation(identity: identity, renderOrdinal: 1, armGeneration: 0)
        let obs2Dup = makeObservation(identity: identity, renderOrdinal: 1, armGeneration: 0)  // same ordinal
        let obs2Earlier = makeObservation(identity: identity, renderOrdinal: 0, armGeneration: 0)  // regressed ordinal

        XCTAssertTrue(reducer.accept(obs1))
        XCTAssertFalse(reducer.accept(obs2Dup), "Duplicate ordinal must be rejected")
        XCTAssertFalse(reducer.accept(obs2Earlier), "Regressed ordinal must be rejected")
        XCTAssertEqual(reducer.bufferCount, 1)
    }

    // MARK: - ProbeAcceptanceReducer target window intersection

    func testReducerRejectsObservationOutsideTargetWindow() {
        let identity = makeIdentity()
        // Target = 5.0s, tolerance = 0.750s → window is [4.25, 5.75]
        var reducer = makeReducer(
            identity: identity,
            armGeneration: 0,
            barrierOrdinal: 0,
            targetSeconds: 5.0,
            toleranceSeconds: 0.750
        )

        // Observation at [1.0, 1.2] — well outside [4.25, 5.75]
        let obs = makeObservation(
            identity: identity,
            renderOrdinal: 1,
            armGeneration: 0,
            startSeconds: 1.0,
            durationSeconds: 0.2
        )
        XCTAssertFalse(reducer.accept(obs))
    }

    func testReducerAcceptsObservationInsideTargetWindow() {
        let identity = makeIdentity()
        // Target = 5.0s, tolerance = 0.750s → window is [4.25, 5.75]
        var reducer = makeReducer(
            identity: identity,
            armGeneration: 0,
            barrierOrdinal: 0,
            targetSeconds: 5.0,
            toleranceSeconds: 0.750
        )

        // Observation at [4.5, 4.7] — inside window
        let obs = makeObservation(
            identity: identity,
            renderOrdinal: 1,
            armGeneration: 0,
            startSeconds: 4.5,
            durationSeconds: 0.2
        )
        XCTAssertTrue(reducer.accept(obs))
    }

    func testReducerRejectsZeroFrameObservation() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 0)

        let obs = makeObservation(
            identity: identity,
            renderOrdinal: 1,
            armGeneration: 0,
            frameCount: 0
        )
        XCTAssertFalse(reducer.accept(obs))
    }

    func testReducerRejectsInvalidSourceTimeRange() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 0)

        let stamp = RenderStamp(renderOrdinal: 1, armGeneration: 0, formatGeneration: 1)
        let obs = TapObservation(
            identity: identity,
            stamp: stamp,
            sourceTimeRange: .invalid,
            frameCount: 9_600
        )
        XCTAssertFalse(reducer.accept(obs))
    }

    func testReducerRejectsEmptySourceTimeRange() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 0)

        let stamp = RenderStamp(renderOrdinal: 1, armGeneration: 0, formatGeneration: 1)
        let obs = TapObservation(
            identity: identity,
            stamp: stamp,
            sourceTimeRange: CMTimeRange(
                start: CMTime(seconds: 1.0, preferredTimescale: 48_000),
                duration: .zero
            ),
            frameCount: 9_600
        )
        XCTAssertFalse(reducer.accept(obs))
    }

    // MARK: - hasMinimumEvidence

    func testReducerHasMinimumEvidenceRequiresThreeBuffersAndHalfSecond() {
        let identity = makeIdentity()
        // 48000 Hz, 9600 frames/buffer = 0.2 seconds/buffer
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 0, sampleRate: 48_000)

        for i in 0..<3 {
            let obs = makeObservation(
                identity: identity,
                renderOrdinal: UInt64(i + 1),
                armGeneration: 0,
                startSeconds: Double(i) * 0.2 + 1.0,
                durationSeconds: 0.2,
                frameCount: 9_600  // 0.2 seconds @ 48kHz
            )
            _ = reducer.accept(obs)
        }

        XCTAssertEqual(reducer.bufferCount, 3)
        XCTAssertGreaterThanOrEqual(reducer.analyzedDurationSeconds, 0.5 - 0.01)
        XCTAssertTrue(reducer.hasMinimumEvidence)
    }

    func testReducerDoesNotHaveMinimumEvidenceWithTwoBuffers() {
        let identity = makeIdentity()
        var reducer = makeReducer(identity: identity, armGeneration: 0, barrierOrdinal: 0, sampleRate: 48_000)

        for i in 0..<2 {
            let obs = makeObservation(
                identity: identity,
                renderOrdinal: UInt64(i + 1),
                armGeneration: 0,
                startSeconds: Double(i) * 0.25 + 1.0,
                durationSeconds: 0.25,
                frameCount: 12_000
            )
            _ = reducer.accept(obs)
        }

        XCTAssertFalse(reducer.hasMinimumEvidence, "Two buffers is insufficient even if > 500ms")
    }

    // MARK: - Ten rapid last-wins seeks

    func testTenRapidSeeksOldArmGenerationsRejected() {
        let identity = makeIdentity()

        // Simulate 10 rapid seeks: arm generations 0..9
        // Only the latest arm (9) should accept observations
        let latestArm: UInt64 = 9
        var finalReducer = makeReducer(
            identity: identity,
            armGeneration: latestArm,
            barrierOrdinal: 0
        )

        // Observations with stale arm generations 0..8 must all be rejected
        for staleArm: UInt64 in 0..<9 {
            let obs = makeObservation(
                identity: identity,
                renderOrdinal: staleArm + 1,
                armGeneration: staleArm
            )
            XCTAssertFalse(finalReducer.accept(obs), "Stale arm \(staleArm) should be rejected by arm \(latestArm)")
        }

        // Observation with latest arm (9) must be accepted
        let fresh = makeObservation(identity: identity, renderOrdinal: 100, armGeneration: latestArm)
        XCTAssertTrue(finalReducer.accept(fresh))
    }

    func testAdjacentSeekTargetsDoNotCrossContaminate() {
        // Two seeks: target 4.9s (arm 0) and target 5.1s (arm 1)
        // Overlap with ±750ms: both windows cover 5.0s
        // But arm generation filtering ensures only the newest arm verifies
        let identity = makeIdentity()

        let arm0Reducer = makeReducer(
            identity: identity,
            armGeneration: 0,
            barrierOrdinal: 0,
            targetSeconds: 4.9,
            toleranceSeconds: 0.750
        )
        var arm1Reducer = makeReducer(
            identity: identity,
            armGeneration: 1,
            barrierOrdinal: 50,  // barrier set after seek 0 completed
            targetSeconds: 5.1,
            toleranceSeconds: 0.750
        )

        // Observation at [4.9, 5.1] — intersects both windows spatially
        let obs = makeObservation(
            identity: identity,
            renderOrdinal: 51,
            armGeneration: 0,  // OLD arm — belongs to seek 0
            startSeconds: 4.9,
            durationSeconds: 0.2
        )

        // Should NOT be accepted by arm1Reducer (wrong arm generation)
        XCTAssertFalse(arm1Reducer.accept(obs), "Old arm observation must not contaminate new seek")

        // Arm 0 reducer would accept it (but arm 0 is no longer active in production)
        var arm0Copy = arm0Reducer
        // arm 0 reducer with barrier 0 would accept ordinal 51 with arm 0
        let obsForArm0 = makeObservation(
            identity: identity,
            renderOrdinal: 51,
            armGeneration: 0,
            startSeconds: 4.9,
            durationSeconds: 0.2
        )
        XCTAssertTrue(arm0Copy.accept(obsForArm0))
    }

    // MARK: - Paused barrier

    func testPausedBarrierNoAdvanceBeforeResume() {
        // Paused: barrier is set AFTER seek completes; observations at ordinals ≤ barrier are rejected
        let identity = makeIdentity()
        let barrierOrdinal: UInt64 = 100  // captured after seek completion
        var reducer = makeReducer(
            identity: identity,
            armGeneration: 0,
            barrierOrdinal: barrierOrdinal,
            targetSeconds: 5.0
        )

        // Observations at ordinal ≤ barrier (pre-seek PCM) must be rejected
        for ordinal: UInt64 in 95...100 {
            let obs = makeObservation(
                identity: identity,
                renderOrdinal: ordinal,
                armGeneration: 0,
                startSeconds: 4.8,
                durationSeconds: 0.2
            )
            XCTAssertFalse(reducer.accept(obs), "Ordinal \(ordinal) ≤ barrier \(barrierOrdinal) should be rejected")
        }

        // First ordinal above barrier (101) is accepted
        let firstNew = makeObservation(
            identity: identity,
            renderOrdinal: 101,
            armGeneration: 0,
            startSeconds: 4.9,
            durationSeconds: 0.2
        )
        XCTAssertTrue(reducer.accept(firstNew))
    }
}
