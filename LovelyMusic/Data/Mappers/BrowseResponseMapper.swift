import Foundation

enum BrowseResponseMapper {
    private static let decoder = JSONDecoder()

    // MARK: - Home

    static func mapHome(_ data: Data) throws -> HomeResult {
        let response = try decoder.decode(BrowseResponse.self, from: data)

        let sectionListRenderer =
            response.contents?.singleColumnBrowseResultsRenderer?
            .tabs?.first?.tabRenderer?.content?.sectionListRenderer
            ?? response.contents?.sectionListRenderer

        // Chip-filter responses (FEmusic_home + params) wrap sections in
        // `continuationContents.sectionListContinuation` rather than the
        // top-level envelope. Precedence: top-level wins when populated and
        // non-empty; otherwise fall through to the continuation envelope.
        // See doc/analysis/2026-05-04-home-chip-filter-empty/audit.md §H2.
        let topLevelContents = sectionListRenderer?.contents ?? []
        let continuationCont = response.continuationContents?.sectionListContinuation
        let sectionContents: [BrowseResponse.SectionContent]
        let continuation: String?
        if !topLevelContents.isEmpty {
            sectionContents = topLevelContents
            continuation = sectionListRenderer?.continuations?.token
        } else if let cont = continuationCont, !(cont.contents ?? []).isEmpty {
            sectionContents = cont.contents ?? []
            continuation = cont.continuations?.token
        } else {
            sectionContents = []
            continuation = sectionListRenderer?.continuations?.token
        }
        let sections = mapHomeSections(from: sectionContents)

        // Extract mood and genre chips from the explore carousel
        var moodAndGenres: [MoodAndGenre] = []
        for section in sectionContents {
            if let carousel = section.musicCarouselShelfRenderer {
                let moreButton = carousel.header?.musicCarouselShelfBasicHeaderRenderer?
                    .moreContentButton?.buttonRenderer?.navigationEndpoint?.browseEndpoint?.browseId
                if moreButton == "FEmusic_moods_and_genres" {
                    for content in carousel.contents ?? [] {
                        if let btn = content.musicNavigationButtonRenderer,
                            let title = btn.buttonText?.text,
                            let browseId = btn.clickCommand?.browseEndpoint?.browseId
                        {
                            let mood = MoodAndGenre(
                                id: browseId,
                                title: title,
                                color: btn.solid?.leftStripeColor,
                                browseEndpoint: .init(
                                    browseId: browseId,
                                    params: btn.clickCommand?.browseEndpoint?.params
                                )
                            )
                            moodAndGenres.append(mood)
                        }
                    }
                }
            }
        }

        // Extract chip cloud filters from the section list header
        let chips: [HomeChip] = (sectionListRenderer?.header?.chipCloudRenderer?.chips ?? [])
            .compactMap { chip in
                guard let renderer = chip.chipCloudChipRenderer,
                    let title = renderer.text?.text,
                    !title.isEmpty
                else { return nil }
                let params = renderer.navigationEndpoint?.browseEndpoint?.params
                return HomeChip(
                    id: title,
                    title: title,
                    params: params,
                    isSelected: renderer.isSelected ?? false
                )
            }

        return HomeResult(
            sections: sections, continuation: continuation, moodAndGenres: moodAndGenres,
            chips: chips)
    }

