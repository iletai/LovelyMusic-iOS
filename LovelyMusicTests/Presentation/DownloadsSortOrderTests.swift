import XCTest

@testable import LovelyMusic

/// polish-E3 — Tests for the persisted Downloads sort order.
@MainActor
final class DownloadsSortOrderTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "DownloadsSortOrderTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Persistence

    func test_sortOrder_persistsToUserDefaults() {
        DownloadsSortOrder.titleAZ.save(to: defaults)
        let loaded = DownloadsSortOrder.load(from: defaults)
        XCTAssertEqual(loaded, .titleAZ)
    }

    func test_sortOrder_recentlyAdded_isDefault() {
        let loaded = DownloadsSortOrder.load(from: defaults)
        XCTAssertEqual(loaded, .recentlyAdded)
    }

    // MARK: - Sorting

    private func makeEntry(
        id: String, title: String, artist: String, duration: Int?
    ) -> DownloadManager.DownloadedSong {
        let song = Song(
            id: id,
            title: title,
            artistName: artist,
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: duration,
            thumbnailURL: nil
        )
        return DownloadManager.DownloadedSong(
            song: song,
            relativePath: "\(id).m4a",
            downloadedAt: Date(),
            fileSize: 1_000_000
        )
    }

    func test_sortOrder_titleAZ_sortsAlphabetically() {
        let entries = [
            makeEntry(id: "1", title: "Charlie", artist: "ZZZ", duration: 100),
            makeEntry(id: "2", title: "alpha", artist: "AAA", duration: 200),
            makeEntry(id: "3", title: "Bravo", artist: "MMM", duration: 150),
        ]

        let sorted = DownloadsSortOrder.titleAZ.apply(to: entries)
        XCTAssertEqual(sorted.map(\.song.title), ["alpha", "Bravo", "Charlie"])
    }

    func test_sortOrder_artistAZ_sortsByArtist() {
        let entries = [
            makeEntry(id: "1", title: "S1", artist: "Zed", duration: 100),
            makeEntry(id: "2", title: "S2", artist: "alice", duration: 200),
            makeEntry(id: "3", title: "S3", artist: "Bob", duration: 150),
        ]

        let sorted = DownloadsSortOrder.artistAZ.apply(to: entries)
        XCTAssertEqual(sorted.map(\.song.artistName), ["alice", "Bob", "Zed"])
    }

    func test_sortOrder_duration_sortsAscending() {
        let entries = [
            makeEntry(id: "1", title: "S1", artist: "A", duration: 300),
            makeEntry(id: "2", title: "S2", artist: "B", duration: 100),
            makeEntry(id: "3", title: "S3", artist: "C", duration: 200),
        ]

        let sorted = DownloadsSortOrder.duration.apply(to: entries)
        XCTAssertEqual(sorted.map(\.song.duration), [100, 200, 300])
    }

    func test_sortOrder_recentlyAdded_preservesInsertionOrder() {
        let entries = [
            makeEntry(id: "1", title: "Newest", artist: "A", duration: 100),
            makeEntry(id: "2", title: "Middle", artist: "B", duration: 200),
            makeEntry(id: "3", title: "Oldest", artist: "C", duration: 150),
        ]

        let sorted = DownloadsSortOrder.recentlyAdded.apply(to: entries)
        XCTAssertEqual(sorted.map(\.song.id), entries.map(\.song.id))
    }
}
