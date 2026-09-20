import Foundation

struct Song: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let artistName: String
    let artistId: String?
    let albumName: String?
    let albumId: String?
    let duration: Int?
    let thumbnailURL: String?
    var isExplicit: Bool = false
    var musicVideoType: String?
    var isEpisode: Bool = false
    var episodeOf: String?
    var streamURL: String?
    var streamContentLength: Int64?

    // Exclude transient stream data from persistence — URLs expire after ~6h.
    private enum CodingKeys: String, CodingKey {
        case id, title, artistName, artistId, albumName, albumId
        case duration, thumbnailURL, isExplicit, musicVideoType
        case isEpisode, episodeOf
    }

    var isVideo: Bool {
        guard let musicVideoType else { return false }
        // Only OMV (Original Music Video) and UGC (User Generated Content) have actual video.
        // ATV (Album Track Video) is audio-only with static album art.
        return musicVideoType == "MUSIC_VIDEO_TYPE_OMV"
            || musicVideoType == "MUSIC_VIDEO_TYPE_UGC"
    }

    var formattedDuration: String {
        guard let duration else { return "--:--" }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Format an arbitrary number of seconds as m:ss (used for share timestamps)
    static func formatTimestamp(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - YouTube URLs

    /// Whether this song has a valid YouTube origin (vs local-only)
    var hasYouTubeOrigin: Bool {
        // YouTube video IDs are exactly 11 chars: [A-Za-z0-9_-]
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// YouTube Music URL for sharing (nil if not a YouTube song)
    var youtubeURL: URL? {
        guard hasYouTubeOrigin else { return nil }
        return URL(string: "https://music.youtube.com/watch?v=\(id)")
    }

    /// YouTube Music URL with timestamp for sharing (nil if not a YouTube song)
    func youtubeURL(atSecond second: Int) -> URL? {
        guard hasYouTubeOrigin else { return nil }
        return URL(string: "https://music.youtube.com/watch?v=\(id)&t=\(second)s")
    }
}