    private static func mapHomeSections(from contents: [BrowseResponse.SectionContent])
        -> [MusicSection]
    {
        return contents.compactMap { section -> MusicSection? in
            // Treat `musicImmersiveCarouselShelfRenderer` as an alias of the
            // standard carousel — same body schema, different key.
            if let carousel = section.musicCarouselShelfRenderer
                ?? section.musicImmersiveCarouselShelfRenderer
            {
                let title =
                    carousel.header?.musicCarouselShelfBasicHeaderRenderer?.title?.text
                    ?? "Untitled"
                let items = (carousel.contents ?? []).compactMap { mapCarouselItem($0) }
                guard !items.isEmpty else { return nil }
                return MusicSection(title: title, items: items)
            }

            if let shelf = section.musicShelfRenderer {
                let title = shelf.title?.text ?? "Untitled"
                let items: [MusicSectionItem] = (shelf.contents ?? []).compactMap { item in
                    if let multiRow = item.musicMultiRowListItemRenderer {
                        return mapMultiRowItem(multiRow)
                    }
                    guard let renderer = item.musicResponsiveListItemRenderer else { return nil }
                    return mapResponsiveListItem(renderer)
                }
                guard !items.isEmpty else { return nil }
                return MusicSection(title: title, items: items)
            }

            if let card = section.musicCardShelfRenderer {
                let title =
                    card.header?.musicCardShelfHeaderBasicRenderer?.title?.text
                    ?? card.title?.text
                    ?? "Untitled"

                // Items = hero (from card.onTap) + secondary rows (card.contents),
                // deduped by MusicSectionItem.id, hero first. Mirrors InnerTune
                // YouTube.kt#L106-L121 — the card's onTap surfaces the highlighted
                // hero, and `contents` carries the supporting list beneath it.
                var seenIds = Set<String>()
                var items: [MusicSectionItem] = []
                if let hero = mapCardShelfItem(card), seenIds.insert(hero.id).inserted {
                    items.append(hero)
                }
                for content in card.contents ?? [] {
                    guard let renderer = content.musicResponsiveListItemRenderer,
                        let mapped = mapResponsiveListItem(renderer)
                    else { continue }
                    if seenIds.insert(mapped.id).inserted {
                        items.append(mapped)
                    }
                }
                guard !items.isEmpty else { return nil }
                return MusicSection(title: title, items: items)
            }

            if let grid = section.gridRenderer {
                let items: [MusicSectionItem] = (grid.items ?? []).compactMap { gridItem in
                    guard let twoRow = gridItem.musicTwoRowItemRenderer else { return nil }
                    return mapTwoRowItem(twoRow)
                }
                guard !items.isEmpty else { return nil }
                return MusicSection(title: "Untitled", items: items)
            }

            if let playlistShelf = section.musicPlaylistShelfRenderer {
                let items: [MusicSectionItem] = (playlistShelf.contents ?? []).compactMap { item in
                    guard let renderer = item.musicResponsiveListItemRenderer else { return nil }
                    return mapResponsiveListItem(renderer)
                }
                guard !items.isEmpty else { return nil }
                return MusicSection(title: "Playlist", items: items)
            }

            // Skip musicDescriptionShelfRenderer and musicResponsiveHeaderRenderer
            // (not visual sections on home)
            return nil
        }
    }

    private static func mapCarouselItem(_ content: CarouselContent) -> MusicSectionItem? {
        if let twoRow = content.musicTwoRowItemRenderer {
            return mapTwoRowItem(twoRow)
        }
        if let listItem = content.musicResponsiveListItemRenderer {
            return mapResponsiveListItem(listItem)
        }
        return nil
    }

    private static func mapTwoRowItem(_ renderer: MusicTwoRowItemRenderer) -> MusicSectionItem? {
        let title = renderer.title?.text ?? ""
        let subtitle = renderer.subtitle?.text ?? ""
        let thumbnailURL = renderer.resolvedThumbnailURL

        let pageType = renderer.navigationEndpoint?.browseEndpoint?
            .browseEndpointContextSupportedConfigs?
            .browseEndpointContextMusicConfig?.pageType

        if let browseId = renderer.navigationEndpoint?.browseEndpoint?.browseId,
            !browseId.isEmpty
        {
            // Podcast check MUST precede the MUSIC_PAGE_TYPE_ALBUM/PLAYLIST/ARTIST
            // switch: inferPageType(from: "MPSP…") returns nil and would otherwise
            // fall to the default `.playlist` branch with isPodcast=false.
            // See review-merged §C1.
            if isPodcast(browseId: browseId, pageType: pageType) {
                let podcast = Playlist(
                    id: browseId,
                    title: title,
                    thumbnailURL: thumbnailURL,
                    description: subtitle,
                    isLocal: false,
                    isPodcast: true
                )
                return .playlist(podcast)
            }

            // Episode detection (S5.2) — mirrors `SearchResponseMapper.mapSong`.
            // MUST precede the pageType switch: `inferPageType("MPED…")` returns
            // nil and `MUSIC_PAGE_TYPE_PODCAST_EPISODE` is unhandled by the
            // switch, so without this hoist episodes fall through to `.playlist`.
            if browseId.hasPrefix("MPED")
                || pageType == "MUSIC_PAGE_TYPE_PODCAST_EPISODE"
            {
                let song = Song(
                    id: browseId,
                    title: title,
                    artistName: subtitle,
                    artistId: nil,
                    albumName: nil,
                    albumId: nil,
                    duration: nil,
                    thumbnailURL: thumbnailURL,
                    isEpisode: true,
                    episodeOf: subtitle
                )
                return .song(song)
            }

            let resolvedType = pageType ?? inferPageType(from: browseId)
            switch resolvedType {
            case "MUSIC_PAGE_TYPE_ALBUM":
                let album = Album(
                    id: browseId,
                    title: title,
                    artistName: subtitle,
                    artistId: nil,
                    year: nil,
                    thumbnailURL: thumbnailURL,
                    songs: []
                )
                return .album(album)

            case "MUSIC_PAGE_TYPE_ARTIST":
                let artist = Artist(
                    id: browseId,
                    name: title,
                    thumbnailURL: thumbnailURL,
                    subscriberCount: nil,
                    songs: [],
                    albums: [],
                    singles: []
                )
                return .artist(artist)

            case "MUSIC_PAGE_TYPE_AUDIOBOOK":
                let audiobook = Audiobook(
                    id: browseId,
                    title: title,
                    authorName: subtitle.isEmpty ? nil : subtitle,
                    thumbnailURL: thumbnailURL,
                    browseId: browseId
                )
                return .audiobook(audiobook)

            case "MUSIC_PAGE_TYPE_USER_CHANNEL":
                let channel = UserChannel(
                    id: browseId,
                    name: title,
                    thumbnailURL: thumbnailURL,
                    browseId: browseId
                )
                return .userChannel(channel)

            default:
                // Handles MUSIC_PAGE_TYPE_PLAYLIST and unknown page types
                let playlist = Playlist(
                    id: browseId,
                    title: title,
                    thumbnailURL: thumbnailURL,
                    isLocal: false
                )
                return .playlist(playlist)
            }
        }

        if let watchEndpoint = renderer.navigationEndpoint?.watchEndpoint,
            let videoId = watchEndpoint.videoId
        {
            let musicVideoType = watchEndpoint.watchEndpointMusicSupportedConfigs?
                .watchEndpointMusicConfig?.musicVideoType
            let song = Song(
                id: videoId,
                title: title,
                artistName: subtitle,
                artistId: nil,
                albumName: nil,
                albumId: nil,
                duration: nil,
                thumbnailURL: thumbnailURL,
                musicVideoType: musicVideoType
            )
            return .song(song)
        }

        // Fallback: item has title and thumbnail but no navigation endpoint
        // Still displayable in the home carousel
        if !title.isEmpty, thumbnailURL != nil {
            // Create a playlist-type item with empty ID — it renders but won't navigate
            // This handles promotional/featured content cards
            let playlist = Playlist(
                id: "",
                title: title,
                thumbnailURL: thumbnailURL,
                isLocal: false
            )
            return .playlist(playlist)
        }

        return nil
    }

