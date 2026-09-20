import XCTest

@testable import LovelyMusic

/// Feature 1 — MusicSectionItem tests for the new `.audiobook` and
/// `.userChannel` cases, plus `isSongSection` edge cases.
final class MusicSectionItemTests: XCTestCase {

    // MARK: - ID prefix tests

    func testAudiobookItemIdHasCorrectPrefix() {
        let book = Audiobook(id: "AB123", title: "T", authorName: nil, thumbnailURL: nil, browseId: "b")
        let item = MusicSectionItem.audiobook(book)
        XCTAssertEqual(item.id, "audiobook-AB123")
    }

    func testUserChannelItemIdHasCorrectPrefix() {
        let channel = UserChannel(id: "UC456", name: "Ch", thumbnailURL: nil, browseId: "UC456")
        let item = MusicSectionItem.userChannel(channel)
        XCTAssertEqual(item.id, "userChannel-UC456")
    }

    func testSongItemIdHasCorrectPrefix() {
        let song = Song(
            id: "vid001", title: "S", artistName: "A", artistId: nil,
            albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil
        )
        let item = MusicSectionItem.song(song)
        XCTAssertEqual(item.id, "song-vid001")
    }

    func testAlbumItemIdHasCorrectPrefix() {
        let album = Album(
            id: "al001", title: "Al", artistName: "A", artistId: nil,
            year: nil, thumbnailURL: nil, songs: []
        )
        let item = MusicSectionItem.album(album)
        XCTAssertEqual(item.id, "album-al001")
    }

    // MARK: - isSongSection

    func testIsSongSectionReturnsFalseForAudiobookSection() {
        let books = (0..<3).map { i in
            MusicSectionItem.audiobook(
                Audiobook(id: "ab\(i)", title: "B\(i)", authorName: nil, thumbnailURL: nil, browseId: "b\(i)")
            )
        }
        let section = MusicSection(title: "Audiobooks", items: books)
        XCTAssertFalse(section.isSongSection, "A section of audiobooks must not be a song section")
    }

    func testIsSongSectionReturnsFalseForUserChannelSection() {
        let channels = (0..<3).map { i in
            MusicSectionItem.userChannel(
                UserChannel(id: "uc\(i)", name: "C\(i)", thumbnailURL: nil, browseId: "uc\(i)")
            )
        }
        let section = MusicSection(title: "Channels", items: channels)
        XCTAssertFalse(section.isSongSection, "A section of user channels must not be a song section")
    }

    func testIsSongSectionReturnsFalseForMixedNonSongItems() {
        let items: [MusicSectionItem] = [
            .audiobook(Audiobook(id: "ab1", title: "B", authorName: nil, thumbnailURL: nil, browseId: "b1")),
            .userChannel(UserChannel(id: "uc1", name: "C", thumbnailURL: nil, browseId: "uc1")),
            .album(Album(id: "al1", title: "A", artistName: "X", artistId: nil, year: nil, thumbnailURL: nil, songs: [])),
        ]
        let section = MusicSection(title: "Mixed", items: items)
        XCTAssertFalse(section.isSongSection)
    }

    func testIsSongSectionReturnsTrueWhenMajorityAreSongs() {
        let songs: [MusicSectionItem] = (0..<4).map { i in
            .song(Song(id: "s\(i)", title: "S\(i)", artistName: "A", artistId: nil,
                       albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil))
        }
        let mixed = songs + [
            .audiobook(Audiobook(id: "ab1", title: "B", authorName: nil, thumbnailURL: nil, browseId: "b1"))
        ]
        let section = MusicSection(title: "Songs+", items: mixed)
        // 4 songs > 5/2 = 2.5, and >= 2 → true
        XCTAssertTrue(section.isSongSection)
    }

    func testIsSongSectionReturnsFalseForEmptySection() {
        let section = MusicSection(title: "Empty", items: [])
        XCTAssertFalse(section.isSongSection, "Empty section cannot be a song section")
    }

    func testIsSongSectionReturnsFalseForSingleSong() {
        let items: [MusicSectionItem] = [
            .song(Song(id: "s1", title: "S", artistName: "A", artistId: nil,
                       albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil))
        ]
        let section = MusicSection(title: "One", items: items)
        // 1 song, count >= 2 fails → false
        XCTAssertFalse(section.isSongSection, "Single song does not meet the >= 2 threshold")
    }

    // MARK: - Hashable / Identifiable

    func testMusicSectionItemIsIdentifiable() {
        let item = MusicSectionItem.audiobook(
            Audiobook(id: "ab1", title: "T", authorName: nil, thumbnailURL: nil, browseId: "b1")
        )
        XCTAssertFalse(item.id.isEmpty, "Item must have a non-empty id")
    }

    func testMusicSectionItemIsHashable() {
        let item1 = MusicSectionItem.audiobook(
            Audiobook(id: "ab1", title: "T", authorName: nil, thumbnailURL: nil, browseId: "b1")
        )
        let item2 = MusicSectionItem.audiobook(
            Audiobook(id: "ab1", title: "T", authorName: nil, thumbnailURL: nil, browseId: "b1")
        )
        var set = Set<MusicSectionItem>()
        set.insert(item1)
        set.insert(item2)
        XCTAssertEqual(set.count, 1)
    }
}
