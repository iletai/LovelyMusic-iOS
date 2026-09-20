import XCTest

@testable import LovelyMusic

/// Round-2 red tests pinning the convergent issues from
/// `doc/review/2026-05-03-home-content-renderers/review-merged.md`:
///
///   1. Subtitle run-joining bug — `Runs.text` concatenates separator
///      runs (` • `), leaking them into `artistName`. Fix per
///      AGENTS.md §Runs Text Parsing oddElements pattern (extract
///      data at even indices 0, 2, 4...).
///   2. `musicCardShelfRenderer.contents` is silently dropped — only
///      the hero `onTap` item is surfaced; section title is read from
///      `card.title` instead of `card.header...title`.
///   3. Decoder fragility — a malformed body under any `SectionContent`
///      key throws the whole `BrowseResponse` decode instead of
///      gracefully skipping just that section.
///
/// All five tests below MUST be RED against current production source
/// (`BrowseResponse.swift`, `BrowseResponseMapper.swift`,
/// `SharedRenderers.swift`) and turn GREEN once the implementer wires
/// up the merged-review fixes. Round-1 tests in
/// `BrowseResponseMapperRendererCoverageTests` and
/// `BrowseResponseMapperRegressionTests` must remain GREEN.
final class BrowseResponseMapperReviewFollowupTests: XCTestCase {

    // MARK: - Subtitle separator runs (oddElements)

    /// AGENTS.md §Runs Text Parsing: artists in subtitle are interleaved
    /// with separator runs (` • `, ` & `); valid data lives at even
    /// indices (0, 2, 4...). Today `Runs.text` joins ALL runs, so
    /// `artistName` ends up `"Beyoncé • Pop • 2024"` instead of
    /// `"Beyoncé"`.
    func testMultiRowItem_subtitleWithSeparatorRuns_artistNameUsesOddElements() throws {
        let data = try FixtureLoader.loadJSON("multirow_subtitle_separators")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 1)

        guard case .song(let song) = section.items[0] else {
            return XCTFail(
                "Expected first item to map to a Song; got \(section.items[0]).")
        }
        XCTAssertEqual(song.id, "sep0000001")
        XCTAssertEqual(song.title, "Texas Hold 'Em")