    /// Maps a `musicMultiRowListItemRenderer` row (used in the home "Quick
    /// picks" shelf) to a domain item. Title is the primary text, subtitle is
    /// treated as the artist line, and `onTap` carries either a watch
    /// (videoId → song) or browse (browseId → album/artist/playlist) endpoint.
    private static func mapMultiRowItem(_ row: MusicMultiRowListItemRenderer) -> MusicSectionItem? {
        let title = row.title?.text ?? ""
        // Subtitle runs interleave artist/genre/year with separator runs
        // (` • `, ` & `). Per AGENTS.md §Runs Text Parsing oddElements
        // pattern, the artist lives at index 0; joining all runs leaks the
        // separator into artistName.
        let subtitle = joinSameFieldRuns(row.subtitle?.runs)
        let thumbnailURL = row.thumbnail?.resolvedThumbnails.last?.url

        if let videoId = row.onTap?.watchEndpoint?.videoId, !videoId.isEmpty {
            let musicVideoType = row.onTap?.watchEndpoint?
                .watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType
            let song = Song(
                id: videoId,
                title: title,
                artistName: subtitle,
                artistId: nil,
                albumName: nil,
                albumId: nil,
                duration: nil,
                thumbnailURL: thumbnailURL,
                musicVideoType: musicVideoType
            )
            return .song(song)
        }

        if let browseId = row.onTap?.browseEndpoint?.browseId, !browseId.isEmpty {
            let pageType =
                row.onTap?.browseEndpoint?
                .browseEndpointContextSupportedConfigs?
                .browseEndpointContextMusicConfig?.pageType
                ?? inferPageType(from: browseId)
            switch pageType {
            case "MUSIC_PAGE_TYPE_ALBUM":
                return .album(
                    Album(
                        id: browseId, title: title, artistName: subtitle,
                        artistId: nil, year: nil, thumbnailURL: thumbnailURL, songs: []
                    ))
            case "MUSIC_PAGE_TYPE_ARTIST":
                return .artist(
                    Artist(
                        id: browseId, name: title, thumbnailURL: thumbnailURL,
                        subscriberCount: nil, songs: [], albums: [], singles: []
                    ))
            case "MUSIC_PAGE_TYPE_AUDIOBOOK":
                return .audiobook(
                    Audiobook(
                        id: browseId, title: title,
                        authorName: subtitle.isEmpty ? nil : subtitle,
                        thumbnailURL: thumbnailURL, browseId: browseId
                    ))
            case "MUSIC_PAGE_TYPE_USER_CHANNEL":
                return .userChannel(
                    UserChannel(
                        id: browseId, name: title,
                        thumbnailURL: thumbnailURL, browseId: browseId
                    ))
            default:
                return .playlist(
                    Playlist(
                        id: browseId, title: title, thumbnailURL: thumbnailURL, isLocal: false
                    ))
            }
        }

        return nil
    }

