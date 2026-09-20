import Foundation

extension SleepTimerOption {
    var minutes: Int {
        switch self {
        case .off: return 0
        case .min15: return 15
        case .min30: return 30
        case .min45: return 45
        case .min60: return 60
        case .endOfTrack: return 0
        }
    }
}

@MainActor
@Observable
final class SleepTimerManager {
    private(set) var remainingSeconds: Int = 0
    private(set) var isActive: Bool = false
    private(set) var selectedOption: SleepTimerOption = .off

    private var timerTask: Task<Void, Never>?

    /// Called when the countdown reaches zero to pause audio.
    var onTimerExpired: (() -> Void)?

    var formattedRemaining: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func start(option: SleepTimerOption) {
        cancel()
        selectedOption = option

        guard option != .off else { return }

        // endOfTrack is handled externally (e.g. by PlayerViewModel on track end)
        guard option != .endOfTrack else {
            isActive = true
            return
        }

        let totalSeconds = option.minutes * 60
        guard totalSeconds > 0 else { return }

        remainingSeconds = totalSeconds
        isActive = true

        timerTask = Task { [weak self] in
            while let self, self.remainingSeconds > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.remainingSeconds -= 1
            }

            guard !Task.isCancelled, let self else { return }
            self.onTimerExpired?()
            self.cancel()
        }
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        isActive = false
        remainingSeconds = 0
        selectedOption = .off
    }
}
