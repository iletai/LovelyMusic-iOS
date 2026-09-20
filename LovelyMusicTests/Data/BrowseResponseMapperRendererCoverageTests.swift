import XCTest

@testable import LovelyMusic

/// Red tests pinning the *desired* behavior for renderers that the home
/// feed mapper currently drops or fails to surface. These tests MUST FAIL
/// against the current `BrowseResponseMapper.mapHome(_:)` and pass once
/// the implementer wires up:
///   - `musicMultiRowListItemRenderer` items inside `musicShelfRenderer`
///   - `musicImmersiveCarouselShelfRenderer` (carousel-shaped alias)
///   - `musicCardShelfRenderer` (single highlighted card)
///   - graceful skip + telemetry hook for unknown section renderers
///
/// See `doc/analysis/2026-05-03-home-content-audit/architecture-mapping-audit.md`
/// and `doc/analysis/2026-05-03-home-content-audit/innertune-upstream-diff.md`.
final class BrowseResponseMapperRendererCoverageTests: XCTestCase {

    // MARK: - musicMultiRowListItemRenderer (Quick picks)

    func testMultiRowListItemRenderer_quickRadioPicks_isMappedToShelf() throws {
        let data = try FixtureLoader.loadJSON("quick_picks_multirow")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(
            result.sections.count, 1,
            "Quick picks shelf should produce exactly one section, but the mapper currently drops musicMultiRowListItemRenderer items, leaving the shelf empty and filtered out."
        )

        guard let section = result.sections.first else {
            return XCTFail("Expected a 'Quick picks' section but got none.")
        }
        XCTAssertEqual(section.title, "Quick picks")
        XCTAssertEqual(
            section.items.count, 2,
            "Both multi-row items should be surfaced as section items."
        )

        // Item 1 — title, artist, thumbnail, watch endpoint videoId.
        guard case .song(let firstSong) = section.items[0] else {
            return XCTFail("Expected first item to map to a Song; got \(section.items[0]).")
        }
        XCTAssertEqual(firstSong.title, "Pick One")
        XCTAssertEqual(firstSong.artistName, "Artist A")
        XCTAssertEqual(firstSong.id, "qp00000001")
        XCTAssertEqual(firstSong.thumbnailURL, "https://example.invalid/thumb1.jpg")
    }

    // MARK: - musicImmersiveCarouselShelfRenderer (Long listening)

    func testImmersiveCarouselShelfRenderer_isDecodedAsCarouselAlias() throws {
        let data = try FixtureLoader.loadJSON("immersive_carousel")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(
            result.sections.count, 1,
            "musicImmersiveCarouselShelfRenderer must be decoded with the same body schema as musicCarouselShelfRenderer; it is currently silently dropped because BrowseResponse.SectionContent has no field for the key."
        )

        guard let section = result.sections.first else {
            return XCTFail("Expected one section from the immersive carousel; got none.")
        }
        XCTAssertEqual(section.title, "Long listening")
        XCTAssertEqual(section.items.count, 2)

        guard case .playlist(let playlist) = section.items[0] else {
            return XCTFail("Expected first item to be a Playlist; got \(section.items[0]).")
        }
        XCTAssertEqual(playlist.id, "VLPLimm00000001")
        XCTAssertEqual(playlist.title, "Mix For You")
    }

    // MARK: - musicCardShelfRenderer (Featured card)

    func testCardShelfRenderer_isDecodedAsHighlightedCard() throws {
        let data = try FixtureLoader.loadJSON("card_shelf")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertGreaterThanOrEqual(
            result.sections.count, 1,
            "musicCardShelfRenderer must be surfaced as at least one renderable home section. It is currently dropped because BrowseResponse.SectionContent has no field for the key in the home browse path."
        )

        // Locate the section that came from the card shelf.
        let cardSection = result.sections.first { $0.title == "Featured Album" }
        XCTAssertNotNil(
            cardSection,
            "Expected a section titled 'Featured Album' produced from musicCardShelfRenderer."
        )

        // Item should resolve via onTap.browseEndpoint (album browseId MPRE*).
        if let items = cardSection?.items, let first = items.first {
            switch first {
            case .album(let album):
                XCTAssertEqual(album.id, "MPREb_card00000001")
                XCTAssertEqual(album.title, "Featured Album")
            case .playlist(let pl):
                // Acceptable fallback if implementer maps card to a playlist-style item.
                XCTAssertEqual(pl.id, "MPREb_card00000001")
            default:
                XCTFail(
                    "Card shelf item should resolve to an album (or fallback playlist); got \(first)."
                )
            }
        } else {
            XCTFail("Card section had no items.")
        }
    }

    // MARK: - Unknown renderer graceful skip (baseline pin)

    /// This test pins the **current best behavior**: the mapper does not
    /// throw when it encounters an unrecognized section renderer; it simply
    /// drops the unknown section and returns the rest. It already passes
    /// today and is included here so the implementer's changes (which will
    /// add a telemetry hook) do not regress the no-throw guarantee.
    func testUnknownSectionRenderer_doesNotCrashAndIsLogged() throws {
        let data = try FixtureLoader.loadJSON("unknown_renderer")

        let result: HomeResult
        do {
            result = try BrowseResponseMapper.mapHome(data)
        } catch {
            return XCTFail("Mapper must not throw on unknown renderers; got: \(error)")
        }

        XCTAssertEqual(
            result.sections.count, 1,
            "Unknown 'musicMadeUpRenderer' must be skipped silently while the valid carousel section is preserved (N-1 sections returned)."
        )
        XCTAssertEqual(result.sections.first?.title, "Real section")

        // Future-work marker: when telemetry is added, replace this comment
        // with an assertion against the recorded skip events.
    }
}
