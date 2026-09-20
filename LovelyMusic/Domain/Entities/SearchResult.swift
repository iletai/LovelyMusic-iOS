import Foundation

struct SearchResult {
    let songs: [Song]
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]
    let continuation: String?

    static let empty = SearchResult(songs: [], albums: [], artists: [], playlists: [], continuation: nil)
}

enum SearchFilter: CaseIterable {
    case songs
    case albums
    case artists
    case playlists

    var displayName: String {
        switch self {
        case .songs: return String(localized: "Songs")
        case .albums: return String(localized: "Albums")
        case .artists: return String(localized: "Artists")
        case .playlists: return String(localized: "Playlists")
        }
    }
}
