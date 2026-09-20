import MediaPlayer
import UIKit

@MainActor
final class NowPlayingManager {
    private var artworkTask: Task<Void, Never>?
    private var currentSongId: String?
    private var artwork: MPMediaItemArtwork?

    /// Pre-rendered fallback artwork created at init time so iOS never receives
    /// a 0×0 `UIImage()` from a closure that races SF-symbol rendering on cold
    /// start (F4). Reused across all songs that lack a thumbnail.
    private let fallbackArtwork: MPMediaItemArtwork

    init() {
        self.fallbackArtwork = Self.makeFallbackArtwork()
    }

    private static func makeFallbackArtwork() -> MPMediaItemArtwork {
        let size = CGSize(width: 300, height: 300)
        let config = UIImage.SymbolConfiguration(pointSize: 200, weight: .regular)
        let symbol = UIImage(systemName: "music.note", withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let symbol {
                let symbolSize = symbol.size
                let origin = CGPoint(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2
                )
                symbol.draw(at: origin)
            }
        }
        return MPMediaItemArtwork(boundsSize: rendered.size) { _ in rendered }
    }

    func updateNowPlayingInfo(song: Song?, duration: TimeInterval) {
        artworkTask?.cancel()
        artworkTask = nil

        guard let song else {
            currentSongId = nil
            artwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        currentSongId = song.id
        artwork = nil

        setNowPlayingInfo(song: song, duration: duration, artwork: fallbackArtwork)

        guard let thumbnailURL = song.thumbnailURL, let url = URL(string: thumbnailURL) else {
            return
        }

        let songId = song.id
        artworkTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, currentSongId == songId else { return }
                if let image = UIImage(data: data) {
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    setNowPlayingInfo(song: song, duration: duration, artwork: self.artwork)
                }
            } catch {
                // Artwork is optional — keep fallback
            }
        }
    }

    func updatePlaybackState(isPlaying: Bool, currentTime: TimeInterval, rate: Double) {
        // Guard against writing playback-state-only updates before the first
        // full `setNowPlayingInfo`. iOS rejects/garbles dictionaries that lack
        // title/artist (F7).
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              info[MPMediaItemPropertyTitle] != nil
        else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setNowPlayingInfo(song: Song, duration: TimeInterval, artwork: MPMediaItemArtwork?) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artistName
        info[MPMediaItemPropertyAlbumTitle] = song.albumName
        // Omit duration when unknown so iOS doesn't classify the track as a
        // live stream of unknown length (F2). iOS will refresh once we write
        // again with a real duration.
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        // Deterministic media-type classification so CarPlay picks the right
        // template behavior (F6).
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
