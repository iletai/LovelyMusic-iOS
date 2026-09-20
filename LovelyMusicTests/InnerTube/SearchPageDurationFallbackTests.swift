import XCTest

@testable import LovelyMusic

/// Regression coverage for two YouTube Music search-result quirks:
///   1. Duration occasionally arrives as the trailing run of the subtitle
///      column (`flexColumns[1]`) instead of in `fixedColumns[0]`.
///   2. Greyed-out (geo-restricted / deleted / premium-locked) tracks are
///      flagged via `musicItemRendererDisplayPolicy` and must be filtered
///      at the mapper boundary.
final class SearchPageDurationFallbackTests: XCTestCase {

    // MARK: - Helpers

    private func makeWatchEndpoint(videoId: String) -> NavigationEndpoint {
        NavigationEndpoint(
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
    }

    private func makeFlexColumn(text: String) -> MusicResponsiveListItemRenderer.FlexColumn {
        let runs = Runs(runs: [Run(text: text, navigationEndpoint: nil)])
        return MusicResponsiveListItemRenderer.FlexColumn(
            musicResponsiveListItemFlexColumnRenderer: .init(text: runs)
        )
    }

    private func makeSubtitleColumn(runs: [Run]) -> MusicResponsiveListItemRenderer.FlexColumn {
        MusicResponsiveListItemRenderer.FlexColumn(
            musicResponsiveListItemFlexColumnRenderer: .init(text: Runs(runs: runs))
        )
    }

    private func makeRenderer(
        title: String = "Song Title",
        subtitleRuns: [Run],
        videoId: String = "vid_abc",
        displayPolicy: String? = nil,
        fixedColumns: [MusicResponsiveListItemRenderer.FixedColumn]? = nil
    ) -> MusicResponsiveListItemRenderer {
        MusicResponsiveListItemRenderer(
            flexColumns: [makeFlexColumn(text: title), makeSubtitleColumn(runs: subtitleRuns)],
            fixedColumns: fixedColumns,
            thumbnail: nil,
            overlay: nil,
            navigationEndpoint: makeWatchEndpoint(videoId: videoId),
            playlistItemData: nil,
            badges: nil,
            musicItemRendererDisplayPolicy: displayPolicy
        )
    }

    // MARK: - Tests

    /// Duration parsed from the trailing run of `flexColumns[1]` when
    /// `fixedColumns` is absent (the common YouTube Music search shape).
    func testMapSongUsesFlexColumnDurationFallback() {
        let subtitle: [Run] = [
            Run(text: "Artist", navigationEndpoint: nil),
            Run(text: " • ", navigationEndpoint: nil),
            Run(text: "Album", navigationEndpoint: nil),
            Run(text: " • ", navigationEndpoint: nil),
            Run(text: "3:45", navigationEndpoint: nil),
        ]
        let renderer = makeRenderer(subtitleRuns: subtitle, fixedColumns: nil)

        let song = SearchResponseMapper.mapSong(from: renderer)

        XCTAssertNotNil(song)
        XCTAssertEqual(song?.duration, 225)
        XCTAssertEqual(song?.title, "Song Title")
    }

    /// `fixedColumns` still wins when present (no behavioural regression for
    /// the legacy shape).
    func testMapSongPrefersFixedColumnDuration() {
        let subtitle: [Run] = [
            Run(text: "Artist", navigationEndpoint: nil),
            Run(text: " • ", navigationEndpoint: nil),
            Run(text: "9:99", navigationEndpoint: nil),
        ]
        let fixed = MusicResponsiveListItemRenderer.FixedColumn(
            musicResponsiveListItemFixedColumnRenderer: .init(
                text: Runs(runs: [Run(text: "2:30", navigationEndpoint: nil)])
            )
        )
        let renderer = makeRenderer(subtitleRuns: subtitle, fixedColumns: [fixed])

        let song = SearchResponseMapper.mapSong(from: renderer)

        XCTAssertEqual(song?.duration, 150)
    }

    /// `mapSong` keeps working when the new policy field is absent
    /// (non-regression for items without `musicItemRendererDisplayPolicy`).
    func testMapSongSucceedsWhenDisplayPolicyIsNil() {
        let subtitle: [Run] = [Run(text: "Artist", navigationEndpoint: nil)]
        let renderer = makeRenderer(subtitleRuns: subtitle, displayPolicy: nil)

        let song = SearchResponseMapper.mapSong(from: renderer)

        XCTAssertNotNil(song)
        XCTAssertTrue(renderer.isPlayable)
    }

    /// Greyed-out renderers are reported as unplayable; any caller filtering
    /// on `isPlayable` will drop them before reaching the UI.
    func testIsPlayableFalseForGreyOutPolicy() {
        let subtitle: [Run] = [Run(text: "Artist", navigationEndpoint: nil)]
        let renderer = makeRenderer(
            subtitleRuns: subtitle,
            displayPolicy: "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
        )

        XCTAssertFalse(renderer.isPlayable)
        // mapSong itself does not enforce the filter (it is applied at the
        // response-loop boundary in mapResponse), but the helper exists and
        // is the contract used by the loops.
        XCTAssertNotNil(SearchResponseMapper.mapSong(from: renderer))
    }
}
