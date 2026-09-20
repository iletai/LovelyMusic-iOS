import XCTest

@testable import LovelyMusic

/// S5.2 — Episode pageType detection on the Browse side (TDD RED phase).
///
/// Episodes appear inside podcast playlist responses (and occasionally on
/// the home feed) as `musicResponsiveListItemRenderer` rows. They are
/// playable like Songs but carry distinct routing markers:
///   • `navigationEndpoint.browseEndpoint.browseId` starts with `MPED`, OR
///   • `pageType == "MUSIC_PAGE_TYPE_PODCAST_EPISODE"`.
/// Detected episodes flow into `MusicSectionItem.song(...)` with the new
/// `Song.isEpisode == true` flag and `Song.episodeOf` populated from the
/// show name (typically the first run of `flexColumns[1]`).
///
/// EXPECTED RED MODE: tests fail to **compile** until `Song` gains the
/// `isEpisode` / `episodeOf` fields, then fail at runtime until
/// `mapResponsiveListItem` (via `SearchResponseMapper.mapSong`) learns
/// the episode contract above. Uses minimal **inline** JSON literals —
/// no new fixtures.
final class BrowseResponseMapperEpisodeTests: XCTestCase {

    // MARK: - Inline JSON builders

    /// Builds a minimal home-shape browse payload with a single
    /// `musicShelfRenderer` containing a single `musicResponsiveListItemRenderer`.
    private func homeShelfJSON(
        title: String,
        showName: String,
        videoId: String,
        browseId: String?,
        pageType: String?
    ) -> Data {
        let browseEndpointJSON: String = {
            guard let browseId else { return "null" }
            let pageTypeJSON =
                pageType.map { "\"\($0)\"" } ?? "null"
            return """
                {
                  "browseId": "\(browseId)",
                  "browseEndpointContextSupportedConfigs": {
                    "browseEndpointContextMusicConfig": { "pageType": \(pageTypeJSON) }
                  }
                }
                """
        }()
        let json = """
            {
              "contents": {
                "singleColumnBrowseResultsRenderer": {
                  "tabs": [{
                    "tabRenderer": {
                      "content": {
                        "sectionListRenderer": {
                          "contents": [{
                            "musicShelfRenderer": {
                              "title": { "runs": [{ "text": "Episodes" }] },
                              "contents": [{
                                "musicResponsiveListItemRenderer": {
                                  "flexColumns": [
                                    { "musicResponsiveListItemFlexColumnRenderer": {
                                        "text": { "runs": [{ "text": "\(title)" }] }
                                    }},
                                    { "musicResponsiveListItemFlexColumnRenderer": {
                                        "text": { "runs": [{ "text": "\(showName)" }] }
                                    }}
                                  ],
                                  "playlistItemData": { "videoId": "\(videoId)" },
                                  "navigationEndpoint": { "browseEndpoint": \(browseEndpointJSON) }
                                }
                              }]
                            }
                          }]
                        }
                      }
                    }
                  }]
                }
              }
            }
            """
        return Data(json.utf8)
    }

    private func extractFirstSong(from data: Data) throws -> Song {
        let result = try BrowseResponseMapper.mapHome(data)
        let section = try XCTUnwrap(result.sections.first)
        let item = try XCTUnwrap(section.items.first)
        guard case .song(let song) = item else {
            XCTFail("Expected .song, got \(item)")
            throw CocoaError(.coderInvalidValue)
        }
        return song
    }

    // MARK: - RED — pageType detection (browse path)

    /// #1 RED — `pageType == MUSIC_PAGE_TYPE_PODCAST_EPISODE` on the
    /// browse path routes the row to `.song(...)` with `isEpisode=true`
    /// and `episodeOf` populated from the show name.
    func testBrowseShelf_episodeByPageType_routesToSongWithIsEpisodeTrue() throws {
        let data = homeShelfJSON(
            title: "Episode 7: The Rise of Agents",
            showName: "Hard Fork",
            videoId: "epBrowseId01",
            browseId: "UCgenericxx",  // intentionally NOT MPED
            pageType: "MUSIC_PAGE_TYPE_PODCAST_EPISODE"
        )

        let song = try extractFirstSong(from: data)

        XCTAssertEqual(song.id, "epBrowseId01")
        XCTAssertEqual(song.title, "Episode 7: The Rise of Agents")
        XCTAssertTrue(
            song.isEpisode,
            "Browse: pageType==MUSIC_PAGE_TYPE_PODCAST_EPISODE must set Song.isEpisode=true."
        )
        XCTAssertEqual(
            song.episodeOf,
            "Hard Fork",
            "Browse: episodeOf must be the show name from flexColumns[1]."
        )
    }

