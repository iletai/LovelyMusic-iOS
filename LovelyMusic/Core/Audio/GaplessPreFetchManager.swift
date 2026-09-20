import AVFoundation
import Foundation
import os

/// Manages gapless playback by preparing an already-local next track while the
/// current one is still playing. Remote media is never fetched speculatively.
@MainActor
@Observable
final class GaplessPreFetchManager {
    // MARK: - Pre-fetch State

    /// The pre-fetched AVPlayerItem ready for gapless transition.
    private(set) var prefetchedPlayerItem: AVPlayerItem?
    /// The song ID of the pre-fetched item, used to match on `next()`.
    private(set) var prefetchedSongId: String?
    /// Local file URL of the pre-fetched (remuxed) audio.
    private(set) var prefetchedLocalFileURL: URL?

    // MARK: - Dependencies (set by AudioEngine)

    /// The current playback queue.
    var queue: [Song] = [] {
        didSet {
            guard oldValue.map(\.id) != queue.map(\.id) else { return }
            cancelPrefetch()
        }
    }
    /// Index of the currently playing track in `queue`.
    var currentIndex: Int = 0 {
        didSet {
            guard oldValue != currentIndex else { return }
            cancelPrefetch()
        }
    }
    /// Whether shuffle is enabled (prefetch disabled during shuffle).
    var shuffleEnabled: Bool = false {
        didSet {
            guard oldValue != shuffleEnabled else { return }
            cancelPrefetch()
        }
    }
    /// Repeat mode — affects whether prefetch wraps around.
    var repeatMode: AudioEngine.RepeatMode = .off {
        didSet {
            guard oldValue != repeatMode else { return }
            cancelPrefetch()
        }
    }
    /// Optional LRU cache manager for remuxed audio files.
    var audioCacheManager: AudioCacheManager?
    /// Optional download manager for offline playback lookup.
    var downloadManager: DownloadManager?

    // MARK: - Public API

    /// Clears any prepared local item.
    func cancelPrefetch() {
        prefetchedPlayerItem = nil
        prefetchedSongId = nil
        prefetchedLocalFileURL = nil
    }

    /// A local miss stays idle so a download/cache entry that appears later can be retried.
    var isIdle: Bool {
        prefetchedPlayerItem == nil
    }

    /// Starts pre-fetching the next track in the queue.
    func prefetchNextTrack() {
        // Determine next index without advancing playback state
        let nextIndex: Int
        if shuffleEnabled {
            return
        } else if currentIndex + 1 < queue.count {
            nextIndex = currentIndex + 1
        } else if repeatMode == .all {
            nextIndex = 0
        } else {
            return
        }

        let nextSong = queue[nextIndex]
        guard prefetchedSongId != nextSong.id else { return }

        cancelPrefetch()

        // Existing remuxes, explicit downloads, and bundled audio are safe to prepare
        // because AVURLAsset cannot start a remote transfer for these file URLs.
        if let cachedURL = audioCacheManager?.getFile(for: nextSong.id) {
            prepareLocalItem(for: nextSong, fileURL: cachedURL, source: "cache")
            return
        }
        if let downloadedURL = downloadManager?.localFileURL(songId: nextSong.id) {
            prepareLocalItem(for: nextSong, fileURL: downloadedURL, source: "downloads")
            return
        }
        if let bundledURL = Bundle.main.url(forResource: nextSong.id, withExtension: "m4a") {
            prepareLocalItem(for: nextSong, fileURL: bundledURL, source: "bundle")
        }
    }

    private func prepareLocalItem(for song: Song, fileURL: URL, source: String) {
        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        prefetchedPlayerItem = item
        prefetchedSongId = song.id
        prefetchedLocalFileURL = fileURL
        Log.audio.info("Pre-fetched from \(source, privacy: .public): \(song.title, privacy: .public)")
    }
}