        // Per AGENTS.md oddElements pattern, the artist name is the
        // first non-separator run (index 0). Separator runs (" • ")
        // must NOT leak into artistName.
        XCTAssertEqual(
            song.artistName, "Beyoncé",
            "artistName should be 'Beyoncé' (first oddElements entry per AGENTS.md), "
                + "not the joined Runs.text 'Beyoncé • Pop • 2024'."
        )
        XCTAssertFalse(
            song.artistName.contains("•"),
            "artistName must not contain the separator run ' • '."
        )
    }

    // MARK: - Card shelf with secondary contents (HIGH convergent)

    /// `musicCardShelfRenderer.contents` carries the secondary list of
    /// rows beneath the hero. Today the mapper drops them entirely —
    /// only the hero `onTap` becomes a section item. Fix per InnerTune
    /// `MusicCardShelfRenderer.kt` + `YouTube.kt#L106-L121`: section
    /// title from `header.musicCardShelfHeaderBasicRenderer.title`,
    /// items = hero + contents (deduped by `videoId`).
    func testCardShelfRenderer_withContents_mapsHeroPlusSecondaryItems() throws {
        let data = try FixtureLoader.loadJSON("card_shelf_with_contents")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(
            result.sections.count, 1,
            "Card shelf must produce exactly one section."
        )
        let section = try XCTUnwrap(result.sections.first)

        XCTAssertEqual(
            section.title, "Quick picks",
            "Section title must come from header.musicCardShelfHeaderBasicRenderer.title, "
                + "not from card.title (which holds the hero song title)."
        )
        XCTAssertEqual(
            section.items.count, 3,
            "Items must be hero (heroVid01) + 2 secondary rows (secVid01, secVid02). "
                + "Today card.contents is silently dropped → only 1 item."
        )

        let ids = section.items.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "Items must be deduplicated by id (no duplicate videoIds)."
        )

        let videoIds = section.items.compactMap { item -> String? in
            if case .song(let s) = item { return s.id }
            return nil
        }
        XCTAssertEqual(Set(videoIds), Set(["heroVid01", "secVid01", "secVid02"]))
    }

    // MARK: - Card shelf hero with watchEndpoint (untested branch)

    /// Pins the song-hero branch of `mapCardShelfItem` and the
    /// header-derived section title. Today the section title falls
    /// back to `"Untitled"` because the mapper reads `card.title?.text`
    /// (omitted in the fixture) instead of
    /// `card.header.musicCardShelfHeaderBasicRenderer.title`.
    func testCardShelfRenderer_withWatchEndpoint_mapsAsSong() throws {
        let data = try FixtureLoader.loadJSON("card_shelf_song_watchendpoint")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)

        XCTAssertEqual(
            section.title, "Now Playing",
            "Section title must be derived from "
                + "header.musicCardShelfHeaderBasicRenderer.title; today the mapper "
                + "uses card.title (absent here) and falls back to 'Untitled'."
        )

        XCTAssertEqual(section.items.count, 1)
        guard case .song(let song) = section.items[0] else {
            return XCTFail(
                "Card with onTap.watchEndpoint must map to a Song (not Album/"
                    + "Playlist/Artist). Got \(section.items[0])."
            )
        }
        XCTAssertEqual(song.id, "heroVid42")
    }

    // MARK: - Multi-row with album browseEndpoint (untested branch + subtitle bug)

    /// Pins the album branch of `mapMultiRowItem` (browseId MPRE* with
    /// pageType `MUSIC_PAGE_TYPE_ALBUM`). The subtitle uses separator
    /// runs to also pin the oddElements fix here — today
    /// `album.artistName` becomes `"Beyoncé • R&B"`.
    func testMultiRowItem_withBrowseEndpointAlbum_mapsAsAlbum() throws {
        let data = try FixtureLoader.loadJSON("multirow_album_browseendpoint")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 1)

        guard case .album(let album) = section.items[0] else {
            return XCTFail(
                "Multi-row with onTap.browseEndpoint pageType=MUSIC_PAGE_TYPE_ALBUM "
                    + "must map to an Album; got \(section.items[0])."
            )
        }
        XCTAssertEqual(album.id, "MPREb_album0001")
        XCTAssertEqual(album.title, "Cowboy Carter")
        XCTAssertEqual(
            album.artistName, "Beyoncé",
            "artistName must use oddElements (first non-separator run); "
                + "today Runs.text yields 'Beyoncé • R&B'."
        )
        XCTAssertFalse(album.artistName.contains("•"))
    }

    // MARK: - Tolerant decoding for malformed section bodies

    /// A real-world `musicCardShelfRenderer` body that no longer matches
    /// our model (e.g., string instead of object — schema drift) must
    /// NOT nuke the whole Home decode. Today the entire
    /// `BrowseResponse.init(from:)` throws because Codable can't coerce
    /// the bad section. After fix, the malformed section is skipped and
    /// the two valid carousels around it are still returned.
    func testSectionContent_malformedCardShelfBody_skipsSectionWithoutThrowing() throws {
        let data = try FixtureLoader.loadJSON("malformed_card_shelf_in_section_list")

        let result: HomeResult
        do {
            result = try BrowseResponseMapper.mapHome(data)
        } catch {
            return XCTFail(
                "Mapper must NOT throw on a single malformed section body — it "
                    + "should skip just that section. Today decoding the whole "
                    + "BrowseResponse throws: \(error)"
            )
        }

        XCTAssertEqual(
            result.sections.count, 2,
            "The two valid carousels must survive; only the malformed "
                + "musicCardShelfRenderer section is skipped."
        )
        XCTAssertEqual(result.sections.map(\.title), ["First valid", "Second valid"])
    }

    // MARK: - Round-3 follow-up: oddElements joins ALL even-indexed artist runs

    /// AGENTS.md §Runs Text Parsing — "Extract actual data at even
    /// indices (0, 2, 4...) — this is the oddElements pattern from
    /// InnerTune"; "Last run for year: In album subtitles, the year is
    /// typically the last run."
    ///
    /// Today `oddElementsText` (BrowseResponseMapper.swift:411-417)
    /// returns `runs.first?.text` — for a collab subtitle whose runs
    /// are `["Beyoncé", " & ", "Jay-Z", " • ", "2024"]` it yields
    /// `"Beyoncé"` and silently drops the 2nd+ artist.
    ///
    /// **Chosen contract** (documented for the implementer):
    ///   - Join all even-indexed runs with `", "` (InnerTune
    ///     `oddElements().joinToString(", ")` convention).
    ///   - Drop the trailing even-indexed run when it parses as a
    ///     4-digit year (per AGENTS.md "Last run for year"). This
    ///     keeps `artistName` semantic — a year does not belong in
    ///     the artist field.
    ///
    /// Expected for this fixture: `"Beyoncé, Jay-Z"` (year `"2024"`
    /// dropped, both artists joined). Today: `"Beyoncé"` → RED.
    func testMultiRowItem_subtitleWithMultipleArtists_joinsAllEvenIndexedRuns()
        throws
    {
        let data = try FixtureLoader.loadJSON("multirow_subtitle_multi_artist")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 1)

        guard case .song(let song) = section.items[0] else {
            return XCTFail(
                "Expected first item to map to a Song; got \(section.items[0]).")
        }
        XCTAssertEqual(song.id, "collab0001")
        XCTAssertEqual(song.title, "Bonnie & Clyde")

        XCTAssertEqual(
            song.artistName, "Beyoncé, Jay-Z",
            "All even-indexed artist runs must be joined with ', ' (InnerTune "
                + "oddElements().joinToString(\", \")); trailing year run must "
                + "be dropped per AGENTS.md 'Last run for year'. Today "
                + "oddElementsText returns runs.first?.text → 'Beyoncé' only."
        )
        XCTAssertFalse(
            song.artistName.contains("•"),
            "Separator runs must not leak into artistName."
        )
        XCTAssertFalse(
            song.artistName.contains("&"),
            "Separator runs (' & ') must not leak into artistName."
        )
        XCTAssertFalse(
            song.artistName.contains("2024"),
            "Trailing year run must be dropped from artistName."
        )
    }

    // MARK: - Round-3 LOW: separator-set robustness

    /// Round-3 review LOW finding (`doc/review/2026-05-04-home-chip-filter-empty/review.md`
    /// §"`joinSameFieldRuns` whitespace-sensitive equality"). The current
    /// field-change separator set in `BrowseResponseMapper.joinSameFieldRuns`
    /// is `[" • ", " · ", "•", "·"]` — strict-equality membership only.
    ///
    /// YouTube emits additional field separators that this set misses:
    ///   - em-dash with regular spaces (`" — "`, U+2014)
    ///   - en-dash with regular spaces (`" – "`, U+2013)
    ///   - bullet bracketed by non-breaking spaces (`"\u{00A0}•\u{00A0}"`,
    ///     U+00A0 + U+2022 + U+00A0)
    ///   - whitespace-edge bullets (`" •"`, `"• "`) — defensive against
    ///     trim/normalization differences in upstream payloads
    ///
    /// For every variant the artist join MUST stop at the separator —
    /// `artistName == "Beyoncé"` — even though the runs after it are
    /// `["Pop", " • ", "2024"]`. Today at least the em-dash, en-dash, and
    /// NBSP-bullet cases leak `"Beyoncé, Pop"` (or `"Beyoncé, Pop, 2024"`)
    /// because their separator strings are not in the set. The whitespace-
    /// edge cases also fail since membership is `Set<String>` strict equality.
    ///
    /// Each separator runs as its own `XCTContext.runActivity` so the
    /// failure report names exactly which variants are broken.
    func testMultiRowItem_subtitleWithVariedSeparators_treatsAllAsFieldChange()
        throws
    {
        struct Case {
            let label: String
            let separator: String
        }
        let cases: [Case] = [
            .init(label: "em-dash with regular spaces (U+2014)", separator: " \u{2014} "),
            .init(label: "en-dash with regular spaces (U+2013)", separator: " \u{2013} "),
            .init(
                label: "bullet bracketed by NBSP (U+00A0)", separator: "\u{00A0}\u{2022}\u{00A0}"),
            .init(label: "bullet missing trailing space", separator: " \u{2022}"),
            .init(label: "bullet missing leading space", separator: "\u{2022} "),
        ]

        // Anchor: load the on-disk fixture once to prove the file parses end
        // to end via FixtureLoader. Its embedded separator is the em-dash
        // variant; the inline template below covers all five cases uniformly
        // so every separator gets the same identical-shape JSON.
        _ = try FixtureLoader.loadJSON("multirow_subtitle_separator_variants")

        for c in cases {
            try XCTContext.runActivity(named: "separator: \(c.label)") { _ in
                // Hex-byte trace for the failure report — the 5 cases differ
                // ONLY in the separator string between runs[0] and runs[2].
                let hex = c.separator.unicodeScalars
                    .map { String(format: "U+%04X", $0.value) }
                    .joined(separator: " ")
                let escaped = c.separator
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let json = """
                    {
                      "contents": {
                        "singleColumnBrowseResultsRenderer": {
                          "tabs": [{ "tabRenderer": { "content": {
                            "sectionListRenderer": { "contents": [
                              { "musicShelfRenderer": {
                                  "title": { "runs": [{ "text": "Quick picks" }] },
                                  "contents": [
                                    { "musicMultiRowListItemRenderer": {
                                        "title": { "runs": [{ "text": "Texas Hold 'Em" }] },
                                        "subtitle": { "runs": [
                                          { "text": "Beyoncé" },
                                          { "text": "\(escaped)" },
                                          { "text": "Pop" },
                                          { "text": " \u{2022} " },
                                          { "text": "2024" }
                                        ]},
                                        "onTap": { "watchEndpoint": { "videoId": "sepvar0001" } }
                                    }}
                                  ]
                              }}
                            ]}
                          }}}]
                        }
                      }
                    }
                    """
                let data = Data(json.utf8)
                let result: HomeResult
                do {
                    result = try BrowseResponseMapper.mapHome(data)
                } catch {
                    XCTFail(
                        "Mapper threw for separator [\(hex)] (\(c.label)): \(error)")
                    return
                }

                guard let section = result.sections.first,
                    let item = section.items.first,
                    case .song(let song) = item
                else {
                    XCTFail(
                        "Did not yield a Song for separator [\(hex)] (\(c.label)). "
                            + "Sections=\(result.sections.count).")
                    return
                }
                XCTAssertEqual(
                    song.artistName, "Beyoncé",
                    "joinSameFieldRuns must treat [\(hex)] (\(c.label)) as a "
                        + "field-changing separator and stop the artist join. "
                        + "Got artistName=\(String(reflecting: song.artistName))."
                )
                XCTAssertFalse(
                    song.artistName.contains("Pop"),
                    "Genre run must not leak into artistName for separator "
                        + "[\(hex)] (\(c.label))."
                )
                XCTAssertFalse(
                    song.artistName.contains("2024"),
                    "Year run must not leak into artistName for separator "
                        + "[\(hex)] (\(c.label))."
                )
            }
        }
    }
}
