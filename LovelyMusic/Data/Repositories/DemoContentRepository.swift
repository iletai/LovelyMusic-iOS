import Foundation

/// Repository that serves bundled royalty-free demo content.
/// Used in review/demo mode to avoid YouTube InnerTube calls.
final class DemoContentRepository: InnerTubeRepositoryProtocol {

    private let catalog: DemoCatalog
    private let allSongs: [Song]
    private let allAlbums: [Album]
    private let allArtists: [Artist]

    init() {
        guard let url = Bundle.main.url(forResource: "demo_catalog", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONDecoder().decode(DemoCatalog.self, from: data)
        else {
            self.catalog = DemoCatalog(artists: [], albums: [], sections: [])
            self.allSongs = []
            self.allAlbums = []
            self.allArtists = []
            return
        }

        self.catalog = catalog
        let albums = catalog.albums.map { $0.toAlbum() }
        let songs = albums.flatMap(\.songs)
        self.allAlbums = albums
        self.allSongs = songs

        // Build artists with their songs and albums
        self.allArtists = catalog.artists.map { entry in
            let artistSongs = songs.filter { $0.artistId == entry.id }
            let artistAlbums = albums.filter { $0.artistId == entry.id }
            return entry.toArtist(songs: artistSongs, albums: artistAlbums)
        }
    }

    // MARK: - InnerTubeRepositoryProtocol

    func browseHome(params: String?) async throws -> HomeResult {
        print(
            "🎵 [DemoContentRepo] browseHome called, catalog has \(catalog.sections.count) sections")
        let sections = catalog.sections.map { section in
            let items = section.items.compactMap { $0.toMusicSectionItem() }
            return MusicSection(title: section.title, items: items)
        }
        return HomeResult(sections: sections, continuation: nil)
    }

    func search(query: String, filter: SearchFilter?) async throws -> SearchResult {
        let lowered = query.lowercased()

        let matchedSongs = allSongs.filter {
            $0.title.lowercased().contains(lowered)
                || $0.artistName.lowercased().contains(lowered)
                || ($0.albumName?.lowercased().contains(lowered) ?? false)
        }

        let matchedAlbums = allAlbums.filter {
            $0.title.lowercased().contains(lowered)
                || $0.artistName.lowercased().contains(lowered)
        }

        let matchedArtists = allArtists.filter {
            $0.name.lowercased().contains(lowered)
        }

        switch filter {
        case .songs:
            return SearchResult(
                songs: matchedSongs, albums: [], artists: [], playlists: [], continuation: nil)
        case .albums:
            return SearchResult(
                songs: [], albums: matchedAlbums, artists: [], playlists: [], continuation: nil)
        case .artists:
            return SearchResult(
                songs: [], albums: [], artists: matchedArtists, playlists: [], continuation: nil)
        case .playlists:
            return SearchResult(
                songs: [], albums: [], artists: [], playlists: [], continuation: nil)
        case nil:
            return SearchResult(
                songs: matchedSongs, albums: matchedAlbums, artists: matchedArtists, playlists: [],
                continuation: nil)
        }
    }

    func searchContinuation(token: String) async throws -> SearchResult {
        .empty
    }

    func searchSuggestions(query: String) async throws -> [String] {
        let lowered = query.lowercased()
        var suggestions: [String] = []

        for song in allSongs where song.title.lowercased().contains(lowered) {
            suggestions.append(song.title)
            if suggestions.count >= 5 { break }
        }
        for artist in allArtists where artist.name.lowercased().contains(lowered) {
            suggestions.append(artist.name)
            if suggestions.count >= 8 { break }
        }

        return suggestions.isEmpty
            ? ["Peaceful Moments", "Cinematic Intensity", "Retro Playful", "Kevin MacLeod"]
            : suggestions
    }

    func getStreamingData(videoId: String) async throws -> StreamingData {
        throw DemoError.streamingNotAvailable
    }

    func getArtist(browseId: String) async throws -> ArtistResult {
        guard let artist = allArtists.first(where: { $0.id == browseId }) else {
            throw DemoError.notFound
        }
        return ArtistResult(artist: artist, songsContinuation: nil)
    }

    func getAlbum(browseId: String) async throws -> AlbumResult {
        guard let album = allAlbums.first(where: { $0.id == browseId }) else {
            throw DemoError.notFound
        }
        return AlbumResult(album: album, songsContinuation: nil)
    }

    func getPlaylist(playlistId: String) async throws -> PlaylistResult {
        // Demo mode has no remote playlists — return empty
        let playlist = Playlist(
            id: playlistId,
            title: "Demo Playlist",
            thumbnailURL: nil,
            songCount: 0,
            songs: [],
            isLocal: false
        )
        return PlaylistResult(playlist: playlist, songsContinuation: nil)
    }

    func getNext(videoId: String?, playlistId: String?) async throws -> [Song] {
        // Return a shuffled subset of demo songs as "related" tracks
        return Array(allSongs.shuffled().prefix(10))
    }

    func browseContinuation(token: String) async throws -> Data {
        // No continuation in demo mode — return empty JSON object
        return "{}".data(using: .utf8) ?? Data()
    }

    func browseHomeContinuation(token: String) async throws -> HomeResult {
        HomeResult(sections: [], continuation: nil)
    }

    func browseShelfContinuation(token: String) async throws -> (
        songs: [Song], continuation: String?
    ) {
        (songs: [], continuation: nil)
    }
}

// MARK: - Demo Errors

enum DemoError: LocalizedError {
    case streamingNotAvailable
    case notFound

    var errorDescription: String? {
        switch self {
        case .streamingNotAvailable:
            return "Streaming is not available in demo mode."
        case .notFound:
            return "Content not found in demo catalog."
        }
    }
}
