import AVFoundation
import Foundation
import os
import Synchronization

// MARK: - Identity types

struct TapContextIdentity: Hashable, Sendable {
    let sessionID: PlaybackSessionID
    let sourceAttemptID: SourceAttemptID
    let itemID: PlaybackAudioItemID
    let tapID: UUID
}

// MARK: - Render stamp (fixed-size POD, no ARC)

struct RenderStamp: Equatable, Sendable {
    let renderOrdinal: UInt64
    let armGeneration: UInt64
    let formatGeneration: UInt32
}

// MARK: - Observation published from render thread

struct TapObservation: Sendable {
    let identity: TapContextIdentity
    let stamp: RenderStamp
    let sourceTimeRange: CMTimeRange
    let frameCount: UInt32
}

// MARK: - SPSC single-slot channel (one per tap context)

/// Non-blocking producer, blocking consumer.
/// Producer uses withLockIfAvailable — drops on contention.
/// Consumer uses withLock — always drains.
final class SPSCObservationSlot: @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<TapObservation?> =
        OSAllocatedUnfairLock(initialState: nil)

    /// Called from render thread. Returns false if slot was contended (observation dropped).
    @discardableResult
    func tryPublish(_ observation: TapObservation) -> Bool {
        storage.withLockIfAvailable { stored in
            stored = observation  // latest-wins
        } != nil
    }

    /// Called from main drain. Returns nil if slot was empty.
    func consume() -> TapObservation? {
        storage.withLock { stored in
            defer { stored = nil }
            return stored
        }
    }
}

// MARK: - Seek probe state

/// Arm generation counter + barrier for one seek verification.
struct ProbeArmState: Sendable {
    let armGeneration: UInt64
    let barrierOrdinal: UInt64  // render ordinals strictly > this may verify
}

// MARK: - Acceptance reducer (pure, no side effects)

/// Determines whether a tap observation counts as verified PCM for a seek target.
struct ProbeAcceptanceReducer {
    private(set) var bufferCount: Int = 0
    private(set) var totalFrames: Int = 0
    private(set) var firstVerifiedOrdinal: UInt64? = nil

    let identity: TapContextIdentity
    let arm: ProbeArmState
    let targetSeconds: TimeInterval
    let toleranceSeconds: TimeInterval
    let sampleRate: Double

    /// Returns true when the observation is accepted (strict forward ordinal, matching identity, range intersects target).
    mutating func accept(_ observation: TapObservation) -> Bool {
        guard observation.identity == identity else { return false }
        guard observation.stamp.armGeneration == arm.armGeneration else { return false }
        guard observation.stamp.renderOrdinal > arm.barrierOrdinal else { return false }
        guard observation.frameCount > 0 else { return false }
        guard observation.sourceTimeRange.isValid,
              !observation.sourceTimeRange.isEmpty,
              !observation.sourceTimeRange.start.isIndefinite,
              !observation.sourceTimeRange.duration.isIndefinite
        else { return false }

        // Check if sourceTimeRange intersects the target window
        let windowStart = CMTime(seconds: targetSeconds - toleranceSeconds, preferredTimescale: 48_000)
        let windowEnd   = CMTime(seconds: targetSeconds + toleranceSeconds, preferredTimescale: 48_000)
        let targetWindow = CMTimeRange(start: windowStart, end: windowEnd)
        let intersection = CMTimeRangeGetIntersection(observation.sourceTimeRange, otherRange: targetWindow)
        guard !intersection.isEmpty else { return false }

        // Deduplicate: ordinal must be strictly > any previously accepted ordinal
        if let prev = firstVerifiedOrdinal {
            guard observation.stamp.renderOrdinal > prev else { return false }
        }

        bufferCount += 1
        totalFrames += Int(observation.frameCount)
        if firstVerifiedOrdinal == nil {
            firstVerifiedOrdinal = observation.stamp.renderOrdinal
        }
        return true
    }

    var analyzedDurationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    var hasMinimumEvidence: Bool {
        bufferCount >= 3 && analyzedDurationSeconds >= 0.5
    }
}
