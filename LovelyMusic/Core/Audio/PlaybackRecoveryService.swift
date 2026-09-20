import Foundation
import os

enum PlaybackRecoveryEvent: Equatable, Sendable {
    case stallDetected(trackID: String, position: TimeInterval)
}

@MainActor
protocol PlaybackRecoveryClock: AnyObject {
    var now: TimeInterval { get }
}

@MainActor
protocol PlaybackRecoveryScheduling: AnyObject {
    func scheduleRepeating(
        every interval: TimeInterval,
        _ check: @escaping @MainActor () -> Void
    )
    func cancelRepeating()
    func sleep(for interval: TimeInterval) async throws
}

@MainActor
private final class SystemPlaybackRecoveryClock: PlaybackRecoveryClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
private final class SystemPlaybackRecoveryScheduler: PlaybackRecoveryScheduling {
    private var timer: Timer?

    func scheduleRepeating(
        every interval: TimeInterval,
        _ check: @escaping @MainActor () -> Void
    ) {
        cancelRepeating()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            _ in
            Task { @MainActor in check() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelRepeating() {
        timer?.invalidate()
        timer = nil
    }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}

/// Delegate protocol that provides PlaybackRecoveryService access to the
/// audio engine state it needs without creating a direct dependency.
@MainActor
protocol PlaybackRecoveryDelegate: AnyObject {
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var currentTrackID: String? { get }
    var streamURLResolver: ((String) async throws -> (url: String, contentLength: Int64?))? { get }
    func resumePlayer()
    func next()
    func performRecoveryLoadAndPlay(song: Song)
    func updateRetryState(song: Song, streamURL: String, contentLength: Int64?)
}

/// Handles playback stall detection and automatic retry/recovery.
/// Extracted from AudioEngine to isolate failure-recovery concerns.
@MainActor
@Observable
final class PlaybackRecoveryService {
    // MARK: - State

    private(set) var hasAttemptedRetry: Bool = false
    private var lastObservedTime: TimeInterval = 0
    private var lastTimeChangeInstant: TimeInterval = 0

    // MARK: - Dependencies

    weak var delegate: PlaybackRecoveryDelegate?
    private let clock: any PlaybackRecoveryClock
    private let scheduler: any PlaybackRecoveryScheduling
    private let eventSink: @MainActor (PlaybackRecoveryEvent) -> Void

    init(
        clock: (any PlaybackRecoveryClock)? = nil,
        scheduler: (any PlaybackRecoveryScheduling)? = nil,
        eventSink: @escaping @MainActor (PlaybackRecoveryEvent) -> Void = { _ in }
    ) {
        self.clock = clock ?? SystemPlaybackRecoveryClock()
        self.scheduler = scheduler ?? SystemPlaybackRecoveryScheduler()
        self.eventSink = eventSink
    }

    // MARK: - Lifecycle

    func resetRetry() {
        hasAttemptedRetry = false
    }

    deinit {
        MainActor.assumeIsolated {
            self.scheduler.cancelRepeating()
        }
    }

    // MARK: - Retry

    func retryPlayback(for song: Song) {
        hasAttemptedRetry = true

        guard let delegate, let resolver = delegate.streamURLResolver else {
            delegate?.updateRetryState(song: song, streamURL: "", contentLength: nil)
            Log.audio.error("No stream URL resolver available for retry")
            return
        }

        Task { [weak self, weak delegate] in
            guard let self, let delegate else { return }
            Log.audio.info("Retry: Re-resolving stream URL for: \(song.id, privacy: .public)")
            do {
                let result = try await resolver(song.id)
                // Guard: if user skipped to a different song during resolve, discard stale result
                guard delegate.currentTrackID == song.id else {
                    Log.audio.info("Retry: Song changed during resolve, discarding result for \(song.id, privacy: .public)")
                    return
                }
                Log.audio.info("Retry: Got fresh stream URL: \(result.url.prefix(80), privacy: .public)...")
                var retrySong = song
                retrySong.streamURL = result.url
                retrySong.streamContentLength = result.contentLength
                delegate.updateRetryState(
                    song: retrySong,
                    streamURL: result.url,
                    contentLength: result.contentLength
                )
                delegate.performRecoveryLoadAndPlay(song: retrySong)
            } catch {
                delegate.updateRetryState(song: song, streamURL: "", contentLength: nil)
                Log.audio.error("Retry failed for \(song.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Stall Detection

    func startStallDetection() {
        stopStallDetection()
        lastObservedTime = delegate?.currentTime ?? 0
        lastTimeChangeInstant = clock.now
        scheduler.scheduleRepeating(every: 5) { [weak self] in
            self?.checkForStall()
        }
    }

    func stopStallDetection() {
        scheduler.cancelRepeating()
    }

    private func checkForStall() {
        guard let delegate else { return }
        let currentTime = delegate.currentTime

        guard delegate.isPlaying, !delegate.isBuffering else {
            lastObservedTime = currentTime
            lastTimeChangeInstant = clock.now
            return
        }

        // At EOF (partial file ended) — not a network stall, skip recovery.
        let dur = delegate.duration
        if dur > 0, currentTime >= dur - 1.0 { return }

        if abs(currentTime - lastObservedTime) < 0.1 {
            if clock.now - lastTimeChangeInstant > 10 {
                Log.audio.warning(
                    "Stall detected: currentTime stuck at \(currentTime) for 10+ seconds"
                )
                handleStall()
            }
        } else {
            lastObservedTime = currentTime
            lastTimeChangeInstant = clock.now
        }
    }

    private func handleStall() {
        guard let delegate, let trackID = delegate.currentTrackID else { return }
        lastTimeChangeInstant = clock.now
        eventSink(
            .stallDetected(trackID: trackID, position: delegate.currentTime)
        )
    }
}
