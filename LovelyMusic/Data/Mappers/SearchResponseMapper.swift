import Foundation

// MARK: - Search Response Mapping

enum SearchResponseMapper {
    private static let decoder = JSONDecoder()

    static func map(_ data: Data, filter: SearchFilter? = nil) throws -> SearchResult {
        let response = try decoder.decode(SearchResponse.self, from: data)
        return mapResponse(response, filter: filter)
    }

    private static func mapResponse(_ response: SearchResponse, filter: SearchFilter? = nil)
        -> SearchResult
    {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        var continuation: String?

        let sections =
            response.contents?
            .tabbedSearchResultsRenderer?.tabs?.first?
            .tabRenderer?.content?.sectionListRenderer?.contents
            ?? response.contents?.sectionListRenderer?.contents ?? []

        for section in sections {
            if let shelf = section.musicShelfRenderer {
                continuation = shelf.continuations?.first?.token
                let items = shelf.contents ?? []
                let category = detectCategory(from: shelf.title?.text, filter: filter)

                for item in items {
                    guard let renderer = item.musicResponsiveListItemRenderer else { continue }
                    switch category {
                    case .songs:
                        guard renderer.isPlayable else { continue }
                        if let song = mapSong(from: renderer) { songs.append(song) }
                    case .albums:
                        if let album = mapAlbum(from: renderer) { albums.append(album) }
                    case .artists:
                        if let artist = mapArtist(from: renderer) { artists.append(artist) }
                    case .playlists:
                        if let playlist = mapPlaylist(from: renderer) { playlists.append(playlist) }
                    case .unknown:
                        guard renderer.isPlayable else { continue }
                        if let song = mapSong(from: renderer) { songs.append(song) }
                    }
                }
            }

            if let card = section.musicCardShelfRenderer {
                if let renderer = card.contents?.first?.musicResponsiveListItemRenderer,
                    renderer.isPlayable,
                    let song = mapSong(from: renderer)
                {
                    songs.append(song)
                }
            }
        }

        if let cont = response.continuationContents?.musicShelfContinuation {
            continuation = cont.continuations?.first?.token
            let contCategory =
                filter.map { f -> SearchCategory in
                    switch f {
                    case .songs: return .songs
                    case .albums: return .albums
                    case .artists: return .artists
                    case .playlists: return .playlists
                    }
                } ?? .songs
            for item in cont.contents ?? [] {
                guard let renderer = item.musicResponsiveListItemRenderer else { continue }
                switch contCategory {
                case .songs, .unknown:
                    guard renderer.isPlayable else { continue }
                    if let song = mapSong(from: renderer) { songs.append(song) }
                case .albums:
                    if let album = mapAlbum(from: renderer) { albums.append(album) }
                case .artists:
                    if let artist = mapArtist(from: renderer) { artists.append(artist) }
                case .playlists:
                    if let playlist = mapPlaylist(from: renderer) { playlists.append(playlist) }
                }
            }
        }

        return SearchResult(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            continuation: continuation
        )
    }

    static func mapSong(from renderer: MusicResponsiveListItemRenderer) -> Song? {
        let columns = renderer.flexColumns ?? []
        guard columns.count >= 2 else { return nil }

        let title = columns[0].musicResponsiveListItemFlexColumnRenderer?.text?.text ?? ""
        let runs = columns[1].musicResponsiveListItemFlexColumnRenderer?.text?.runs ?? []

        let artistRun = runs.first
        let artistName = artistRun?.text ?? ""
        let artistId = artistRun?.navigationEndpoint?.browseEndpoint?.browseId

        let albumRun = runs.first(where: {
            $0.navigationEndpoint?.browseEndpoint?.browseEndpointContextSupportedConfigs?
                .browseEndpointContextMusicConfig?.pageType == "MUSIC_PAGE_TYPE_ALBUM"
        })
        let albumName = albumRun?.text
        let albumId = albumRun?.navigationEndpoint?.browseEndpoint?.browseId

        let videoId =
            renderer.playlistItemData?.videoId
            ?? renderer.overlay?.musicItemThumbnailOverlayRenderer?.content?
            .musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId
            ?? renderer.navigationEndpoint?.watchEndpoint?.videoId

        guard let id = videoId, !title.isEmpty else { return nil }

        let thumbnailURL = renderer.thumbnail?.resolvedThumbnails.last?.url

        let durationText = renderer.fixedColumns?.first?
            .musicResponsiveListItemFixedColumnRenderer?.text?.text
        let duration: Int? = {
            if let parsed = parseDuration(durationText) { return parsed }
            // Fallback: YouTube Music sometimes places duration as the trailing run
            // of the subtitle column (e.g. "Artist • Album • 3:45").
            if let lastRun = runs.last?.text, let parsed = parseDuration(lastRun) {
                return parsed
            }
            return nil
        }()

        let isExplicit =
            renderer.badges?.contains(where: {
                $0.musicInlineBadgeRenderer?.icon?.iconType == "MUSIC_EXPLICIT_BADGE"
            }) ?? false

        let musicVideoType =
            renderer.overlay?.musicItemThumbnailOverlayRenderer?.content?
            .musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?
            .watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType
            ?? renderer.navigationEndpoint?.watchEndpoint?
            .watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType

        // Episode detection (S5.2): mirrors S5.1 podcast reduction. A row is
        // an episode when EITHER the canonical `MPED` browseId prefix is
        // present OR `pageType == MUSIC_PAGE_TYPE_PODCAST_EPISODE`.
        // Detected episodes surface as Song with `isEpisode=true` and the
        // show name (first run of flexColumns[1], which is also `artistName`)
        // promoted to `episodeOf`.
        let browseId = renderer.navigationEndpoint?.browseEndpoint?.browseId
        let pageType = renderer.navigationEndpoint?.browseEndpoint?
            .browseEndpointContextSupportedConfigs?
            .browseEndpointContextMusicConfig?.pageType
        let isEpisode =
            (browseId?.hasPrefix("MPED") ?? false)
            || pageType == "MUSIC_PAGE_TYPE_PODCAST_EPISODE"
        let episodeOf: String? = isEpisode ? artistName : nil

        return Song(
            id: id,
            title: title,
            artistName: artistName,
            artistId: artistId,
            albumName: albumName,
            albumId: albumId,
            duration: duration,
            thumbnailURL: thumbnailURL,
            isExplicit: isExplicit,
            musicVideoType: musicVideoType,
            isEpisode: isEpisode,
            episodeOf: episodeOf
        )
    }

