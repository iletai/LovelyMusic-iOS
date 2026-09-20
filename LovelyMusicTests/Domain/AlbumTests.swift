import XCTest
@testable import LovelyMusic

final class AlbumTests: XCTestCase {
    func testTotalDuration() {
        let songs = [
            Song(id: "1", title: "A", artistName: "X", artistId: nil, albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil),
            Song(id: "2", title: "B", artistName: "X", artistId: nil, albumName: nil, albumId: nil, duration: 240, thumbnailURL: nil),
            Song(id: "3", title: "C", artistName: "X", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil),
        ]
        let album = Album(id: "a1", title: "Album", artistName: "X", artistId: nil, year: "2024", thumbnailURL: nil, songs: songs)
        XCTAssertEqual(album.totalDuration, "7 min")
    }

    func testTotalDurationEmpty() {
        let album = Album(id: "a1", title: "Album", artistName: "X", artistId: nil, year: nil, thumbnailURL: nil, songs: [])
        XCTAssertEqual(album.totalDuration, "0 min")
    }

    func testTotalDurationAllNil() {
        let songs = [
            Song(id: "1", title: "A", artistName: "X", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil),
            Song(id: "2", title: "B", artistName: "X", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil),
        ]
        let album = Album(id: "a1", title: "Album", artistName: "X", artistId: nil, year: nil, thumbnailURL: nil, songs: songs)
        XCTAssertEqual(album.totalDuration, "0 min")
    }

    func testTotalDurationSingleSong() {
        let songs = [
            Song(id: "1", title: "A", artistName: "X", artistId: nil, albumName: nil, albumId: nil, duration: 300, thumbnailURL: nil),
        ]
        let album = Album(id: "a1", title: "Album", artistName: "X", artistId: nil, year: "2023", thumbnailURL: nil, songs: songs)
        XCTAssertEqual(album.totalDuration, "5 min")
    }

    func testAlbumIdentifiable() {
        let album = Album(id: "unique-id", title: "Test", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [])
        XCTAssertEqual(album.id, "unique-id")
    }
}
