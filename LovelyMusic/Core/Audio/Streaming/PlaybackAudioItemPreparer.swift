import AVFoundation
import Foundation
import os

// MARK: - Prepared item

struct PreparedPlaybackAudioItem: Sendable {
    let item: AVPlayerItem
    let itemID: PlaybackAudioItemID
    let retirementHandle: RetirementHandle
}

// MARK: - Retirement handle

final class RetirementHandle: @unchecked Sendable {
    private let onRetire: @Sendable () -> Void
    private let retired = OSAllocatedUnfairLock(initialState: false)

    init(onRetire: @escaping @Sendable () -> Void) {
        self.onRetire = onRetire
    }

    /// Idempotent: second call is a no-op.
    func retire() {
        let wasAlreadyRetired = retired.withLock { flag in
            defer { flag = true }
            return flag
        }
        guard !wasAlreadyRetired else { return }
        onRetire()
    }
}

// MARK: - Preparer errors

enum PlaybackItemPreparationError: Error {
    case noPlayableAudioTrack
    case multipleAudioTracks(Int)
    case tapCreationFailed
}

// MARK: - Central preparer

/// Asynchronously loads exactly one audio track, installs exactly one tap,
/// sets spectral pitch, and returns a fully prepared item before any player insertion.
@MainActor
final class PlaybackAudioItemPreparer {
    private let eqProcessor: EQAudioProcessor

    init(eqProcessor: EQAudioProcessor) {
        self.eqProcessor = eqProcessor
    }

    func prepare(
        asset: AVURLAsset,
        session: PlaybackSessionID,
        attempt: SourceAttemptID
    ) async throws -> PreparedPlaybackAudioItem {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let playableTracks = tracks.filter { $0.isPlayable }

        guard !playableTracks.isEmpty else {
            throw PlaybackItemPreparationError.noPlayableAudioTrack
        }
        guard playableTracks.count == 1 else {
            throw PlaybackItemPreparationError.multipleAudioTracks(playableTracks.count)
        }
        let audioTrack = playableTracks[0]

        let itemID = PlaybackAudioItemID.fresh()
        let item = AVPlayerItem(asset: asset)

        // One EQTapContext per item lifetime
        let tapIdentity = TapContextIdentity(
            sessionID: session,
            sourceAttemptID: attempt,
            itemID: itemID,
            tapID: UUID()
        )
        let context = EQTapContext(identity: tapIdentity)

        // Attach exactly one audio-mix processing tap
        guard let audioMix = eqProcessor.createAudioMix(for: context, track: audioTrack) else {
            throw PlaybackItemPreparationError.tapCreationFailed
        }
        item.audioMix = audioMix

        // Pitch-preserving 1.25x mode
        if let audioMixInput = audioMix.inputParameters.first {
            item.audioTimePitchAlgorithm = .spectral
            _ = audioMixInput  // audioMix already applied
        }
        item.audioTimePitchAlgorithm = .spectral

        let handle = RetirementHandle {
            context.logicallyInvalidate()
        }

        return PreparedPlaybackAudioItem(
            item: item,
            itemID: itemID,
            retirementHandle: handle
        )
    }
}
