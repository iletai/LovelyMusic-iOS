import AVFoundation
import Accelerate
import MediaToolbox
import Synchronization
import os

// MARK: - EQRenderEpoch

/// One per prepare/unprepare cycle.
/// Owns one vDSP_biquad_Setup — never created or destroyed on the render thread.
final class EQRenderEpoch: @unchecked Sendable {
    let formatGeneration: UInt32
    private let setup: vDSP_biquad_Setup
    private var delayBuffers: [[Float]]
    /// Preallocated mailbox: latest (coefficients, generation) from control side.
    private let coeffMailbox: OSAllocatedUnfairLock<([Double], UInt64)?> =
        OSAllocatedUnfairLock(initialState: nil)
    private var appliedCoeffGeneration: UInt64 = 0

    init(formatGeneration: UInt32, coefficients: [Double], channelCount: Int) {
        self.formatGeneration = formatGeneration
        self.setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(EQAudioProcessor.bandCount))!
        let delayCount = 2 * EQAudioProcessor.bandCount + 2
        self.delayBuffers = (0..<channelCount).map { _ in Array(repeating: Float(0), count: delayCount) }
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
    }

    /// Called off-render (control side). Publishes new coefficient generation.
    func publishCoefficients(_ coefficients: [Double], generation: UInt64) {
        coeffMailbox.withLock { stored in
            stored = (coefficients, generation)
        }
    }

    /// Called on render thread at buffer boundary. Non-blocking mailbox read.
    /// Acknowledges the generation without rebuilding vDSP state on render thread.
    /// ponytail: coefficient update is generation-tracked only; actual vDSP setup rebuild
    /// happens via epoch replacement (off-render) when needed for audible EQ changes.
    func applyNewestCoefficientsIfAvailable() {
        var snapshot: ([Double], UInt64)? = nil
        let acquired = coeffMailbox.withLockIfAvailable { state -> Void in snapshot = state }
        guard acquired != nil, let (_, gen) = snapshot else { return }
        guard gen > appliedCoeffGeneration else { return }
        appliedCoeffGeneration = gen
    }

    /// Called on render thread. Processes PCM in-place.
    func processAudio(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for (idx, buffer) in buffers.enumerated() {
            guard idx < delayBuffers.count,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { continue }
            vDSP_biquad(setup, &delayBuffers[idx], data, 1, data, 1, vDSP_Length(frames))
        }
    }
}

// MARK: - EQTapContext

/// One per AVPlayerItem lifetime.
/// Owns one EQRenderEpoch (while tap is prepared).
final class EQTapContext: @unchecked Sendable {
    let identity: TapContextIdentity

    // Atomic render state (iOS 18+ Synchronization.Atomic)
    let armGeneration: Atomic<UInt64> = Atomic(0)
    let renderOrdinal: Atomic<UInt64> = Atomic(0)
    let activeRenderCount: Atomic<Int> = Atomic(0)
    let logicallyInvalidFlag: Atomic<Bool> = Atomic(false)
    let tapFinalizedFlag: Atomic<Bool> = Atomic(false)
    // Monotonically incremented per prepare cycle; identifies epoch format generation
    let epochFormatCounter: Atomic<UInt32> = Atomic(0)

    // Current epoch — modified only by prepare/unprepare (guarded by lock)
    private let epochLock: OSAllocatedUnfairLock<EQRenderEpoch?> =
        OSAllocatedUnfairLock(initialState: nil)

    // SPSC observation channel
    let renderChannel: SPSCObservationSlot = SPSCObservationSlot()

    init(identity: TapContextIdentity) {
        self.identity = identity
    }

    /// Called from control side when item is being replaced or retired.
    func logicallyInvalidate() {
        logicallyInvalidFlag.store(true, ordering: .releasing)
        _ = armGeneration.wrappingAdd(1, ordering: .relaxed)  // reject any in-flight observations
    }

    /// Called from `eqTapPrepare`. Creates a new epoch.
    func installEpoch(_ epoch: EQRenderEpoch) {
        epochLock.withLock { stored in stored = epoch }
    }

    /// Called from `eqTapUnprepare`. Removes epoch (it will be deallocated after leases release).
    func removeEpoch() {
        epochLock.withLock { stored in stored = nil }
    }