    /// #2 RED — Defensive fallback: canonical `MPED…` browseId prefix
    /// flips `isEpisode=true` even with `pageType` missing, mirroring
    /// the S5.1 `MPSP` podcast fallback.
    func testBrowseShelf_episodeByMPEDBrowseIdPrefix_setsIsEpisodeTrue() throws {
        let data = homeShelfJSON(
            title: "Bonus Drop",
            showName: "Some Show",
            videoId: "epBrowseId02",
            browseId: "MPEDsomething",
            pageType: nil
        )

        let song = try extractFirstSong(from: data)

        XCTAssertTrue(
            song.isEpisode,
            "Browse: 'MPED' browseId prefix must set isEpisode=true even with pageType=nil."
        )
        XCTAssertEqual(song.episodeOf, "Some Show")
    }

    // MARK: - REGRESSION — non-episode browse rows keep defaults

    /// #3 REGRESSION — A regular shelf row (no browseEndpoint, plain
    /// watchEndpoint song) MUST keep `isEpisode == false` and
    /// `episodeOf == nil`. Pins the negative case so we don't false-tag
    /// every browse song.
    func testBrowseShelf_regularSong_keepsEpisodeDefaults() throws {
        // Regular song shape: watchEndpoint with videoId, no browseEndpoint.
        let json = """
            {
              "contents": {
                "singleColumnBrowseResultsRenderer": {
                  "tabs": [{
                    "tabRenderer": {
                      "content": {
                        "sectionListRenderer": {
                          "contents": [{
                            "musicShelfRenderer": {
                              "title": { "runs": [{ "text": "Quick picks" }] },
                              "contents": [{
                                "musicResponsiveListItemRenderer": {
                                  "flexColumns": [
                                    { "musicResponsiveListItemFlexColumnRenderer": {
                                        "text": { "runs": [{ "text": "Banger" }] }
                                    }},
                                    { "musicResponsiveListItemFlexColumnRenderer": {
                                        "text": { "runs": [{ "text": "Some Artist" }] }
                                    }}
                                  ],
                                  "navigationEndpoint": {
                                    "watchEndpoint": { "videoId": "regSongId01" }
                                  }
                                }
                              }]
                            }
                          }]
                        }
                      }
                    }
                  }]
                }
              }
            }
            """
        let song = try extractFirstSong(from: Data(json.utf8))

        XCTAssertEqual(song.id, "regSongId01")
        XCTAssertFalse(
            song.isEpisode,
            "Browse: plain songs (watchEndpoint only) must keep isEpisode=false."
        )
        XCTAssertNil(
            song.episodeOf,
            "Browse: plain songs must keep episodeOf=nil."
        )
    }

    // MARK: - RED — episode detection (carousel / twoRowItem path)