    /// Maps a `musicCardShelfRenderer` (single highlighted card in the home
    /// feed) to one domain item, derived from the card's `onTap` endpoint.
    private static func mapCardShelfItem(_ card: MusicCardShelfRenderer) -> MusicSectionItem? {
        let title = card.title?.text ?? ""
        // See `mapMultiRowItem` — same separator-run leak applies to card
        // subtitles. Use the oddElements pattern.
        let subtitle = joinSameFieldRuns(card.subtitle?.runs)
        let thumbnailURL = card.thumbnail?.resolvedThumbnails.last?.url

        if let videoId = card.onTap?.watchEndpoint?.videoId, !videoId.isEmpty {
            let song = Song(
                id: videoId, title: title, artistName: subtitle, artistId: nil,
                albumName: nil, albumId: nil, duration: nil,
                thumbnailURL: thumbnailURL, musicVideoType: nil
            )
            return .song(song)
        }

        if let browseId = card.onTap?.browseEndpoint?.browseId, !browseId.isEmpty {
            let pageType =
                card.onTap?.browseEndpoint?
                .browseEndpointContextSupportedConfigs?
                .browseEndpointContextMusicConfig?.pageType
                ?? inferPageType(from: browseId)
            switch pageType {
            case "MUSIC_PAGE_TYPE_ALBUM":
                return .album(
                    Album(
                        id: browseId, title: title, artistName: subtitle,
                        artistId: nil, year: nil, thumbnailURL: thumbnailURL, songs: []
                    ))
            case "MUSIC_PAGE_TYPE_ARTIST":
                return .artist(
                    Artist(
                        id: browseId, name: title, thumbnailURL: thumbnailURL,
                        subscriberCount: nil, songs: [], albums: [], singles: []
                    ))
            case "MUSIC_PAGE_TYPE_AUDIOBOOK":
                return .audiobook(
                    Audiobook(
                        id: browseId, title: title,
                        authorName: subtitle.isEmpty ? nil : subtitle,
                        thumbnailURL: thumbnailURL, browseId: browseId
                    ))
            case "MUSIC_PAGE_TYPE_USER_CHANNEL":
                return .userChannel(
                    UserChannel(
                        id: browseId, name: title,
                        thumbnailURL: thumbnailURL, browseId: browseId
                    ))
            default:
                return .playlist(
                    Playlist(
                        id: browseId, title: title, thumbnailURL: thumbnailURL, isLocal: false
                    ))
            }
        }

        return nil
    }

    /// Joins consecutive even-indexed data runs across same-field
    /// separators (` & `, `, `, ` feat. `) and stops at field-changing
    /// separator markers. Returns `""` for nil/empty runs.
    ///
    /// Field-change markers (after trimming whitespace): `•`, `·`, `—` (em-dash),
    /// `–` (en-dash). Whitespace is trimmed via `.whitespacesAndNewlines` before
    /// comparison, which covers regular space, NBSP (`\u{00A0}`), and tabs —
    /// so variants like `" • "`, `"\u{00A0}•\u{00A0}"`, `" •"`, `"• "` all match.
    /// Same-field separators (`&`, `,`, `feat.`) are NOT in the marker set and
    /// continue to merge into the joined value.
    ///
    /// YouTube interleaves data runs with literal separator runs at odd
    /// offsets; data lives at even offsets (0, 2, 4...). A subtitle like
    /// `["Beyoncé", " & ", "Jay-Z", " • ", "2024"]` belongs to two fields
    /// (artists, year) — joining all evens would leak the year into the
    /// artist name. See AGENTS.md §"Runs Text Parsing" and InnerTune's
    /// group-aware subtitle parsing in `SearchSummaryPage.kt#L42-L66`.
    private static func joinSameFieldRuns(_ runs: [Run]?) -> String {
        guard let runs, !runs.isEmpty else { return "" }
        var parts: [String] = []
        var i = 0
        while i < runs.count {
            parts.append(runs[i].text)
            let sepIndex = i + 1
            guard sepIndex < runs.count else { break }
            if isFieldChangeSeparator(runs[sepIndex].text) { break }
            i += 2
        }
        return parts.joined(separator: ", ")
    }

