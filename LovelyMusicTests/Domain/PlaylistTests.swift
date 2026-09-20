import XCTest
@testable import LovelyMusic

final class PlaylistTests: XCTestCase {
    func testDefaultInit() {
        let p = Playlist(title: "My Playlist")
        XCTAssertFalse(p.id.isEmpty)
        XCTAssertEqual(p.title, "My Playlist")
        XCTAssertTrue(p.songs.isEmpty)
        XCTAssertTrue(p.isLocal)
        XCTAssertNil(p.thumbnailURL)
        XCTAssertNil(p.songCount)
    }

    func testCustomInit() {
        let p = Playlist(id: "pl1", title: "Test", thumbnailURL: "https://img.com/1", songCount: 5, songs: [], isLocal: false)
        XCTAssertEqual(p.id, "pl1")
        XCTAssertEqual(p.title, "Test")
        XCTAssertEqual(p.thumbnailURL, "https://img.com/1")
        XCTAssertEqual(p.songCount, 5)
        XCTAssertFalse(p.isLocal)
    }

    func testUniqueIds() {
        let p1 = Playlist(title: "Playlist 1")
        let p2 = Playlist(title: "Playlist 2")
        XCTAssertNotEqual(p1.id, p2.id)
    }

    func testMutableTitle() {
        var p = Playlist(title: "Original")
        p.title = "Updated"
        XCTAssertEqual(p.title, "Updated")
    }

    func testMutableSongs() {
        var p = Playlist(title: "Test")
        let song = Song(id: "s1", title: "Song", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        p.songs.append(song)
        XCTAssertEqual(p.songs.count, 1)
    }
}
