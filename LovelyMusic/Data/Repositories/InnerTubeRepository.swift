import Foundation

final class InnerTubeRepository: InnerTubeRepositoryProtocol {
    private let api: InnerTubeAPI

    init(api: InnerTubeAPI) {
        self.api = api
    }

    func search(query: String, filter: SearchFilter?) async throws -> SearchResult {
        let data = try await api.search(
            query: query, params: filter.map { SearchFilterMapper.toParams($0) })
        return try SearchResponseMapper.map(data, filter: filter)
    }

    func searchContinuation(token: String) async throws -> SearchResult {
        let data = try await api.search(continuation: token)
        return try SearchResponseMapper.map(data)
    }

    func searchSuggestions(query: String) async throws -> [String] {
        let data = try await api.getSearchSuggestions(input: query)
        return try SuggestionsMapper.map(data)
    }

    func getStreamingData(videoId: String) async throws -> StreamingData {
        let data = try await api.player(videoId: videoId)
        let response = try JSONDecoder().decode(PlayerResponse.self, from: data)
        return StreamingDataMapper.map(response.streamingData)
    }

    func browseHome(params: String? = nil) async throws -> HomeResult {
        // Chip-filter requests are already curated variants of FEmusic_home and
        // must preserve their response/continuation contract unchanged.
        guard params == nil else {
            let data = try await api.browse(browseId: "FEmusic_home", params: params)
            return try BrowseResponseMapper.mapHome(data)
        }

        // The signed-out FEmusic_home feed can put old user-created playlists at
        // the top even when the response is fresh (maxAgeStoreSeconds == 0).
        // FEmusic_explore is YouTube Music's current/trending surface, so request
        // both in parallel and lead with its sections. Home remains authoritative
        // for chips, moods, and continuation pagination.
        async let homeData = api.browse(browseId: "FEmusic_home")
        async let exploreData: Data? = try? api.browse(browseId: "FEmusic_explore")

        let home = try BrowseResponseMapper.mapHome(try await homeData)
        let explore: HomeResult?
        if let data = await exploreData {
            explore = try? BrowseResponseMapper.mapHome(data)
        } else {
            explore = nil
        }

        return Self.mergeInitialHome(home: home, explore: explore)
    }

    /// Leads the initial Home screen with current/trending Explore sections while
    /// retaining all Home-only metadata and pagination. Exact duplicate section
    /// titles are removed stably, with Explore taking precedence.
    static func mergeInitialHome(home: HomeResult, explore: HomeResult?) -> HomeResult {
        guard let explore, !explore.sections.isEmpty else { return home }

        // YouTube's signed-out regional Home currently injects this shelf ahead
        // of its current charts. Its contents can be years old (for example,
        // "Hit 2019") despite a non-cacheable server response. Explore replaces
        // it with current/trending content, so do not keep the stale duplicate
        // experience lower in the merged feed. Keep the match deliberately
        // narrow and localized; all other Home shelves remain untouched.
        let genericCommunityPlaylistTitles: Set<String> = [
            "Danh sách phát thịnh hành trong cộng đồng người dùng",
            "Trending community playlists",
        ]
        let retainedHomeSections = home.sections.filter {
            !genericCommunityPlaylistTitles.contains($0.title)
        }

        var seenTitles = Set<String>()
        let sections = (explore.sections + retainedHomeSections).filter {
            seenTitles.insert($0.title).inserted
        }

        return HomeResult(
            sections: sections,
            continuation: home.continuation,
            moodAndGenres: home.moodAndGenres,
            chips: home.chips
        )
    }

    func getArtist(browseId: String) async throws -> ArtistResult {
        let data = try await api.browse(browseId: browseId)
        let result = try BrowseResponseMapper.mapArtist(data)
        let artist = Artist(
            id: browseId,
            name: result.artist.name,
            thumbnailURL: result.artist.thumbnailURL,
            subscriberCount: result.artist.subscriberCount,
            description: result.artist.description,
            songs: result.artist.songs,
            albums: result.artist.albums,
            singles: result.artist.singles
        )
        return ArtistResult(artist: artist, songsContinuation: result.songsContinuation)
    }

    func getAlbum(browseId: String) async throws -> AlbumResult {
        let data = try await api.browse(browseId: browseId)
        let result = try BrowseResponseMapper.mapAlbum(data)
        let album = Album(
            id: browseId,
            title: result.album.title,
            artistName: result.album.artistName,
            artistId: result.album.artistId,
            year: result.album.year,
            thumbnailURL: result.album.thumbnailURL,
            description: result.album.description,
            songs: result.album.songs
        )
        return AlbumResult(album: album, songsContinuation: result.songsContinuation)
    }

    func browseContinuation(token: String) async throws -> Data {
        return try await api.browse(continuation: token)
    }

    func browseHomeContinuation(token: String) async throws -> HomeResult {
        let data = try await api.browse(continuation: token)
        return try BrowseResponseMapper.mapHomeContinuation(data)
    }

    func browseShelfContinuation(token: String) async throws -> (
        songs: [Song], continuation: String?
    ) {
        let data = try await api.browse(continuation: token)
        return try BrowseResponseMapper.mapShelfContinuation(data)
    }

    func getPlaylist(playlistId: String) async throws -> PlaylistResult {
        let browseId: String
        if playlistId.hasPrefix("VL") {
            browseId = playlistId
        } else {
            browseId = "VL\(playlistId)"
        }
        let data = try await api.browse(browseId: browseId)
        let result = try BrowseResponseMapper.mapPlaylist(data)
        let playlist = Playlist(
            id: playlistId,
            title: result.playlist.title,
            thumbnailURL: result.playlist.thumbnailURL,
            songCount: result.playlist.songCount,
            description: result.playlist.description,
            songs: result.playlist.songs,
            isLocal: false,
            isPodcast: playlistId.hasPrefix("MPSP")
        )
        return PlaylistResult(playlist: playlist, songsContinuation: result.songsContinuation)
    }

    func getNext(videoId: String?, playlistId: String?) async throws -> [Song] {
        let data = try await api.next(videoId: videoId, playlistId: playlistId)
        return try NextResponseMapper.map(data)
    }
}
