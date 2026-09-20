import XCTest

@testable import LovelyMusic

/// Feature 1 — Mapper tests for `MUSIC_PAGE_TYPE_AUDIOBOOK` and
/// `MUSIC_PAGE_TYPE_USER_CHANNEL` in carousel (twoRowItem) shapes.
///
/// Follows the pattern established in `BrowseResponseMapperPodcastTests`.
final class BrowseResponseMapperAudiobookTests: XCTestCase {

    // MARK: - Audiobook (carousel twoRowItem)

    /// Verify `mapHome` produces an `.audiobook` item from a carousel
    /// containing a `MUSIC_PAGE_TYPE_AUDIOBOOK` twoRowItem.
    func testTwoRowItem_audiobook_mapsToAudiobookItem() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_audiobook_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.title, "Audiobooks for you")
        XCTAssertEqual(section.items.count, 1)

        guard case .audiobook(let book) = section.items[0] else {
            return XCTFail("Expected .audiobook; got \(section.items[0]).")
        }
        XCTAssertEqual(book.title, "Deep Work")
        XCTAssertEqual(book.browseId, "MPREb_deepwork001")
        XCTAssertEqual(book.authorName, "Cal Newport")
        XCTAssertEqual(book.thumbnailURL, "https://example.invalid/audiobook_deep_work.jpg")
    }

    /// Verify the `.audiobook` item's `id` matches the browseId extracted
    /// from the fixture.
    func testTwoRowItem_audiobook_idMatchesBrowseId() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_audiobook_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)

        let section = try XCTUnwrap(result.sections.first)
        guard case .audiobook(let book) = section.items[0] else {
            return XCTFail("Expected .audiobook; got \(section.items[0]).")
        }
        XCTAssertEqual(book.id, "MPREb_deepwork001")
    }

    // MARK: - UserChannel (carousel twoRowItem)

    /// Verify `mapHome` produces a `.userChannel` item from a carousel
    /// containing a `MUSIC_PAGE_TYPE_USER_CHANNEL` twoRowItem.
    func testTwoRowItem_userChannel_mapsToUserChannelItem() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_userchannel_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.title, "Channels you follow")
        XCTAssertEqual(section.items.count, 1)

        guard case .userChannel(let channel) = section.items[0] else {
            return XCTFail("Expected .userChannel; got \(section.items[0]).")
        }
        XCTAssertEqual(channel.name, "Lo-Fi Beats")
        XCTAssertEqual(channel.browseId, "UClofi_beats_001")
        XCTAssertEqual(channel.thumbnailURL, "https://example.invalid/channel_lofi.jpg")
    }

    /// Verify the `.userChannel` item's `id` matches the browseId.
    func testTwoRowItem_userChannel_idMatchesBrowseId() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_userchannel_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)

        let section = try XCTUnwrap(result.sections.first)
        guard case .userChannel(let channel) = section.items[0] else {
            return XCTFail("Expected .userChannel; got \(section.items[0]).")
        }
        XCTAssertEqual(channel.id, "UClofi_beats_001")
    }

    // MARK: - MusicSectionItem ID prefix verification

    /// The `.audiobook` wrapper must produce an ID with "audiobook-" prefix.
    func testAudiobookSectionItemIdPrefix() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_audiobook_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)

        let item = try XCTUnwrap(result.sections.first?.items.first)
        XCTAssertTrue(
            item.id.hasPrefix("audiobook-"),
            "Audiobook MusicSectionItem id must start with 'audiobook-'; got '\(item.id)'"
        )
    }

    /// The `.userChannel` wrapper must produce an ID with "userChannel-" prefix.
    func testUserChannelSectionItemIdPrefix() throws {
        let data = try FixtureLoader.loadJSON("home_carousel_userchannel_twoRowItem")
        let result = try BrowseResponseMapper.mapHome(data)

        let item = try XCTUnwrap(result.sections.first?.items.first)
        XCTAssertTrue(
            item.id.hasPrefix("userChannel-"),
            "UserChannel MusicSectionItem id must start with 'userChannel-'; got '\(item.id)'"
        )
    }
}
