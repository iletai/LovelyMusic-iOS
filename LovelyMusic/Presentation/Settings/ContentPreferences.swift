import Foundation

struct ContentPreferences {
    private static let defaults = UserDefaults.standard

    static var hidesExplicitContent: Bool {
        defaults.bool(forKey: "hideExplicitContent")
    }

    static func filteredSongs(_ songs: [Song]) -> [Song] {
        guard hidesExplicitContent else { return songs }
        return songs.filter { !$0.isExplicit }
    }

    static func filtered(_ result: SearchResult) -> SearchResult {
        SearchResult(
            songs: filteredSongs(result.songs),
            albums: result.albums,
            artists: result.artists,
            playlists: result.playlists,
            continuation: result.continuation
        )
    }

    static func filtered(_ sections: [MusicSection]) -> [MusicSection] {
        sections.compactMap { filtered($0) }
    }

    static func filtered(_ section: MusicSection) -> MusicSection? {
        guard hidesExplicitContent else { return section }

        let filteredItems = section.items.compactMap { item -> MusicSectionItem? in
            if case .song(let song) = item, song.isExplicit {
                return nil
            }
            return item
        }

        guard !filteredItems.isEmpty else { return nil }
        return MusicSection(title: section.title, items: filteredItems)
    }
}