    static func mapAlbum(from renderer: MusicResponsiveListItemRenderer) -> Album? {
        let columns = renderer.flexColumns ?? []
        guard columns.count >= 2 else { return nil }

        let title = columns[0].musicResponsiveListItemFlexColumnRenderer?.text?.text ?? ""
        let runs = columns[1].musicResponsiveListItemFlexColumnRenderer?.text?.runs ?? []

        let browseId = renderer.navigationEndpoint?.browseEndpoint?.browseId
        guard let id = browseId, !title.isEmpty else { return nil }

        let artistRun =
            runs.first(where: {
                $0.navigationEndpoint?.browseEndpoint?.browseEndpointContextSupportedConfigs?
                    .browseEndpointContextMusicConfig?.pageType == "MUSIC_PAGE_TYPE_ARTIST"
            }) ?? runs.first
        let artistName = artistRun?.text ?? ""
        let artistId = artistRun?.navigationEndpoint?.browseEndpoint?.browseId

        let year = runs.last?.text
        let thumbnailURL = renderer.thumbnail?.resolvedThumbnails.last?.url

        return Album(
            id: id,
            title: title,
            artistName: artistName,
            artistId: artistId,
            year: year,
            thumbnailURL: thumbnailURL,
            songs: []
        )
    }

    static func mapArtist(from renderer: MusicResponsiveListItemRenderer) -> Artist? {
        let columns = renderer.flexColumns ?? []
        guard !columns.isEmpty else { return nil }

        let name = columns[0].musicResponsiveListItemFlexColumnRenderer?.text?.text ?? ""
        let browseId = renderer.navigationEndpoint?.browseEndpoint?.browseId
        guard let id = browseId, !name.isEmpty else { return nil }

        let subscriberText =
            columns.count > 1
            ? columns[1].musicResponsiveListItemFlexColumnRenderer?.text?.text
            : nil

        let thumbnailURL = renderer.thumbnail?.resolvedThumbnails.last?.url

        return Artist(
            id: id,
            name: name,
            thumbnailURL: thumbnailURL,
            subscriberCount: subscriberText,
            songs: [],
            albums: [],
            singles: []
        )
    }

    static func mapPlaylist(from renderer: MusicResponsiveListItemRenderer) -> Playlist? {
        let columns = renderer.flexColumns ?? []
        guard !columns.isEmpty else { return nil }

        let title = columns[0].musicResponsiveListItemFlexColumnRenderer?.text?.text ?? ""
        let browseId = renderer.navigationEndpoint?.browseEndpoint?.browseId
        guard let id = browseId, !title.isEmpty else { return nil }

        let thumbnailURL = renderer.thumbnail?.resolvedThumbnails.last?.url

        return Playlist(
            id: id,
            title: title,
            thumbnailURL: thumbnailURL,
            isLocal: false
        )
    }

    // MARK: - Helpers

    private enum SearchCategory {
        case songs, albums, artists, playlists, unknown
    }

    private static func detectCategory(from title: String?, filter: SearchFilter? = nil)
        -> SearchCategory
    {
        if let title = title?.lowercased() {
            if title.contains("song") { return .songs }
            if title.contains("album") { return .albums }
            if title.contains("artist") { return .artists }
            if title.contains("playlist") || title.contains("community") { return .playlists }
        }
        // Fall back to the active filter when shelf title doesn't match
        if let filter {
            switch filter {
            case .songs: return .songs
            case .albums: return .albums
            case .artists: return .artists
            case .playlists: return .playlists
            }
        }
        return .unknown
    }

    static func parseDuration(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}
