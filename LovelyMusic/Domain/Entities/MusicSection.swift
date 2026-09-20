import Foundation

struct MusicSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let items: [MusicSectionItem]

    var isSongSection: Bool {
        let songCount = items.filter {
            if case .song = $0 { return true }
            return false
        }.count
        return songCount > items.count / 2 && songCount >= 2
    }
}

enum MusicSectionItem: Identifiable, Hashable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case audiobook(Audiobook)
    case userChannel(UserChannel)

    var id: String {
        switch self {
        case .song(let s): return "song-\(s.id)"
        case .album(let a): return "album-\(a.id)"
        case .artist(let a): return "artist-\(a.id)"
        case .playlist(let p): return "playlist-\(p.id)"
        case .audiobook(let a): return "audiobook-\(a.id)"
        case .userChannel(let u): return "userChannel-\(u.id)"
        }
    }
}
