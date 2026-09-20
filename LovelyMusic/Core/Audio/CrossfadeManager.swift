import AVFoundation
import Foundation
import os

/// Manages crossfade transitions between two AVPlayer instances.
/// Uses a Timer-based volume animation (~30fps) for smooth fading.
@MainActor
@Observable
final class CrossfadeManager {
    // MARK: - Configuration

    /// Crossfade duration in seconds (0 = disabled). Stored in UserDefaults.
    var crossfadeDuration: TimeInterval {
        didSet {
            UserDefaults.standard.set(crossfadeDuration, forKey: "crossfade_duration")
        }
    }

    /// Whether crossfade is currently active (two players playing simultaneously).
    private(set) var isCrossfading: Bool = false

    // MARK: - Players

    /// The player currently producing audio (fading out during crossfade).
    private(set) var outgoingPlayer: AVPlayer?

    /// The player fading in during crossfade.
    private(set) var incomingPlayer: AVPlayer?

    // MARK: - Private

    private var fadeTimer: Timer?
    private var fadeStartTime: Date?
    private var fadeDuration: TimeInterval = 0
    private var crossfadeTriggered: Bool = false
    private var onCrossfadeComplete: (() -> Void)?

    /// Volume level before crossfade started (respects normalization).
    private var targetVolume: Float = 1.0

    init() {
        let saved = UserDefaults.standard.double(forKey: "crossfade_duration")
        self.crossfadeDuration = saved
    }

    /// Whether crossfade is enabled (duration > 0).
    var isEnabled: Bool { crossfadeDuration > 0 }

    /// Resets the crossfade trigger flag so the next track can trigger crossfade.
    func resetTrigger() {
        crossfadeTriggered = false
    }

    /// Returns true if crossfade should trigger at the given playback position.
    /// Only triggers once per track (guarded by `crossfadeTriggered`).
    func shouldTrigger(
        currentTime: TimeInterval, duration: TimeInterval, repeatMode: AudioEngine.RepeatMode
    ) -> Bool {
        guard isEnabled,
            !isCrossfading,
            !crossfadeTriggered,
            repeatMode != .one,
            duration > crossfadeDuration + 1,  // Meaningful crossfade requires enough track length
            currentTime >= duration - crossfadeDuration,
            currentTime > 0
        else { return false }
        return true
    }

    /// Begins crossfade: fades out the outgoing player while fading in the incoming player.
    /// - Parameters:
    ///   - outgoing: The current AVPlayer (will fade out).
    ///   - incoming: The next AVPlayer (will fade in).
    ///   - volume: The target volume (e.g. 0.85 for normalization, 1.0 default).
    ///   - completion: Called when crossfade finishes — swap player references here.
    func start(
        outgoing: AVPlayer,
        incoming: AVPlayer,
        volume: Float,
        completion: @escaping () -> Void
    ) {
        cancelFade()

        self.outgoingPlayer = outgoing
        self.incomingPlayer = incoming
        self.targetVolume = volume
        self.fadeDuration = crossfadeDuration
        self.onCrossfadeComplete = completion
        self.isCrossfading = true
        self.crossfadeTriggered = true

        // Set initial volumes
        outgoing.volume = volume
        incoming.volume = 0.0

        Log.audio.info("Crossfade started: duration=\(self.fadeDuration)s, targetVolume=\(volume)")

        fadeStartTime = Date()
        // ~30fps update rate
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateFade()
            }
        }
    }

    /// Cancels any in-progress crossfade and cleans up.
    func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeStartTime = nil

        if isCrossfading {
            // Stop and clean up the incoming player if crossfade is interrupted
            incomingPlayer?.pause()
            incomingPlayer?.replaceCurrentItem(with: nil)
            Log.audio.info("Crossfade cancelled")
        }

        outgoingPlayer = nil
        incomingPlayer = nil
        isCrossfading = false
        onCrossfadeComplete = nil
    }

    /// Cleans up the outgoing player after crossfade completes.
    /// Called by AudioEngine after it has swapped player references.
    func cleanupOutgoingPlayer() {
        outgoingPlayer?.pause()
        outgoingPlayer?.replaceCurrentItem(with: nil)
        outgoingPlayer = nil
        incomingPlayer = nil
    }

    // MARK: - Private

    private func updateFade() {
        guard let startTime = fadeStartTime else {
            cancelFade()
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / fadeDuration, 1.0)

        // Linear fade curve
        let outVolume = targetVolume * Float(1.0 - progress)
        let inVolume = targetVolume * Float(progress)

        outgoingPlayer?.volume = outVolume
        incomingPlayer?.volume = inVolume

        if progress >= 1.0 {
            // Crossfade complete
            fadeTimer?.invalidate()
            fadeTimer = nil
            fadeStartTime = nil
            isCrossfading = false

            outgoingPlayer?.volume = 0.0
            incomingPlayer?.volume = targetVolume

            Log.audio.info("Crossfade complete")
            onCrossfadeComplete?()
            onCrossfadeComplete = nil
        }
    }
}