    private static func isFieldChangeSeparator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers: Set<String> = ["•", "·", "—", "–"]
        return markers.contains(trimmed)
    }

    /// Shared `musicResponsiveListItemRenderer` → domain mapping chain used
    /// by both home shelves and card-shelf secondary contents. Strict song
    /// mapping first, then lenient, then album / artist / playlist fallbacks.
    private static func mapResponsiveListItem(
        _ renderer: MusicResponsiveListItemRenderer
    ) -> MusicSectionItem? {
        // Podcast detection MUST run first. Real YouTube podcast list items
        // expose 2 flexColumns (title + host), satisfying `mapAlbum`'s
        // `columns.count >= 2` guard, so without this hoist they get claimed
        // as `.album` before podcast routing has a chance. See review-merged
        // §"Consolidated remediation checklist" item 1 (Claude F1).
        let browseId = renderer.navigationEndpoint?.browseEndpoint?.browseId
        let pageType = renderer.navigationEndpoint?.browseEndpoint?
            .browseEndpointContextSupportedConfigs?
            .browseEndpointContextMusicConfig?.pageType
        if let id = browseId, !id.isEmpty,
            isPodcast(browseId: id, pageType: pageType)
        {
            let title =
                renderer.flexColumns?.first?
                .musicResponsiveListItemFlexColumnRenderer?.text?.text ?? ""
            let thumbnailURL = renderer.thumbnail?.resolvedThumbnails.last?.url
            return .playlist(
                Playlist(
                    id: id, title: title, thumbnailURL: thumbnailURL,
                    isLocal: false, isPodcast: true
                )
            )
        }
        if let song = SearchResponseMapper.mapSong(from: renderer) {
            return .song(song)
        }
        if let song = mapSongLenient(from: renderer) {
            return .song(song)
        }
        if let album = SearchResponseMapper.mapAlbum(from: renderer) {
            return .album(album)
        }
        // Playlist routing MUST precede the artist fallback: shelf-shape
        // tiles have 1 flexColumn + a browseId, which `mapArtist` would
        // otherwise claim regardless of pageType.
        if let id = browseId, !id.isEmpty,
            pageType == "MUSIC_PAGE_TYPE_PLAYLIST",
            let playlist = SearchResponseMapper.mapPlaylist(from: renderer)
        {
            return .playlist(playlist)
        }
        if let artist = SearchResponseMapper.mapArtist(from: renderer) {
            return .artist(artist)
        }
        if let playlist = SearchResponseMapper.mapPlaylist(from: renderer) {
            return .playlist(playlist)
        }
        return nil
    }

    /// Lenient song mapping for home feed — accepts items with fewer columns
    private static func mapSongLenient(from renderer: MusicResponsiveListItemRenderer) -> Song? {
        let columns = renderer.flexColumns ?? []
        guard !columns.isEmpty else { return nil }  // Only need 1 column (was: >= 2)

        let title = columns[0].musicResponsiveListItemFlexColumnRenderer?.text?.text ?? ""

        // Soft extraction of artist from column 1 if available
        let runs =
            columns.count >= 2
            ? (columns[1].musicResponsiveListItemFlexColumnRenderer?.text?.runs ?? [])
            : []
        let artistName = runs.first?.text ?? ""
        let artistId = runs.first?.navigationEndpoint?.browseEndpoint?.browseId

        // Album info (optional)
        let albumRun = runs.first(where: {
            $0.navigationEndpoint?.browseEndpoint?.browseEndpointContextSupportedConfigs?
                .browseEndpointContextMusicConfig?.pageType == "MUSIC_PAGE_TYPE_ALBUM"
        })
        let albumName = albumRun?.text
        let albumId = albumRun?.navigationEndpoint?.browseEndpoint?.browseId

        // videoId is still REQUIRED — can't play without it
        let videoId =
            renderer.playlistItemData?.videoId
            ?? renderer.overlay?.musicItemThumbnailOverlayRenderer?.content?
            .musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId
            ?? renderer.navigationEndpoint?.watchEndpoint?.videoId

        guard let id = videoId, !title.isEmpty else { return nil }

        let thumbnailURL = renderer.thumbnail?.resolvedThumbnails.last?.url
        let durationText = renderer.fixedColumns?.first?
            .musicResponsiveListItemFixedColumnRenderer?.text?.text
        let duration = SearchResponseMapper.parseDuration(durationText)

        let musicVideoType =
            renderer.overlay?.musicItemThumbnailOverlayRenderer?.content?
            .musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?
            .watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType
            ?? renderer.navigationEndpoint?.watchEndpoint?
            .watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType

        return Song(
            id: id,
            title: title,
            artistName: artistName,
            artistId: artistId,
            albumName: albumName,
            albumId: albumId,
            duration: duration,
            thumbnailURL: thumbnailURL,
            musicVideoType: musicVideoType
        )
    }

    /// Infers page type from browseId prefix when pageType is missing
    private static func inferPageType(from browseId: String) -> String? {
        if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK5") {
            return "MUSIC_PAGE_TYPE_ALBUM"
        } else if browseId.hasPrefix("UC") {
            return "MUSIC_PAGE_TYPE_ARTIST"
        } else if browseId.hasPrefix("VL") || browseId.hasPrefix("RD")
            || browseId.hasPrefix("PL")
        {
            return "MUSIC_PAGE_TYPE_PLAYLIST"
        }
        return nil
    }

    /// Detects whether a browse endpoint targets a Podcast show.
    /// Returns true when EITHER the canonical `MPSP` browseId prefix is
    /// present OR `pageType == MUSIC_PAGE_TYPE_PODCAST`. Per AGENTS.md
    /// (RustyPipe alignment), Podcast is reduced to `Playlist{isPodcast:true}`
    /// rather than introducing a new domain entity.
    private static func isPodcast(browseId: String?, pageType: String?) -> Bool {
        if let id = browseId, id.hasPrefix("MPSP") { return true }
        // Canonical RustyPipe-aligned constant
        // (ThetaDev/rustypipe url_endpoint.rs:228,270). Some payloads also
        // surface the shorter alias; accept both.
        if pageType == "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE" { return true }
        if pageType == "MUSIC_PAGE_TYPE_PODCAST" { return true }
        return false
    }

    // MARK: - Artist

    static func mapArtist(_ data: Data) throws -> ArtistResult {
        let response = try decoder.decode(BrowseResponse.self, from: data)

        let header = response.header
        let name =
            header?.musicImmersiveHeaderRenderer?.title?.text
            ?? header?.musicVisualHeaderRenderer?.title?.text ?? "Unknown"

        let thumbnailURL =
            header?.musicImmersiveHeaderRenderer?.thumbnail?.resolvedThumbnails.last?.url
            ?? header?.musicVisualHeaderRenderer?.thumbnail?.resolvedThumbnails.last?.url

        let subscriberCount = header?.musicImmersiveHeaderRenderer?
            .subscriptionButton?.subscribeButtonRenderer?.subscriberCountText?.text

        let artistDescription = header?.musicImmersiveHeaderRenderer?.description?.text

        var songs: [Song] = []
        var albums: [Album] = []
        var singles: [Album] = []
        var songsContinuation: String?

        let sections =
            response.contents?.singleColumnBrowseResultsRenderer?
            .tabs?.first?.tabRenderer?.content?.sectionListRenderer?.contents ?? []

        for section in sections {
            let sectionTitle =
                section.musicShelfRenderer?.title?.text
                ?? section.musicCarouselShelfRenderer?.header?
                .musicCarouselShelfBasicHeaderRenderer?.title?.text ?? ""
            let lowerTitle = sectionTitle.lowercased()

            if let shelf = section.musicShelfRenderer {
                for item in shelf.contents ?? [] {
                    if let renderer = item.musicResponsiveListItemRenderer,
                        let song = SearchResponseMapper.mapSong(from: renderer)
                    {
                        songs.append(song)
                    }
                }
                if lowerTitle.contains("song") || songsContinuation == nil {
                    songsContinuation = shelf.continuations?.token
                }
            }

            if let carousel = section.musicCarouselShelfRenderer {
                for content in carousel.contents ?? [] {
                    if let twoRow = content.musicTwoRowItemRenderer {
                        let album = mapTwoRowToAlbum(twoRow)
                        if lowerTitle.contains("single") {
                            singles.append(album)
                        } else if lowerTitle.contains("album") {
                            albums.append(album)
                        } else {
                            albums.append(album)
                        }
                    }
                    if let listItem = content.musicResponsiveListItemRenderer,
                        let song = SearchResponseMapper.mapSong(from: listItem)
                    {
                        songs.append(song)
                    }
                }
            }
        }

        let artist = Artist(
            id: "",
            name: name,
            thumbnailURL: thumbnailURL,
            subscriberCount: subscriberCount,
            description: artistDescription,
            songs: songs,
            albums: albums,
            singles: singles
        )
        return ArtistResult(artist: artist, songsContinuation: songsContinuation)
    }

    // MARK: - Album

    static func mapAlbum(_ data: Data) throws -> AlbumResult {
        let response = try decoder.decode(BrowseResponse.self, from: data)

        // Extract header — check two-column layout first, then single-column
        let twoColSections = response.contents?.twoColumnBrowseResultsRenderer?
            .tabs?.first?.tabRenderer?.content?.sectionListRenderer?.contents
        let twoColHeader = twoColSections?.first?.musicResponsiveHeaderRenderer

        let detailHeader = response.header?.musicDetailHeaderRenderer
        let title =
            twoColHeader?.title?.text
            ?? detailHeader?.title?.text ?? "Unknown"

        let subtitleRuns = twoColHeader?.subtitle?.runs ?? detailHeader?.subtitle?.runs ?? []
        let artistRun =
            subtitleRuns.first(where: {
                $0.navigationEndpoint?.browseEndpoint != nil
            }) ?? subtitleRuns.first
        let artistName = artistRun?.text ?? ""
        let artistId = artistRun?.navigationEndpoint?.browseEndpoint?.browseId

        let year = subtitleRuns.last?.text
        let thumbnailURL =
            twoColHeader?.thumbnail?.resolvedThumbnails.last?.url
            ?? detailHeader?.thumbnail?.resolvedThumbnails.last?.url
            ?? response.background?.resolvedThumbnails.last?.url

        let albumDescription = twoColHeader?.description?.text ?? detailHeader?.description?.text

        var songs: [Song] = []
        var songsContinuation: String?

        // Songs can come from two-column secondary contents or single-column tabs
        let sections: [BrowseResponse.SectionContent]
        if let secondary = response.contents?.twoColumnBrowseResultsRenderer?
            .secondaryContents?.sectionListRenderer?.contents
        {
            sections = secondary
        } else {
            sections =
                response.contents?.singleColumnBrowseResultsRenderer?
                .tabs?.first?.tabRenderer?.content?.sectionListRenderer?.contents ?? []
        }

        for section in sections {
            let shelf = section.musicShelfRenderer
            let playlistShelf = section.musicPlaylistShelfRenderer
            let shelfContents = shelf?.contents ?? playlistShelf?.contents

            if let contents = shelfContents {
                for (index, item) in contents.enumerated() {
                    if let renderer = item.musicResponsiveListItemRenderer {
                        let columns = renderer.flexColumns ?? []
                        let songTitle =
                            columns.first?
                            .musicResponsiveListItemFlexColumnRenderer?.text?.text
                            ?? "Track \(index + 1)"

                        let videoId =
                            renderer.playlistItemData?.videoId
                            ?? renderer.overlay?.musicItemThumbnailOverlayRenderer?.content?
                            .musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId

                        guard let id = videoId else { continue }

                        let durationText = renderer.fixedColumns?.first?
                            .musicResponsiveListItemFixedColumnRenderer?.text?.text
                        let duration = SearchResponseMapper.parseDuration(durationText)

                        let song = Song(
                            id: id,
                            title: songTitle,
                            artistName: artistName,
                            artistId: artistId,
                            albumName: title,
                            albumId: nil,
                            duration: duration,
                            thumbnailURL: thumbnailURL
                        )
                        songs.append(song)
                    }
                }
                songsContinuation =
                    shelf?.continuations?.token ?? playlistShelf?.continuations?.token
            }
        }

        let album = Album(
            id: "",
            title: title,
            artistName: artistName,
            artistId: artistId,
            year: year,
            thumbnailURL: thumbnailURL,
            description: albumDescription,
            songs: songs
        )
        return AlbumResult(album: album, songsContinuation: songsContinuation)
    }

    // MARK: - Playlist

    static func mapPlaylist(_ data: Data) throws -> PlaylistResult {
        let response = try decoder.decode(BrowseResponse.self, from: data)

        // Extract header info — response can use different layouts:
        // 1. Top-level header (singleColumnBrowseResultsRenderer)
        // 2. Two-column layout with header inside tab content (twoColumnBrowseResultsRenderer)
        let title: String
        let thumbnailURL: String?

        // Two-column layout: header is musicResponsiveHeaderRenderer inside first tab section
        let twoColSections = response.contents?.twoColumnBrowseResultsRenderer?
            .tabs?.first?.tabRenderer?.content?.sectionListRenderer?.contents
        let twoColHeader = twoColSections?.first?.musicResponsiveHeaderRenderer

        // Single-column layout: header is at top level
        let detailHeader =
            response.header?.musicDetailHeaderRenderer
            ?? response.header?.musicEditablePlaylistDetailHeaderRenderer?.header?
            .musicDetailHeaderRenderer
        let immersiveHeader = response.header?.musicImmersiveHeaderRenderer
        let responsiveHeader = response.header?.musicEditablePlaylistDetailHeaderRenderer?.header?
            .musicResponsiveHeaderRenderer

        title =
            twoColHeader?.title?.text
            ?? detailHeader?.title?.text
            ?? immersiveHeader?.title?.text
            ?? responsiveHeader?.title?.text
            ?? "Unknown"

        thumbnailURL =
            twoColHeader?.thumbnail?.resolvedThumbnails.last?.url
            ?? detailHeader?.thumbnail?.resolvedThumbnails.last?.url
            ?? immersiveHeader?.thumbnail?.resolvedThumbnails.last?.url
            ?? responsiveHeader?.thumbnail?.resolvedThumbnails.last?.url

        let playlistDescription =
            twoColHeader?.description?.text
            ?? responsiveHeader?.description?.text
            ?? detailHeader?.description?.text

        // Extract songs — two possible content sources:
        // 1. Two-column: secondaryContents.sectionListRenderer
        // 2. Single-column: singleColumnBrowseResultsRenderer tabs
        var songs: [Song] = []
        var songsContinuation: String?

        let songSections: [BrowseResponse.SectionContent]
        if let secondary = response.contents?.twoColumnBrowseResultsRenderer?
            .secondaryContents?.sectionListRenderer?.contents
        {
            songSections = secondary
        } else {
            songSections =
                response.contents?.singleColumnBrowseResultsRenderer?
                .tabs?.first?.tabRenderer?.content?.sectionListRenderer?.contents ?? []
        }

        for section in songSections {
            if let contents = section.musicShelfRenderer?.contents
                ?? section.musicPlaylistShelfRenderer?.contents
            {
                for item in contents {
                    if let renderer = item.musicResponsiveListItemRenderer,
                        let song = SearchResponseMapper.mapSong(from: renderer)
                    {
                        songs.append(song)
                    }
                }
                songsContinuation =
                    section.musicShelfRenderer?.continuations?.token
                    ?? section.musicPlaylistShelfRenderer?.continuations?.token
            } else if let carouselContents = section.musicCarouselShelfRenderer?.contents {
                for item in carouselContents {
                    if let renderer = item.musicResponsiveListItemRenderer,
                        let song = SearchResponseMapper.mapSong(from: renderer)
                    {
                        songs.append(song)
                    }
                }
            }
        }

        let playlist = Playlist(
            id: "",
            title: title,
            thumbnailURL: thumbnailURL,
            songCount: songs.count,
            description: playlistDescription,
            songs: songs,
            isLocal: false
        )
        return PlaylistResult(playlist: playlist, songsContinuation: songsContinuation)
    }

    // MARK: - Home Continuation

    static func mapHomeContinuation(_ data: Data) throws -> HomeResult {
        let response = try decoder.decode(BrowseResponse.self, from: data)

        if let sectionListCont = response.continuationContents?.sectionListContinuation {
            let sections = mapHomeSections(from: sectionListCont.contents ?? [])
            let continuation = sectionListCont.continuations?.token
            return HomeResult(sections: sections, continuation: continuation)
        }

        return HomeResult(sections: [], continuation: nil)
    }

    // MARK: - Shelf Continuation

    static func mapShelfContinuation(_ data: Data) throws -> (songs: [Song], continuation: String?)
    {
        let response = try decoder.decode(BrowseResponse.self, from: data)
        var songs: [Song] = []

        if let shelfCont = response.continuationContents?.musicShelfContinuation {
            for item in shelfCont.contents ?? [] {
                if let renderer = item.musicResponsiveListItemRenderer,
                    let song = SearchResponseMapper.mapSong(from: renderer)
                {
                    songs.append(song)
                }
            }
            return (songs, shelfCont.continuations?.token)
        } else if let playlistShelfCont = response.continuationContents?
            .musicPlaylistShelfContinuation
        {
            for item in playlistShelfCont.contents ?? [] {
                if let renderer = item.musicResponsiveListItemRenderer,
                    let song = SearchResponseMapper.mapSong(from: renderer)
                {
                    songs.append(song)
                }
            }
            return (songs, playlistShelfCont.continuations?.token)
        }
        return (songs, nil)
    }

    // MARK: - Helpers

    private static func mapTwoRowToAlbum(_ renderer: MusicTwoRowItemRenderer) -> Album {
        let title = renderer.title?.text ?? ""
        let subtitle = renderer.subtitle?.text ?? ""
        let browseId = renderer.navigationEndpoint?.browseEndpoint?.browseId ?? ""
        let thumbnailURL = renderer.resolvedThumbnailURL

        let subtitleRuns = renderer.subtitle?.runs ?? []
        let year = subtitleRuns.last?.text

        return Album(
            id: browseId,
            title: title,
            artistName: subtitle,
            artistId: nil,
            year: year,
            thumbnailURL: thumbnailURL,
            songs: []
        )
    }
}
