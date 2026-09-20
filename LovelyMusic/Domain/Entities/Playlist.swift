import Foundation

struct Playlist: Identifiable, Hashable {
    let id: String
    var title: String
    let thumbnailURL: String?
    let songCount: Int?
    var description: String?
    var songs: [Song]
    let isLocal: Bool
    /// True when this playlist represents a YouTube Music podcast show.
    /// RustyPipe-aligned canonical reduction: `Podcast → Playlist{is_podcast:true}`.
    let isPodcast: Bool

    init(
        id: String = UUID().uuidString,
        title: String,
        thumbnailURL: String? = nil,
        songCount: Int? = nil,
        description: String? = nil,
        songs: [Song] = [],
        isLocal: Bool = true,
        isPodcast: Bool = false
    ) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.songCount = songCount
        self.description = description
        self.songs = songs
        self.isLocal = isLocal
        self.isPodcast = isPodcast
    }
}
