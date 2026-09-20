import XCTest

@testable import LovelyMusic

/// TDD red-phase suite for the chip-filter empty-Home bug.
///
/// Audit: `doc/analysis/2026-05-04-home-chip-filter-empty/audit.md` §H2.
/// Chip-filtered `FEmusic_home + params` responses come back wrapped in
/// `continuationContents.sectionListContinuation` rather than the
/// top-level `contents.…sectionListRenderer` envelope. The current
/// `BrowseResponseMapper.mapHome(_:)` only reads the top-level path,
/// so all sections silently drop and the user sees an empty Home.
///
/// These tests pin the contract that the chip-filter fix must satisfy:
/// 1. A response with ONLY the continuation envelope must yield its
///    sections from `mapHome`.
/// 2. When BOTH envelopes are present, top-level wins (precedence).
/// 3. A response with an empty top-level `contents[]` must fall through
///    to the continuation envelope (matches chip-tap reality where the
///    top-level array can be present-but-empty).
/// 4. A response with neither envelope returns empty without throwing.
final class BrowseResponseMapperChipFilterTests: XCTestCase {

    // MARK: - Test 1: continuation-only envelope (the actual chip-tap shape)

    func testMapHome_responseWithContinuationEnvelope_mapsSectionsFromContinuation() throws {
        let data = try FixtureLoader.loadJSON("chip_filter_continuation_envelope")

        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(
            result.sections.count, 2,
            "Chip-filtered home response wraps sections under continuationContents.sectionListContinuation.contents[]; mapHome must read that envelope when contents is absent."
        )
        XCTAssertEqual(result.sections.first?.title, "Relax mix")
        XCTAssertEqual(result.sections.last?.title, "Focus instrumentals")
    }

    // MARK: - Test 2: precedence — top-level wins

    func testMapHome_responseWithBothEnvelopes_prefersTopLevel() throws {
        let data = try FixtureLoader.loadJSON("chip_filter_both_envelopes")

        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(
            result.sections.count, 1,
            "When both envelopes are populated, the top-level sectionListRenderer must win to preserve current home-tab behavior."
        )
        XCTAssertEqual(result.sections.first?.title, "Top-level only")
    }

    // MARK: - Test 3: empty top-level → fall through to continuation

    func testMapHome_responseWithEmptyContents_butContinuationPresent_usesContinuation() throws {
        // Build inline: top-level contents.sectionListRenderer.contents = []
        // AND continuationContents.sectionListContinuation populated.
        let json = """
            {
                "contents": {
                    "singleColumnBrowseResultsRenderer": {
                        "tabs": [
                            {
                                "tabRenderer": {
                                    "content": {
                                        "sectionListRenderer": {
                                            "contents": []
                                        }
                                    }
                                }
                            }
                        ]
                    }
                },
                "continuationContents": {
                    "sectionListContinuation": {
                        "contents": [
                            {
                                "musicCarouselShelfRenderer": {
                                    "header": {
                                        "musicCarouselShelfBasicHeaderRenderer": {
                                            "title": { "runs": [{ "text": "Fallback shelf" }] }
                                        }
                                    },
                                    "contents": [
                                        {
                                            "musicTwoRowItemRenderer": {
                                                "title": { "runs": [{ "text": "Fallback Playlist" }] },
                                                "subtitle": { "runs": [{ "text": "YouTube Music" }] },
                                                "thumbnailRenderer": {
                                                    "musicThumbnailRenderer": {
                                                        "thumbnail": {
                                                            "thumbnails": [
                                                                { "url": "https://example.invalid/fb.jpg", "width": 226, "height": 226 }
                                                            ]
                                                        }
                                                    }
                                                },
                                                "navigationEndpoint": {
                                                    "browseEndpoint": {
                                                        "browseId": "VLPLfb0001",
                                                        "browseEndpointContextSupportedConfigs": {
                                                            "browseEndpointContextMusicConfig": {
                                                                "pageType": "MUSIC_PAGE_TYPE_PLAYLIST"
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    ]
                                }
                            }
                        ]
                    }
                }
            }
            """
        let data = Data(json.utf8)

        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertGreaterThanOrEqual(
            result.sections.count, 1,
            "When top-level contents is present-but-empty (chip-tap reality), mapHome must fall through to continuationContents.sectionListContinuation."
        )
        XCTAssertEqual(result.sections.first?.title, "Fallback shelf")
    }

    // MARK: - Test 4: neither envelope → empty, no throw (sanity baseline)

    func testMapHome_responseWithNeitherEnvelope_returnsEmpty() throws {
        let json = "{}"
        let data = Data(json.utf8)

        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(
            result.sections.count, 0,
            "An empty browse response must yield zero sections without throwing."
        )
    }
}
