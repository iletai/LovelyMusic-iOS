import XCTest

@testable import LovelyMusic

/// Regression guard for `BrowseResponseMapper.mapHome(_:)`. These tests
/// pin the existing carousel/shelf/grid mapping behavior so the
/// implementer's renderer-coverage work cannot silently break the three
/// renderer paths that currently work in production.
///
/// All three tests must be GREEN today and remain GREEN after the
/// follow-up implementer change.
final class BrowseResponseMapperRegressionTests: XCTestCase {

    // MARK: - musicCarouselShelfRenderer (playlists)

    func testCarouselShelf_existingPlaylistsSection_stillMapsCorrectly() throws {
        let data = try FixtureLoader.loadJSON("regression_carousel_playlists")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1, "Expected exactly one carousel section.")
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.title, "Recommended playlists")
        XCTAssertEqual(section.items.count, 2)

        guard case .playlist(let firstPlaylist) = section.items[0] else {
            return XCTFail("First carousel item should map to .playlist; got \(section.items[0]).")
        }
        XCTAssertEqual(firstPlaylist.id, "VLPLchill0001")
        XCTAssertEqual(firstPlaylist.title, "Chill Hits")
        XCTAssertEqual(firstPlaylist.thumbnailURL, "https://example.invalid/pl1.jpg")
    }

    // MARK: - musicShelfRenderer + musicResponsiveListItemRenderer (songs)

    func testShelfRenderer_existingSongsSection_stillMapsCorrectly() throws {
        let data = try FixtureLoader.loadJSON("regression_shelf_songs")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1, "Expected exactly one shelf section.")
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.title, "Listen again")
        XCTAssertEqual(section.items.count, 2)

        guard case .song(let firstSong) = section.items[0] else {
            return XCTFail("First shelf item should map to .song; got \(section.items[0]).")
        }
        XCTAssertEqual(firstSong.id, "songVid001")
        XCTAssertEqual(firstSong.title, "Song One")
        XCTAssertEqual(firstSong.artistName, "Artist One")
    }

    // MARK: - gridRenderer + musicTwoRowItemRenderer (artists)

    func testGridRenderer_existingArtistsSection_stillMapsCorrectly() throws {
        let data = try FixtureLoader.loadJSON("regression_grid_artists")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1, "Expected exactly one grid section.")
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.items.count, 2)

        guard case .artist(let firstArtist) = section.items[0] else {
            return XCTFail("First grid item should map to .artist; got \(section.items[0]).")
        }
        XCTAssertEqual(firstArtist.id, "UCalpha000001")
        XCTAssertEqual(firstArtist.name, "Artist Alpha")
        XCTAssertEqual(firstArtist.thumbnailURL, "https://example.invalid/a1.jpg")
    }
}

final class InnerTubeRepositoryHomeMergeTests: XCTestCase {

    func testExploreSectionsLeadWhileHomeMetadataAndPaginationArePreserved() throws {
        let explore = try BrowseResponseMapper.mapHome(
            FixtureLoader.loadJSON("regression_shelf_songs"))
        let mappedHome = try BrowseResponseMapper.mapHome(
            FixtureLoader.loadJSON("regression_carousel_playlists"))
        let home = HomeResult(
            sections: mappedHome.sections,
            continuation: "home-next-page",
            chips: [
                HomeChip(id: "all", title: "Tất cả", params: nil, isSelected: true)
            ]
        )

        let result = InnerTubeRepository.mergeInitialHome(home: home, explore: explore)

        XCTAssertEqual(result.sections.map(\.title), ["Listen again", "Recommended playlists"])
        XCTAssertEqual(result.continuation, "home-next-page")
        XCTAssertEqual(result.chips, home.chips)
    }

    func testDuplicateSectionTitleUsesExploreVersion() throws {
        let mapped = try BrowseResponseMapper.mapHome(
            FixtureLoader.loadJSON("regression_carousel_playlists"))
        let home = HomeResult(sections: mapped.sections, continuation: "next")
        let explore = HomeResult(sections: mapped.sections, continuation: nil)

        let result = InnerTubeRepository.mergeInitialHome(home: home, explore: explore)

        XCTAssertEqual(result.sections.count, 1)
        XCTAssertEqual(result.sections.first?.title, "Recommended playlists")
        XCTAssertEqual(result.continuation, "next")
    }

    func testGenericCommunityPlaylistShelfIsRemovedFromMergedFeed() throws {
        let mapped = try BrowseResponseMapper.mapHome(
            FixtureLoader.loadJSON("regression_carousel_playlists"))
        let items = try XCTUnwrap(mapped.sections.first?.items)
        let staleCommunitySection = MusicSection(
            title: "Danh sách phát thịnh hành trong cộng đồng người dùng",
            items: items
        )
        let home = HomeResult(
            sections: [staleCommunitySection] + mapped.sections,
            continuation: "next"
        )

        let result = InnerTubeRepository.mergeInitialHome(home: home, explore: mapped)

        XCTAssertFalse(
            result.sections.contains { $0.title == staleCommunitySection.title })
        XCTAssertEqual(result.continuation, "next")
    }

    func testMissingExploreFallsBackToUnchangedHome() throws {
        let home = try BrowseResponseMapper.mapHome(
            FixtureLoader.loadJSON("regression_carousel_playlists"))

        let result = InnerTubeRepository.mergeInitialHome(home: home, explore: nil)

        XCTAssertEqual(result.sections.map(\.title), home.sections.map(\.title))
        XCTAssertEqual(result.continuation, home.continuation)
    }
}
