import XCTest

@testable import LovelyMusic

/// S5.1 — Podcast pageType → Playlist{isPodcast:true} (TDD RED phase).
///
/// Per the locked architectural decision (Option B), Podcast surfaces as
/// the existing `Playlist` entity with a new optional flag
/// `isPodcast: Bool = false`, mirroring RustyPipe's canonical
/// `Podcast → Playlist{is_podcast:true}` reduction. We do NOT introduce a
/// new `MusicSectionItem` case.
///
/// Detection contract (mapper must satisfy after impl lands):
///   A tile is a podcast when EITHER
///     • `browseEndpoint.browseId` starts with `"MPSP"`, OR
///     • `browseEndpointContextMusicConfig.pageType == "MUSIC_PAGE_TYPE_PODCAST"`.
///   Detected podcasts emit `.playlist(Playlist(..., isPodcast: true))`.
///   All other playlists keep `isPodcast == false` (default).
///
/// EXPECTED RED MODE (this commit): all five tests fail to **compile**
/// with `Value of type 'Playlist' has no member 'isPodcast'` because the
/// `isPodcast` field has not yet been added to the `Playlist` entity.
/// The implementer's next step is to add the field with default `false`;
/// regression tests #4 and #5 will then go GREEN automatically while
/// tests #1–#3 will still fail at runtime until the mapper learns the
/// detection contract above.
final class BrowseResponseMapperPodcastTests: XCTestCase {

    // MARK: - RED — podcast detection (twoRowItem)

    /// #1 RED — canonical browseId prefix `MPSP…` → isPodcast == true.
    func testTwoRowItem_podcastByBrowseIdPrefix_mapsToPlaylistWithIsPodcastTrue() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_podcast_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 1)

        guard case .playlist(let podcast) = section.items[0] else {
            return XCTFail("Expected .playlist; got \(section.items[0]).")
        }
        XCTAssertEqual(podcast.title, "The Daily")
        XCTAssertEqual(podcast.id, "MPSPPLdaily000001")
        XCTAssertTrue(
            podcast.isPodcast,
            "Podcast detected by 'MPSP' browseId prefix must set isPodcast=true."
        )
    }

    /// #2 RED — defensive fallback: pageType==MUSIC_PAGE_TYPE_PODCAST overrides
    ///          generic browseId prefix.
    func testTwoRowItem_podcastByPageType_mapsToPlaylistWithIsPodcastTrue() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_podcast_byPageType")
        let result = try BrowseResponseMapper.mapHome(data)

        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 1)

        guard case .playlist(let podcast) = section.items[0] else {
            return XCTFail("Expected .playlist; got \(section.items[0]).")
        }
        XCTAssertEqual(podcast.title, "The Daily")
        XCTAssertTrue(
            podcast.isPodcast,
            "pageType==MUSIC_PAGE_TYPE_PODCAST must set isPodcast=true even with generic browseId."
        )
    }

    // MARK: - RED — podcast detection (responsiveListItem)

    /// #3 RED — shelf shape, MPSP browseId → isPodcast == true.
    func testResponsiveListItem_podcast_mapsToPlaylistWithIsPodcastTrue() throws {
        let data = try FixtureLoader.loadJSON("home_shelf_podcast_responsiveListItem")
        let result = try BrowseResponseMapper.mapHome(data)

        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 1)

        guard case .playlist(let podcast) = section.items[0] else {
            return XCTFail("Expected .playlist; got \(section.items[0]).")
        }
        XCTAssertEqual(podcast.title, "Hard Fork")
        XCTAssertEqual(podcast.id, "MPSPPLhardfork0002")
        XCTAssertTrue(
            podcast.isPodcast,
            "Podcast in shelf shape (responsiveListItem + MPSP browseId) must set isPodcast=true."
        )
    }

    // MARK: - REGRESSION — non-podcast playlists keep isPodcast == false

    /// #4 REGRESSION — twoRowItem with VLPL browseId + MUSIC_PAGE_TYPE_PLAYLIST.
    ///                 Reuses existing fixture to also pin existing carousel mapping.
    func testTwoRowItem_regularPlaylist_keepsIsPodcastFalse() throws {
        let data = try FixtureLoader.loadJSON("regression_carousel_playlists")
        let result = try BrowseResponseMapper.mapHome(data)

        let section = try XCTUnwrap(result.sections.first)
        XCTAssertGreaterThanOrEqual(section.items.count, 1)

        guard case .playlist(let regular) = section.items[0] else {
            return XCTFail("Expected .playlist; got \(section.items[0]).")
        }
        XCTAssertEqual(regular.id, "VLPLchill0001")
        XCTAssertFalse(
            regular.isPodcast,
            "Regular MUSIC_PAGE_TYPE_PLAYLIST must keep isPodcast=false (default)."
        )
    }

    /// #5 REGRESSION — responsiveListItem (shelf) with VLPL browseId +
    ///                 MUSIC_PAGE_TYPE_PLAYLIST.
    func testResponsiveListItem_regularPlaylist_keepsIsPodcastFalse() throws {
        let data = try FixtureLoader.loadJSON("home_shelf_regular_playlist_responsiveListItem")
        let result = try BrowseResponseMapper.mapHome(data)

        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 1)

        guard case .playlist(let regular) = section.items[0] else {
            return XCTFail("Expected .playlist; got \(section.items[0]).")
        }
        XCTAssertFalse(
            regular.isPodcast,
            "Regular MUSIC_PAGE_TYPE_PLAYLIST in shelf shape must keep isPodcast=false (default)."
        )
    }

    // MARK: - REGRESSION — 2-flexColumn podcast (Claude F1 + Codex F1)

    /// #6 REGRESSION — real YouTube podcast list items expose 2 flexColumns
    /// (title + host). Without hoisting podcast detection above `mapAlbum`,
    /// the `columns.count >= 2` guard would claim this as `.album`. Pins the
    /// remediation: `isPodcast` MUST run first AND accept the canonical
    /// `MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE` pageType.
    func testResponsiveListItem_podcastWith2FlexColumns_routesToPlaylistNotAlbum() throws {
        let data = try FixtureLoader.loadJSON("home_shelf_podcast_2flex_responsiveListItem")
        let result = try BrowseResponseMapper.mapHome(data)
        XCTAssertEqual(result.sections.count, 1)
        let item = try XCTUnwrap(result.sections.first?.items.first)
        guard case .playlist(let p) = item else {
            XCTFail("Expected .playlist with isPodcast=true, got \(item)")
            return
        }
        XCTAssertTrue(p.isPodcast, "Podcast with 2 flex columns must NOT route to .album")
        XCTAssertEqual(p.title, "Hard Fork")
    }
}
