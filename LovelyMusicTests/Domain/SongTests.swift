import XCTest
@testable import LovelyMusic

final class SongTests: XCTestCase {
    func testFormattedDuration() {
        let song = Song(id: "1", title: "Test", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 185, thumbnailURL: nil)
        XCTAssertEqual(song.formattedDuration, "3:05")
    }

    func testFormattedDurationNil() {
        let song = Song(id: "1", title: "Test", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        XCTAssertEqual(song.formattedDuration, "--:--")
    }

    func testFormattedDurationZero() {
        let song = Song(id: "1", title: "Test", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 0, thumbnailURL: nil)
        XCTAssertEqual(song.formattedDuration, "0:00")
    }

    func testFormattedDurationLong() {
        let song = Song(id: "1", title: "Test", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 3661, thumbnailURL: nil)
        XCTAssertEqual(song.formattedDuration, "61:01")
    }

    func testFormattedDurationExactMinute() {
        let song = Song(id: "1", title: "Test", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 120, thumbnailURL: nil)
        XCTAssertEqual(song.formattedDuration, "2:00")
    }

    func testFormattedDurationUnderMinute() {
        let song = Song(id: "1", title: "Test", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 45, thumbnailURL: nil)
        XCTAssertEqual(song.formattedDuration, "0:45")
    }

    func testSongEquality() {
        let s1 = Song(id: "abc", title: "A", artistName: "B", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        let s2 = Song(id: "abc", title: "A", artistName: "B", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        XCTAssertEqual(s1, s2)
    }

    func testSongInequality() {
        let s1 = Song(id: "abc", title: "A", artistName: "B", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        let s2 = Song(id: "xyz", title: "A", artistName: "B", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        XCTAssertNotEqual(s1, s2)
    }

    func testSongHashable() {
        let song = Song(id: "1", title: "Test", artistName: "Artist", artistId: nil, albumName: nil, albumId: nil, duration: 100, thumbnailURL: nil)
        var set = Set<Song>()
        set.insert(song)
        set.insert(song)
        XCTAssertEqual(set.count, 1)
    }

    func testSongCodable() throws {
        let song = Song(id: "v1", title: "My Song", artistName: "Artist", artistId: "a1", albumName: "Album", albumId: "al1", duration: 200, thumbnailURL: "https://img.com/1")
        let data = try JSONEncoder().encode(song)
        let decoded = try JSONDecoder().decode(Song.self, from: data)
        XCTAssertEqual(decoded.id, song.id)
        XCTAssertEqual(decoded.title, song.title)
        XCTAssertEqual(decoded.artistName, song.artistName)
        XCTAssertEqual(decoded.duration, song.duration)
        XCTAssertEqual(decoded.thumbnailURL, song.thumbnailURL)
    }
}
