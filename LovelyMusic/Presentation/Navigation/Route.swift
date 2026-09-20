import Foundation

enum Route: Hashable {
    case artist(browseId: String)
    case album(browseId: String)
    case playlist(playlistId: String)
    case homeSection(MusicSection)
    case likedSongs
    case downloads
    case settings
}

extension Notification.Name {
    static let navigateToArtist = Notification.Name("navigateToArtist")
    static let navigateToAlbum = Notification.Name("navigateToAlbum")
    static let switchToSearchTab = Notification.Name("switchToSearchTab")
}