    /// Builds a minimal home payload with a single
    /// `musicCarouselShelfRenderer` containing one `musicTwoRowItemRenderer`.
    /// `pageType` is optional; `browseId` is required (matches real episode
    /// tiles which always carry a browseEndpoint).
    private func carouselTwoRowEpisodeJSON(
        title: String,
        showName: String,
        browseId: String,
        pageType: String?
    ) -> Data {
        let pageTypeJSON = pageType.map { "\"\($0)\"" } ?? "null"
        let json = """
            {
              "contents": {
                "singleColumnBrowseResultsRenderer": {
                  "tabs": [{
                    "tabRenderer": {
                      "content": {
                        "sectionListRenderer": {
                          "contents": [{
                            "musicCarouselShelfRenderer": {
                              "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                  "title": { "runs": [{ "text": "Latest episodes" }] }
                                }
                              },
                              "contents": [{
                                "musicTwoRowItemRenderer": {
                                  "title": { "runs": [{ "text": "\(title)" }] },
                                  "subtitle": { "runs": [{ "text": "\(showName)" }] },
                                  "thumbnailRenderer": {
                                    "musicThumbnailRenderer": {
                                      "thumbnail": { "thumbnails": [
                                        { "url": "https://i.ytimg.com/x.jpg", "width": 60, "height": 60 }
                                      ]}
                                    }
                                  },
                                  "navigationEndpoint": {
                                    "browseEndpoint": {
                                      "browseId": "\(browseId)",
                                      "browseEndpointContextSupportedConfigs": {
                                        "browseEndpointContextMusicConfig": { "pageType": \(pageTypeJSON) }
                                      }
                                    }
                                  }
                                }
                              }]
                            }
                          }]
                        }
                      }
                    }
                  }]
                }
              }
            }
            """
        return Data(json.utf8)
    }

    /// #4 RED — Episode in carousel layout (`musicTwoRowItemRenderer`).
    /// `pageType == MUSIC_PAGE_TYPE_PODCAST_EPISODE` must route the tile to
    /// `.song(...)` with `isEpisode=true` and `episodeOf` populated from
    /// the subtitle (show name). Currently `mapTwoRowItem` has no episode
    /// branch — the tile falls through to the default `.playlist(...)`
    /// case, so this test is RED.
    func testCarouselTwoRowItem_episodeByPageType_routesToSongWithIsEpisodeTrue() throws {
        let data = carouselTwoRowEpisodeJSON(
            title: "Episode 12: Shipping AI Safely",
            showName: "Hard Fork",
            browseId: "MPEDcarousel0001",
            pageType: "MUSIC_PAGE_TYPE_PODCAST_EPISODE"
        )

        let result = try BrowseResponseMapper.mapHome(data)
        let section = try XCTUnwrap(result.sections.first)
        let item = try XCTUnwrap(section.items.first)
        guard case .song(let song) = item else {
            XCTFail(
                "Carousel: episode pageType must route to .song; got \(item). "
                    + "mapTwoRowItem needs an episode branch mirroring the "
                    + "responsiveListItem path."
            )
            return
        }
        XCTAssertEqual(song.id, "MPEDcarousel0001")
        XCTAssertEqual(song.title, "Episode 12: Shipping AI Safely")
        XCTAssertTrue(
            song.isEpisode,
            "Carousel twoRowItem: pageType==MUSIC_PAGE_TYPE_PODCAST_EPISODE "
                + "must set Song.isEpisode=true."
        )
        XCTAssertEqual(
            song.episodeOf,
            "Hard Fork",
            "Carousel twoRowItem: episodeOf must be the show name from subtitle."
        )
    }

    // MARK: - GREEN guard — S5.1/S5.2 boundary

    /// #5 GREEN — Defends the boundary between S5.1 (Podcast show) and
    /// S5.2 (Episode item). A podcast SHOW (canonical `MPSP` browseId +
    /// `MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE`) MUST map to
    /// `.playlist(isPodcast: true)` and MUST NOT be confused with a Song
    /// episode. Reuses the S5.1 carousel fixture so a regression in
    /// either direction is caught here.
    func testCarouselTwoRowItem_podcastShow_remainsPlaylistNotEpisodeSong() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_podcast_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)
        let section = try XCTUnwrap(result.sections.first)
        let item = try XCTUnwrap(section.items.first)

        guard case .playlist(let podcast) = item else {
            XCTFail(
                "Boundary: podcast SHOW must remain .playlist; got \(item). "
                    + "S5.2 episode detection must NOT swallow S5.1 show tiles."
            )
            return
        }
        XCTAssertTrue(
            podcast.isPodcast,
            "Boundary: podcast show must keep isPodcast=true (S5.1 contract)."
        )
        // Negative assertion: the same item must NOT also surface as an
        // episode song. Since enum cases are exclusive, the guard above
        // already proves this — but we make the intent explicit by
        // re-checking the case shape.
        if case .song = item {
            XCTFail("Boundary: a podcast SHOW must never route to .song(isEpisode=true).")
        }
    }
}
