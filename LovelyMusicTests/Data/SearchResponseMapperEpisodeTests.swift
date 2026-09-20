import XCTest

@testable import LovelyMusic

/// S5.2 — Episode pageType detection on the Search side (TDD RED phase).
///
/// Mirrors `BrowseResponseMapperEpisodeTests` but exercises the shared
/// `SearchResponseMapper.mapSong(from:)` directly, since both Browse and
/// Search routes funnel `musicResponsiveListItemRenderer` rows through
/// this single mapper.
///
/// Detection contract (mapper must satisfy after impl lands):
///   A `musicResponsiveListItemRenderer` is an episode when EITHER
///     • `navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs
///        .browseEndpointContextMusicConfig.pageType
///        == "MUSIC_PAGE_TYPE_PODCAST_EPISODE"`, OR
///     • `navigationEndpoint.browseEndpoint.browseId` starts with `"MPED"`
///       (canonical episode browseId prefix per InnerTune reference).
///   Detected episodes emit a `Song` with `isEpisode == true` and
///   `episodeOf` populated from the show name (typically the first run of
///   `flexColumns[1]`). All other songs keep both fields at default
///   (false / nil).
///
/// EXPECTED RED MODE: tests fail to **compile** until `Song` gains the
/// `isEpisode` / `episodeOf` fields, and then fail at runtime until
/// `mapSong` learns the detection rule above.
final class SearchResponseMapperEpisodeTests: XCTestCase {

    // MARK: - Renderer builders (in-memory; no fixtures)

    private func makeFlex(text: String) -> MusicResponsiveListItemRenderer.FlexColumn {
        MusicResponsiveListItemRenderer.FlexColumn(
            musicResponsiveListItemFlexColumnRenderer: .init(
                text: Runs(runs: [Run(text: text, navigationEndpoint: nil)])
            )
        )
    }

    private func makeRenderer(
        title: String,
        showName: String,
        videoId: String,
        episodeBrowseId: String?,
        episodePageType: String?
    ) -> MusicResponsiveListItemRenderer {
        // Episodes carry navigationEndpoint.browseEndpoint (→ episode page),
        // and their videoId for playback lives in playlistItemData OR the
        // overlay's play button watch endpoint. We use playlistItemData for
        // simplicity — both shapes flow through `mapSong`'s videoId chain.
        let nav: NavigationEndpoint? = {
            guard let browseId = episodeBrowseId else { return nil }
            let cfg = BrowseEndpointContextMusicConfig(pageType: episodePageType)
            let supported = BrowseEndpointContextSupportedConfigs(
                browseEndpointContextMusicConfig: cfg
            )
            return NavigationEndpoint(
                watchEndpoint: nil,
                browseEndpoint: BrowseEndpoint(
                    browseId: browseId,
                    params: nil,
                    browseEndpointContextSupportedConfigs: supported
                ),
                searchEndpoint: nil,
                watchPlaylistEndpoint: nil
            )
        }()
        return MusicResponsiveListItemRenderer(
            flexColumns: [makeFlex(text: title), makeFlex(text: showName)],
            fixedColumns: nil,
            thumbnail: nil,
            overlay: nil,
            navigationEndpoint: nav,
            playlistItemData: .init(videoId: videoId, playlistSetVideoId: nil),
            badges: nil,
            musicItemRendererDisplayPolicy: nil
        )
    }

    private func makeRegularSongRenderer(
        title: String,
        artist: String,
        videoId: String
    ) -> MusicResponsiveListItemRenderer {
        // Regular song: watchEndpoint with videoId, no browseEndpoint.
        let nav = NavigationEndpoint(
            watchEndpoint: WatchEndpoint(
                videoId: videoId,
                playlistId: nil,
                playlistSetVideoId: nil,
                index: nil,
                params: nil,
                watchEndpointMusicSupportedConfigs: nil
            ),
            browseEndpoint: nil,
            searchEndpoint: nil,
            watchPlaylistEndpoint: nil
        )
        return MusicResponsiveListItemRenderer(
            flexColumns: [makeFlex(text: title), makeFlex(text: artist)],
            fixedColumns: nil,
            thumbnail: nil,
            overlay: nil,
            navigationEndpoint: nav,
            playlistItemData: nil,
            badges: nil,
            musicItemRendererDisplayPolicy: nil
        )
    }

    // MARK: - RED — pageType detection

    /// #1 RED — `pageType == MUSIC_PAGE_TYPE_PODCAST_EPISODE` flips the
    /// resulting Song to `isEpisode == true` and pulls the show name into
    /// `episodeOf`.
    func testMapSong_episodeByPageType_setsIsEpisodeAndEpisodeOf() {
        let renderer = makeRenderer(
            title: "Episode 42: The AI Beat",
            showName: "Hard Fork",
            videoId: "epVideoId01",
            episodeBrowseId: "UCgenericbrowseId",  // intentionally NOT MPED
            episodePageType: "MUSIC_PAGE_TYPE_PODCAST_EPISODE"
        )

        let song = SearchResponseMapper.mapSong(from: renderer)

        XCTAssertNotNil(song, "Episodes must still map to Song (they are playable).")
        XCTAssertEqual(song?.id, "epVideoId01")
        XCTAssertEqual(song?.title, "Episode 42: The AI Beat")
        XCTAssertTrue(
            song?.isEpisode ?? false,
            "pageType==MUSIC_PAGE_TYPE_PODCAST_EPISODE must set Song.isEpisode=true."
        )
        XCTAssertEqual(
            song?.episodeOf,
            "Hard Fork",
            "Show name (first run of flexColumns[1]) must populate episodeOf."
        )
    }

    /// #2 RED — Defensive fallback: canonical `MPED…` browseId prefix
    /// flips `isEpisode=true` even when `pageType` is missing. Mirrors the
    /// S5.1 `MPSP` fallback for podcasts.
    func testMapSong_episodeByMPEDBrowseIdPrefix_setsIsEpisodeTrue() {
        let renderer = makeRenderer(
            title: "Standalone Search Episode",
            showName: "Some Show",
            videoId: "epVideoId02",
            episodeBrowseId: "MPEDsomething",
            episodePageType: nil
        )

        let song = SearchResponseMapper.mapSong(from: renderer)

        XCTAssertNotNil(song)
        XCTAssertTrue(
            song?.isEpisode ?? false,
            "browseId prefix 'MPED' must set Song.isEpisode=true even with pageType=nil."
        )
        XCTAssertEqual(song?.episodeOf, "Some Show")
    }

    // MARK: - REGRESSION — non-episodes keep defaults

    /// #3 REGRESSION — A regular song (no browseEndpoint, no episode
    /// markers) MUST keep `isEpisode == false` and `episodeOf == nil`.
    /// Guards against false-positives that would mis-tag every search hit.
    func testMapSong_regularSong_keepsEpisodeDefaults() {
        let renderer = makeRegularSongRenderer(
            title: "Regular Banger",
            artist: "Some Artist",
            videoId: "regVideoId1"
        )

        let song = SearchResponseMapper.mapSong(from: renderer)

        XCTAssertNotNil(song)
        XCTAssertFalse(
            song?.isEpisode ?? true,
            "Plain songs (watchEndpoint only) must keep isEpisode=false."
        )
        XCTAssertNil(
            song?.episodeOf,
            "Plain songs must keep episodeOf=nil."
        )
    }
}