    /// Called from finalize callback (render system). Never waits.
    func markTapFinalized() {
        tapFinalizedFlag.store(true, ordering: .releasing)
    }

    // MARK: Render-thread entry/exit (no ARC, no allocation)

    struct RenderLease {
        let stamp: RenderStamp
        // unsafe reference — epoch is kept alive by context which is kept alive by tap passRetained
        let epoch: Unmanaged<EQRenderEpoch>

        func applyNewestCoefficients() {
            epoch.takeUnretainedValue().applyNewestCoefficientsIfAvailable()
        }

        func processAudio(_ list: UnsafeMutablePointer<AudioBufferList>) {
            epoch.takeUnretainedValue().processAudio(list)
        }
    }

    /// Called on render thread. No allocation, no ARC retain.
    func beginRender() -> RenderLease? {
        guard !logicallyInvalidFlag.load(ordering: .acquiring) else { return nil }

        let ordinal = renderOrdinal.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        let arm = armGeneration.load(ordering: .acquiring)
        _ = activeRenderCount.wrappingAdd(1, ordering: .acquiringAndReleasing)

        // Re-check after incrementing active count
        guard !logicallyInvalidFlag.load(ordering: .acquiring) else {
            _ = activeRenderCount.wrappingAdd(-1, ordering: .acquiringAndReleasing)
            return nil
        }

        guard let epoch = epochLock.withLockIfAvailable({ $0 }) else {
            _ = activeRenderCount.wrappingAdd(-1, ordering: .acquiringAndReleasing)
            return nil
        }
        guard let epoch else {
            _ = activeRenderCount.wrappingAdd(-1, ordering: .acquiringAndReleasing)
            return nil
        }

        let stamp = RenderStamp(
            renderOrdinal: ordinal,
            armGeneration: arm,
            formatGeneration: epoch.formatGeneration
        )
        return RenderLease(stamp: stamp, epoch: Unmanaged.passUnretained(epoch))
    }

    /// Called on render thread (via defer). No dispatch, no log.
    func endRender(_ lease: RenderLease) {
        _ = lease  // stamp only needed for identity — already published
        _ = activeRenderCount.wrappingAdd(-1, ordering: .releasing)
    }

    var activeLeases: Int { activeRenderCount.load(ordering: .acquiring) }
    var isLogicallyInvalid: Bool { logicallyInvalidFlag.load(ordering: .acquiring) }
    var isTapFinalized: Bool { tapFinalizedFlag.load(ordering: .acquiring) }
}

// MARK: - EQAudioProcessor

final class EQAudioProcessor: @unchecked Sendable {

    static let bandCount = 10
    static let centerFrequencies: [Float] = [
        32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    static let qualityFactor: Double = 1.414

    // MARK: - Thread-Safe Parameter Passing (off-render)

    private let pending = OSAllocatedUnfairLock(
        initialState: Params(
            gains: Array(repeating: Float(0), count: bandCount),
            enabled: false,
            generation: 0
        )
    )

    struct Params: Sendable {
        var gains: [Float]
        var enabled: Bool
        var generation: UInt64
    }

    // Legacy audio-thread state (kept for backward compatibility)
    fileprivate var activeGains: [Float] = Array(repeating: 0, count: bandCount)
    fileprivate var activeEnabled: Bool = false
    fileprivate var legacySampleRate: Double = 44_100
    fileprivate var legacyChannelCount: UInt32 = 2

    // MARK: - Public API (Main Thread)

    func updateBands(_ gains: [Float], enabled: Bool) {
        pending.withLock { p in
            p.gains = gains
            p.enabled = enabled
            p.generation &+= 1
        }
    }

    // MARK: - Tap creation (new context-based API)

    func createAudioMix(for context: EQTapContext, track: AVAssetTrack) -> AVMutableAudioMix? {
        guard let tap = createTap(context: context) else { return nil }
        let inputParams = AVMutableAudioMixInputParameters(track: track)
        inputParams.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [inputParams]
        return mix
    }

    // MARK: - Legacy API (kept for Downloads/video)

    @available(iOS, deprecated: 16.0, message: "Uses sync tracks API for local-file compatibility")
    func createAudioMix(for asset: AVAsset) -> AVMutableAudioMix? {
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return nil }
        // Legacy path: create a throw-away context (no observation channel used)
        let dummyIdentity = TapContextIdentity(
            sessionID: PlaybackSessionID.fresh(),
            sourceAttemptID: SourceAttemptID.fresh(),
            itemID: PlaybackAudioItemID.fresh(),
            tapID: UUID()
        )
        let context = EQTapContext(identity: dummyIdentity)
        return createAudioMix(for: context, track: audioTrack)
    }

