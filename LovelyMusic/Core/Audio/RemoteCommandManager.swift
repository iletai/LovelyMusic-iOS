import MediaPlayer

@MainActor
final class RemoteCommandManager {
    var onPlay: (@MainActor () -> Void)?
    var onPause: (@MainActor () -> Void)?
    var onNext: (@MainActor () -> Void)?
    var onPrevious: (@MainActor () -> Void)?
    var onSeek: (@MainActor (TimeInterval) -> Void)?
    var currentTime: (@MainActor () -> TimeInterval)?
    var duration: (@MainActor () -> TimeInterval)?

    func setup() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any previously registered targets to prevent accumulation
        // when setup() is called multiple times.
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPlay?()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPause?()
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onNext?()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPrevious?()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                if let event = event as? MPChangePlaybackPositionCommandEvent {
                    self?.onSeek?(event.positionTime)
                }
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let event = event as? MPSkipIntervalCommandEvent else {
                    return
                }
                let current = self.currentTime?() ?? 0
                let totalDuration = self.duration?() ?? 0
                let newPosition = current + event.interval
                if totalDuration > 0, newPosition >= totalDuration {
                    self.onNext?()
                } else {
                    self.onSeek?(max(newPosition, 0))
                }
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let event = event as? MPSkipIntervalCommandEvent else {
                    return
                }
                let current = self.currentTime?() ?? 0
                let totalDuration = self.duration?() ?? 0
                let newPosition = current - event.interval
                self.onSeek?(min(max(newPosition, 0), totalDuration))
            }
            return .success
        }
    }

    /// Removes all command center targets. Call on deallocation or when the
    /// manager is no longer needed to prevent leaked handler closures.
    func tearDown() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
    }
}
