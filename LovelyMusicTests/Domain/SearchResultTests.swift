import XCTest
@testable import LovelyMusic

final class SearchResultTests: XCTestCase {
    func testEmptySearchResult() {
        let result = SearchResult.empty
        XCTAssertTrue(result.songs.isEmpty)
        XCTAssertTrue(result.albums.isEmpty)
        XCTAssertTrue(result.artists.isEmpty)
        XCTAssertTrue(result.playlists.isEmpty)
        XCTAssertNil(result.continuation)
    }

    func testSearchResultWithData() {
        let song = Song(id: "1", title: "Song", artistName: "A", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        let album = Album(id: "2", title: "Album", artistName: "A", artistId: nil, year: nil, thumbnailURL: nil, songs: [])
        let result = SearchResult(songs: [song], albums: [album], artists: [], playlists: [], continuation: "token123")
        XCTAssertEqual(result.songs.count, 1)
        XCTAssertEqual(result.albums.count, 1)
        XCTAssertEqual(result.continuation, "token123")
    }
}
