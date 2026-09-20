import Foundation

@MainActor @Observable
final class PlaybackProgress {
    private let audioEngine: AudioEngine

    var progress: Double {
        guard audioEngine.duration > 0 else { return 0 }
        return audioEngine.currentTime / audioEngine.duration
    }

    var currentTime: TimeInterval { audioEngine.currentTime }
    var duration: TimeInterval { audioEngine.duration }

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }
}
