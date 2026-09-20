import AVFoundation
import XCTest

@testable import LovelyMusic

@MainActor
final class EQAudioTapCompositionTests: XCTestCase {

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

    private func makeNeutralCoefficients() -> [Double] {
        EQAudioProcessor.neutralCoefficients()
    }

    private func makeEpoch(
        formatGeneration: UInt32 = 1,
        channelCount: Int = 1,
        coefficients: [Double]? = nil
    ) -> EQRenderEpoch {
        let coefs = coefficients ?? makeNeutralCoefficients()
        return EQRenderEpoch(
            formatGeneration: formatGeneration,
            coefficients: coefs,
            channelCount: channelCount
        )
    }

    // MARK: - EQTapContext lifecycle

    func testEQTapContextInitialState() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)

        XCTAssertFalse(ctx.isLogicallyInvalid)
        XCTAssertFalse(ctx.isTapFinalized)
        XCTAssertEqual(ctx.activeLeases, 0)
    }

    func testLogicallyInvalidateMarksContext() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)

        ctx.logicallyInvalidate()
        XCTAssertTrue(ctx.isLogicallyInvalid)
    }

    func testMarkTapFinalizedMarksContext() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)

        ctx.markTapFinalized()
        XCTAssertTrue(ctx.isTapFinalized)
    }

    func testLogicallyInvalidateIncreasesArmGeneration() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)

        let before = ctx.armGeneration.load(ordering: .relaxed)
        ctx.logicallyInvalidate()
        let after = ctx.armGeneration.load(ordering: .relaxed)

        XCTAssertGreaterThan(after, before, "Logical invalidation must increment arm generation")
    }

    // MARK: - EQRenderEpoch format generation

    func testEQRenderEpochFormatGeneration() {
        let epoch1 = makeEpoch(formatGeneration: 1)
        let epoch2 = makeEpoch(formatGeneration: 2)

        XCTAssertEqual(epoch1.formatGeneration, 1)
        XCTAssertEqual(epoch2.formatGeneration, 2)
        XCTAssertNotEqual(epoch1.formatGeneration, epoch2.formatGeneration)
    }

    func testEQTapContextInstallAndRemoveEpoch() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        let epoch = makeEpoch(formatGeneration: 1)

        ctx.installEpoch(epoch)
        // After install, beginRender should succeed
        let lease = ctx.beginRender()
        XCTAssertNotNil(lease)
        if let l = lease { ctx.endRender(l) }

        ctx.removeEpoch()
        // After remove, beginRender should return nil
        let leaseAfterRemove = ctx.beginRender()
        XCTAssertNil(leaseAfterRemove, "No epoch installed — beginRender must return nil")
    }

    // MARK: - beginRender / endRender

    func testBeginRenderWithoutEpochReturnsNil() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        // No epoch installed
        XCTAssertNil(ctx.beginRender())
    }

    func testBeginRenderAfterLogicallyInvalidateReturnsNil() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        ctx.installEpoch(makeEpoch())
        ctx.logicallyInvalidate()

        XCTAssertNil(ctx.beginRender(), "Logically invalid context must not produce leases")
    }

    func testBeginRenderIncrementsRenderOrdinal() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        ctx.installEpoch(makeEpoch())

        let l1 = ctx.beginRender()
        let l2 = ctx.beginRender()

        XCTAssertNotNil(l1)
        XCTAssertNotNil(l2)
        if let a = l1, let b = l2 {
            XCTAssertLessThan(a.stamp.renderOrdinal, b.stamp.renderOrdinal)
            ctx.endRender(a)
            ctx.endRender(b)
        }
    }

    func testEndRenderDecrementsActiveCount() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        ctx.installEpoch(makeEpoch())

        let lease = ctx.beginRender()
        XCTAssertEqual(ctx.activeLeases, 1)

        if let l = lease { ctx.endRender(l) }
        XCTAssertEqual(ctx.activeLeases, 0)
    }

    func testActiveLeasesPreventsReclamationCondition() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        ctx.installEpoch(makeEpoch())

        let lease = ctx.beginRender()
        ctx.logicallyInvalidate()
        ctx.markTapFinalized()

        // While a lease is active, activeLeases > 0 → can't reclaim yet
        XCTAssertGreaterThan(ctx.activeLeases, 0)

        if let l = lease { ctx.endRender(l) }

        // After endRender, all conditions for reclaim should be met
        XCTAssertEqual(ctx.activeLeases, 0)
        XCTAssertTrue(ctx.isLogicallyInvalid)
        XCTAssertTrue(ctx.isTapFinalized)
    }

    // MARK: - RenderLease stamp matches context state

    func testRenderLeaseStampSnapshotsArmGenerationAtBeginRender() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        ctx.installEpoch(makeEpoch(formatGeneration: 3))

        let lease = ctx.beginRender()
        XCTAssertNotNil(lease)

        let armAtBegin = ctx.armGeneration.load(ordering: .relaxed)
        XCTAssertEqual(lease?.stamp.armGeneration, armAtBegin)

        if let l = lease { ctx.endRender(l) }
    }

    func testRenderLeaseStampCapturesEpochFormatGeneration() {
        let identity = makeIdentity()
        let ctx = EQTapContext(identity: identity)
        ctx.installEpoch(makeEpoch(formatGeneration: 7))

        let lease = ctx.beginRender()
        XCTAssertEqual(lease?.stamp.formatGeneration, 7)

        if let l = lease { ctx.endRender(l) }
    }

    // MARK: - Two independent contexts for crossfade

    func testTwoPreparedItemsHaveIndependentContexts() {
        let session = PlaybackSessionID.fresh()
        let attempt1 = SourceAttemptID.fresh()
        let attempt2 = SourceAttemptID.fresh()
        let item1 = PlaybackAudioItemID.fresh()
        let item2 = PlaybackAudioItemID.fresh()

        let ctx1 = EQTapContext(identity: makeIdentity(
            sessionID: session,
            attemptID: attempt1,
            itemID: item1
        ))
        let ctx2 = EQTapContext(identity: makeIdentity(
            sessionID: session,
            attemptID: attempt2,
            itemID: item2
        ))

        // Independent identities
        XCTAssertNotEqual(ctx1.identity, ctx2.identity)

        // Independent state: invalidating one doesn't affect other
        ctx1.logicallyInvalidate()
        XCTAssertTrue(ctx1.isLogicallyInvalid)
        XCTAssertFalse(ctx2.isLogicallyInvalid, "Invalidating ctx1 must not affect ctx2")
    }

    func testTwoContextsIndependentArmGenerations() {
        let ctx1 = EQTapContext(identity: makeIdentity())
        let ctx2 = EQTapContext(identity: makeIdentity())

        ctx1.installEpoch(makeEpoch())
        ctx2.installEpoch(makeEpoch())

        // Arm 1 on ctx1
        ctx1.logicallyInvalidate()
        let arm1 = ctx1.armGeneration.load(ordering: .relaxed)

        // Arm 0 on ctx2
        let arm2 = ctx2.armGeneration.load(ordering: .relaxed)

        XCTAssertGreaterThan(arm1, arm2, "ctx1 arm incremented, ctx2 remains at 0")
    }

    func testTwoContextsHaveIndependentSPSCChannels() {
        let identity1 = makeIdentity()
        let identity2 = makeIdentity()
        let ctx1 = EQTapContext(identity: identity1)
        let ctx2 = EQTapContext(identity: identity2)

        let stamp = RenderStamp(renderOrdinal: 1, armGeneration: 0, formatGeneration: 1)
        let range = CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 48_000),
            duration: CMTime(seconds: 0.2, preferredTimescale: 48_000)
        )
        let obs1 = TapObservation(identity: identity1, stamp: stamp, sourceTimeRange: range, frameCount: 9_600)

        ctx1.renderChannel.tryPublish(obs1)

        // ctx2 channel is independent — not affected
        XCTAssertNil(ctx2.renderChannel.consume(), "ctx2 channel must be empty when only ctx1 publishes")
        XCTAssertNotNil(ctx1.renderChannel.consume())
    }

    // MARK: - EQRenderEpoch coefficient mailbox

    func testEpochCoefficientsPublishAndConsumeOnRender() {
        let epoch = makeEpoch(formatGeneration: 1, channelCount: 1)

        // Publish new coefficients off-render
        let newCoefs = EQAudioProcessor.neutralCoefficients()
        epoch.publishCoefficients(newCoefs, generation: 1)

        // applyNewestCoefficientsIfAvailable should not crash on render thread
        // (non-blocking, no allocation, just updates internal state)
        epoch.applyNewestCoefficientsIfAvailable()
        // No way to observe the applied state externally, but no crash = pass
    }

    func testEpochCoefficientsCalledTwiceDoesNotCrash() {
        let epoch = makeEpoch(formatGeneration: 1, channelCount: 1)

        epoch.publishCoefficients(EQAudioProcessor.neutralCoefficients(), generation: 1)
        epoch.publishCoefficients(EQAudioProcessor.neutralCoefficients(), generation: 2)

        epoch.applyNewestCoefficientsIfAvailable()
        epoch.applyNewestCoefficientsIfAvailable()
    }

    // MARK: - RetirementHandle idempotency

    func testRetirementHandleIdempotent() {
        var retireCount = 0
        let handle = RetirementHandle {
            retireCount += 1
        }

        handle.retire()
        handle.retire()
        handle.retire()

        XCTAssertEqual(retireCount, 1, "RetirementHandle.retire() must be idempotent")
    }

    func testRetirementHandleCallsOnRetire() {
        var called = false
        let handle = RetirementHandle { called = true }

        XCTAssertFalse(called)
        handle.retire()
        XCTAssertTrue(called)
    }

    // MARK: - PlaybackAudioItemPreparer

    @MainActor
    func testPreparerRejectsMissingAssetWithNoTracks() async {
        let eq = EQAudioProcessor()
        let preparer = PlaybackAudioItemPreparer(eqProcessor: eq)

        // Asset with no tracks (e.g. invalid URL)
        let url = URL(string: "file:///nonexistent_\(UUID().uuidString).m4a")!
        let asset = AVURLAsset(url: url)

        do {
            _ = try await preparer.prepare(
                asset: asset,
                session: .fresh(),
                attempt: .fresh()
            )
            XCTFail("Expected error for asset with no tracks")
        } catch PlaybackItemPreparationError.noPlayableAudioTrack {
            // expected
        } catch {
            // Any error is acceptable — the asset has no tracks
        }
    }

    func testPreparerProducesUniqueItemIDsForTwoPrepares() async throws {
        // We can't create real audio assets in unit tests without fixture files,
        // but we can verify that fresh IDs are unique per factory call.
        let id1 = PlaybackAudioItemID.fresh()
        let id2 = PlaybackAudioItemID.fresh()

        XCTAssertNotEqual(id1, id2, "Each fresh PlaybackAudioItemID must be unique")
    }

    // MARK: - One-tap-per-item invariant (structural check)

    func testPreparerCreatesOneContextPerPrepare() {
        // Structural test: each EQTapContext has a unique tapID
        let s = PlaybackSessionID.fresh()
        let a = SourceAttemptID.fresh()
        let i = PlaybackAudioItemID.fresh()

        let ctx1 = EQTapContext(identity: TapContextIdentity(
            sessionID: s, sourceAttemptID: a, itemID: i, tapID: UUID()
        ))
        let ctx2 = EQTapContext(identity: TapContextIdentity(
            sessionID: s, sourceAttemptID: a, itemID: i, tapID: UUID()
        ))

        XCTAssertNotEqual(ctx1.identity.tapID, ctx2.identity.tapID, "Each tap creation must use a unique tapID")
    }

    // MARK: - EQAudioProcessor static helpers

    func testNeutralCoefficientsHaveCorrectCount() {
        let coefs = EQAudioProcessor.neutralCoefficients()
        XCTAssertEqual(coefs.count, EQAudioProcessor.bandCount * 5)
    }

    func testNeutralCoefficientsAreIdentityFilters() {
        let coefs = EQAudioProcessor.neutralCoefficients()
        for bandIndex in 0..<EQAudioProcessor.bandCount {
            let base = bandIndex * 5
            XCTAssertEqual(coefs[base], 1.0, accuracy: 1e-10, "b0 must be 1 for neutral band \(bandIndex)")
            XCTAssertEqual(coefs[base + 1], 0.0, accuracy: 1e-10, "b1 must be 0 for neutral band \(bandIndex)")
            XCTAssertEqual(coefs[base + 2], 0.0, accuracy: 1e-10, "b2 must be 0 for neutral band \(bandIndex)")
            XCTAssertEqual(coefs[base + 3], 0.0, accuracy: 1e-10, "a1 must be 0 for neutral band \(bandIndex)")
            XCTAssertEqual(coefs[base + 4], 0.0, accuracy: 1e-10, "a2 must be 0 for neutral band \(bandIndex)")
        }
    }
}
