import AVFoundation
import Foundation
import os

/// Manages video playback as a separate AVPlayer layer, muted and synced
/// with the main audio player. Extracted from AudioEngine to reduce its
/// responsibility count.
@MainActor
@Observable
final class VideoPlaybackManager {
    // MARK: - Public State

    enum VideoLoadState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable
        case failed(String)
    }

    private(set) var isVideoMode: Bool = false
    private(set) var videoLoadState: VideoLoadState = .idle
    private(set) var videoPlayerItem: AVPlayerItem?
    /// The AVPlayer instance used for video streaming (separate from audio player)
    private(set) var videoPlayer: AVPlayer?

    // MARK: - Dependencies (injected by AudioEngine)

    /// Resolves a song ID to a video stream URL + optional content length.
    var videoStreamURLResolver: ((String) async throws -> (url: String, contentLength: Int64?)?)?

    /// HTTP headers to attach to the video stream request.
    var streamHeaders: [String: String] = [:]

    /// Whether the main audio player is currently playing (used to sync video).
    var isPlaying: Bool = false

    /// Defensive secondary guard against `Task.isCancelled` propagation latency
    /// across `await MainActor.run` hops. Even though `currentTask?.cancel()`
    /// has been called, a body that began awaiting before the cancel landed
    /// may observe `Task.isCancelled == false` momentarily on resume and
    /// reach the assignment block; the token equality check then rejects it.
    private var loadToken: Int = 0

    /// In-flight load task. Cancelled (and replaced) on every new
    /// `loadVideoStream(for:)` call so superseded loads do not assign
    /// `videoPlayerItem` or emit success log lines.
    private var currentTask: Task<Void, Never>?

    #if DEBUG
        /// Test-only audit trail of stream URLs that successfully passed the
        /// cancellation/token guards and reached the `videoPlayerItem`
        /// assignment block. Lets tests assert *causally* that a superseded
        /// load was rejected, instead of relying on the timing-sensitive
        /// observation that `videoPlayerItem` is still `nil`.
        internal private(set) var assignedStreamURLsForTesting: [String] = []
    #endif

    // MARK: - Public API

    func setVideoMode(_ enabled: Bool) {
        isVideoMode = enabled
        if !enabled {
            videoLoadState = .idle
            cleanupVideoPlayer()
        }
    }

    func loadVideoStream(for song: Song) {
        guard isVideoMode, let resolver = videoStreamURLResolver else { return }
        loadToken &+= 1
        let token = loadToken
        currentTask?.cancel()
        videoLoadState = .loading
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let result = try await resolver(song.id) else {
                    Log.audio.warning("No video stream available for \(song.id, privacy: .public)")
                    await MainActor.run {
                        guard token == self.loadToken else { return }
                        self.videoLoadState = .unavailable
                    }
                    return
                }
                // Bail out if a newer load superseded this one before the
                // network round-trip returned. Both the cancellation token
                // and `loadToken` are checked so cancelled tasks neither
                // assign `videoPlayerItem` nor emit a success log line.
                if Task.isCancelled { return }
                guard let streamURL = URL(string: result.url) else {
                    Log.audio.warning("Invalid video stream URL for \(song.id, privacy: .public)")
                    await MainActor.run {
                        guard token == self.loadToken else { return }
                        self.videoLoadState = .failed("Invalid stream URL")
                    }
                    return
                }
                let headers =
                    self.streamHeaders.isEmpty
                    ? AppConstants.youtubeStreamHeaders : self.streamHeaders
                let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
                let asset = AVURLAsset(url: streamURL, options: options)
                // Build a silent audio mix so the video asset's audio track
                // is never decoded — eliminates any chance of double audio
                // even if isMuted gets toggled by AVPlayerViewController or
                // an audio-route change (volume-button HUD, AirPods, etc.).
                let audioMix = await Self.makeSilentAudioMix(for: asset)
                if Task.isCancelled { return }
                let item = AVPlayerItem(asset: asset)
                item.audioMix = audioMix
                await MainActor.run {
                    // Discard if a newer load superseded this one.
                    guard !Task.isCancelled, token == self.loadToken, self.isVideoMode else {
                        return
                    }
                    #if DEBUG
                        self.assignedStreamURLsForTesting.append(result.url)
                    #endif
                    self.videoPlayerItem = item
                    self.videoLoadState = .loaded
                    if let vp = self.videoPlayer {
                        // Reuse existing AVPlayer — isMuted persists across
                        // replaceCurrentItem so no race window.
                        vp.isMuted = true
                        vp.replaceCurrentItem(with: item)
                    } else {
                        // Create-then-mute BEFORE play() to close the race
                        // window where AVPlayer(playerItem:) defaults isMuted
                        // to false and could emit a frame of audio.
                        let newPlayer = AVPlayer(playerItem: item)
                        newPlayer.isMuted = true
                        newPlayer.actionAtItemEnd = .pause
                        self.videoPlayer = newPlayer
                    }
                    if self.isPlaying {
                        self.videoPlayer?.play()
                    }
                    Log.audio.info(
                        "Video stream loaded: \(result.url.prefix(80), privacy: .public)...")
                }
            } catch {
                if !Task.isCancelled {
                    Log.audio.error("Failed to load video stream: \(error, privacy: .public)")
                    await MainActor.run {
                        guard token == self.loadToken else { return }
                        self.videoLoadState = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Mirror the audio engine's play/pause state onto the video layer.
    func setIsPlaying(_ playing: Bool) {
        isPlaying = playing
        guard isVideoMode, let vp = videoPlayer else { return }
        if playing {
            // Re-assert mute on every resume — defends against AVPlayerViewController
            // re-enabling audio when its view (re)appears, e.g. on fullscreen toggle.
            vp.isMuted = true
            vp.play()
        } else {
            vp.pause()
        }
    }

    /// Keep the video player frame-aligned with the audio player. Must be
    /// called whenever the audio engine seeks; otherwise the two streams
    /// drift apart and the gap is only visible once the user opens the
    /// fullscreen video viewer.
    func seek(to seconds: TimeInterval) {
        guard isVideoMode, let vp = videoPlayer else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        vp.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func cleanupVideoPlayer() {
        loadToken &+= 1  // invalidate any in-flight load Task
        currentTask?.cancel()
        currentTask = nil
        videoPlayer?.pause()
        videoPlayer?.replaceCurrentItem(with: nil)
        videoPlayer = nil
        videoPlayerItem = nil
    }

    // MARK: - Helpers

    /// Build an AVAudioMix that silences every audio track of the asset.
    /// This is a hard mute applied at the decode stage — independent of
    /// AVPlayer.isMuted — so AVPlayerViewController cannot un-mute us.
    private static func makeSilentAudioMix(for asset: AVURLAsset) async -> AVAudioMix? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return nil }
            let mix = AVMutableAudioMix()
            mix.inputParameters = tracks.map { track in
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(0, at: .zero)
                return params
            }
            return mix
        } catch {
            Log.audio.error(
                "Failed to load audio tracks for silent mix: \(error, privacy: .public)")
            return nil
        }
    }
}
