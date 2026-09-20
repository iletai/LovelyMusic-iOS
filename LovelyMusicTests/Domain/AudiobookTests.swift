import XCTest

@testable import LovelyMusic

/// Feature 1 — Audiobook and UserChannel entity tests.
///
/// Validates that the new Home P1 entities (`Audiobook`, `UserChannel`)
/// conform to `Identifiable` and `Hashable`, and can be initialized with
/// all fields including optional ones.
final class AudiobookTests: XCTestCase {

    // MARK: - Audiobook

    func testAudiobookInitWithAllFields() {
        let book = Audiobook(
            id: "AB001",
            title: "Deep Work",
            authorName: "Cal Newport",
            thumbnailURL: "https://example.com/cover.jpg",
            browseId: "MPREb_deepwork001"
        )

        XCTAssertEqual(book.id, "AB001")
        XCTAssertEqual(book.title, "Deep Work")
        XCTAssertEqual(book.authorName, "Cal Newport")
        XCTAssertEqual(book.thumbnailURL, "https://example.com/cover.jpg")
        XCTAssertEqual(book.browseId, "MPREb_deepwork001")
    }

    func testAudiobookInitWithNilOptionals() {
        let book = Audiobook(
            id: "AB002",
            title: "Untitled",
            authorName: nil,
            thumbnailURL: nil,
            browseId: "MPREb_002"
        )

        XCTAssertNil(book.authorName)
        XCTAssertNil(book.thumbnailURL)
    }

    func testAudiobookConformsToIdentifiable() {
        let book = Audiobook(
            id: "AB003",
            title: "Atomic Habits",
            authorName: nil,
            thumbnailURL: nil,
            browseId: "MPREb_003"
        )
        // Identifiable requires `id` — compiler enforces this; runtime check:
        XCTAssertEqual(book.id, "AB003")
    }

    func testAudiobookConformsToHashable() {
        let a = Audiobook(id: "AB1", title: "A", authorName: nil, thumbnailURL: nil, browseId: "b1")
        let b = Audiobook(id: "AB1", title: "A", authorName: nil, thumbnailURL: nil, browseId: "b1")

        var set = Set<Audiobook>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Identical audiobooks must hash equally")
    }

    func testAudiobookEquality() {
        let a = Audiobook(id: "AB1", title: "X", authorName: "Y", thumbnailURL: nil, browseId: "b1")
        let b = Audiobook(id: "AB1", title: "X", authorName: "Y", thumbnailURL: nil, browseId: "b1")
        XCTAssertEqual(a, b)
    }

    func testAudiobookInequality() {
        let a = Audiobook(id: "AB1", title: "X", authorName: nil, thumbnailURL: nil, browseId: "b1")
        let b = Audiobook(id: "AB2", title: "X", authorName: nil, thumbnailURL: nil, browseId: "b2")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - UserChannel

    func testUserChannelInitWithAllFields() {
        let channel = UserChannel(
            id: "UC001",
            name: "Lo-Fi Beats",
            thumbnailURL: "https://example.com/avatar.jpg",
            browseId: "UClofi001"
        )

        XCTAssertEqual(channel.id, "UC001")
        XCTAssertEqual(channel.name, "Lo-Fi Beats")
        XCTAssertEqual(channel.thumbnailURL, "https://example.com/avatar.jpg")
        XCTAssertEqual(channel.browseId, "UClofi001")
    }

    func testUserChannelInitWithNilThumbnail() {
        let channel = UserChannel(
            id: "UC002",
            name: "No Avatar",
            thumbnailURL: nil,
            browseId: "UC002"
        )

        XCTAssertNil(channel.thumbnailURL)
    }

    func testUserChannelConformsToHashable() {
        let a = UserChannel(id: "UC1", name: "A", thumbnailURL: nil, browseId: "UC1")
        let b = UserChannel(id: "UC1", name: "A", thumbnailURL: nil, browseId: "UC1")

        var set = Set<UserChannel>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Identical channels must hash equally")
    }

    func testUserChannelEquality() {
        let a = UserChannel(id: "UC1", name: "Ch", thumbnailURL: nil, browseId: "UC1")
        let b = UserChannel(id: "UC1", name: "Ch", thumbnailURL: nil, browseId: "UC1")
        XCTAssertEqual(a, b)
    }

    func testUserChannelInequality() {
        let a = UserChannel(id: "UC1", name: "Ch", thumbnailURL: nil, browseId: "UC1")
        let b = UserChannel(id: "UC2", name: "Ch", thumbnailURL: nil, browseId: "UC2")
        XCTAssertNotEqual(a, b)
    }
}
