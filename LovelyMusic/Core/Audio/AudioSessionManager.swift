import AVFoundation
import os

enum AudioSessionManager {
    static var onResume: (@MainActor @Sendable () -> Void)?

    /// Configure the audio session category at app launch.
    ///
    /// Apple recommends configuring the category early but **activating lazily**
    /// (just before playback begins). Activating at launch with no audio to play
    /// leaves the session "active but silent", which can prevent iOS from binding
    /// the app as the current Now Playing app on first play (see F1 in
    /// `nowplaying-investigation.md`).
    static func setCategory() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            Log.audioSession.error("setCategory failed: \(error, privacy: .public)")
        }
    }

    /// Activate the audio session immediately before `AVPlayer.rate = 1.0`.
    ///
    /// Idempotent: calling on an already-active session is a no-op. Activation
    /// errors are logged but do not throw — `AVPlayer` will surface its own
    /// playback failure if the session genuinely cannot become active.
    static func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            Log.audioSession.info("Audio session activated for playback")
        } catch {
            Log.audioSession.error("Activation failed: \(error, privacy: .public)")
        }
    }

    static func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            break  // Handled by AudioEngine
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                Task { @MainActor in
                    onResume?()
                }
            }
        @unknown default:
            break
        }
    }
}