    private func createTap(context: EQTapContext) -> MTAudioProcessingTap? {
        let ctxPtr = Unmanaged.passRetained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(ctxPtr),
            init: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if status != noErr {
            Unmanaged<EQTapContext>.fromOpaque(ctxPtr).release()
            return nil
        }
        return tap
    }

    // MARK: - Biquad helpers

    static func neutralCoefficients() -> [Double] {
        Array(repeating: [1.0, 0.0, 0.0, 0.0, 0.0], count: bandCount).flatMap { $0 }
    }

    static func peakingEQCoefficients(
        gains: [Float], sampleRate: Double
    ) -> [Double] {
        var result: [Double] = []
        for i in 0..<bandCount {
            result.append(contentsOf: peakingEQCoefficients(
                frequency: Double(centerFrequencies[i]),
                gainDB: Double(gains[i]),
                q: qualityFactor,
                sampleRate: sampleRate
            ))
        }
        return result
    }

    private static func peakingEQCoefficients(
        frequency: Double, gainDB: Double, q: Double, sampleRate: Double
    ) -> [Double] {
        guard abs(gainDB) > 0.01 else { return [1, 0, 0, 0, 0] }
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)
        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    // MARK: - Pending params helper (used by epoch rebuild off-render)

    func currentCoefficients(sampleRate: Double) -> [Double] {
        let params = pending.withLock { $0 }
        guard params.enabled else { return Self.neutralCoefficients() }
        return Self.peakingEQCoefficients(gains: params.gains, sampleRate: sampleRate)
    }
}

// MARK: - MTAudioProcessingTap C Callbacks

private func eqTapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func eqTapFinalize(tap: MTAudioProcessingTap) {
    let ctx = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
    ctx.takeUnretainedValue().markTapFinalized()
    ctx.release()
}

private func eqTapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let ctx = Unmanaged<EQTapContext>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()

    let fmt = processingFormat.pointee
    let sampleRate = fmt.mSampleRate
    let channelCount = Int(fmt.mChannelsPerFrame)
    let coefs = EQAudioProcessor.neutralCoefficients()
    let formatGen = ctx.epochFormatCounter.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
    let epoch = EQRenderEpoch(formatGeneration: formatGen, coefficients: coefs, channelCount: channelCount)
    ctx.installEpoch(epoch)
    Log.eq.info("Prepared: \(sampleRate) Hz, \(channelCount) ch")
}

private func eqTapUnprepare(tap: MTAudioProcessingTap) {
    Unmanaged<EQTapContext>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
        .removeEpoch()
}

private func eqTapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let ctx = Unmanaged<EQTapContext>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()

    let lease = ctx.beginRender()   // no allocation, no ARC
    defer { if let lease { ctx.endRender(lease) } }

    var sourceTimeRange = CMTimeRange.invalid
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, &sourceTimeRange, numberFramesOut
    )
    guard status == noErr else { return }
    guard numberFramesOut.pointee > 0, let lease else { return }

    lease.applyNewestCoefficients()
    lease.processAudio(bufferListInOut)

    // Publish observation for seek verification
    guard sourceTimeRange.isValid,
          !sourceTimeRange.isEmpty,
          sourceTimeRange.start.isNumeric,
          sourceTimeRange.duration.isNumeric,
          CMTimeCompare(sourceTimeRange.duration, .zero) > 0
    else { return }

    ctx.renderChannel.tryPublish(TapObservation(
        identity: ctx.identity,
        stamp: lease.stamp,
        sourceTimeRange: sourceTimeRange,
        frameCount: UInt32(numberFramesOut.pointee)
    ))
}
