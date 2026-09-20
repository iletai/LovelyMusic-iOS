import XCTest
@testable import LovelyMusic

final class SearchPageTests: XCTestCase {
    // MARK: - parseDuration

    func testParseDurationMinutesSeconds() {
        XCTAssertEqual(SearchResponseMapper.parseDuration("3:45"), 225)
    }

    func testParseDurationHalfMinute() {
        XCTAssertEqual(SearchResponseMapper.parseDuration("0:30"), 30)
    }

    func testParseDurationHoursMinutesSeconds() {
        XCTAssertEqual(SearchResponseMapper.parseDuration("1:00:00"), 3600)
    }

    func testParseDurationComplex() {
        XCTAssertEqual(SearchResponseMapper.parseDuration("1:23:45"), 5025)
    }

    func testParseDurationNil() {
        XCTAssertNil(SearchResponseMapper.parseDuration(nil))
    }

    func testParseDurationEmpty() {
        XCTAssertNil(SearchResponseMapper.parseDuration(""))
    }

    func testParseDurationInvalid() {
        XCTAssertNil(SearchResponseMapper.parseDuration("abc"))
    }

    func testParseDurationZero() {
        XCTAssertEqual(SearchResponseMapper.parseDuration("0:00"), 0)
    }

    // MARK: - map(data:)

    func testParseEmptyData() {
        XCTAssertThrowsError(try SearchResponseMapper.map(Data()))
    }

    func testParseInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try SearchResponseMapper.map(data))
    }

    func testParseEmptyJSON() throws {
        let data = "{}".data(using: .utf8)!
        let result = try SearchResponseMapper.map(data)
        XCTAssertTrue(result.songs.isEmpty)
        XCTAssertTrue(result.albums.isEmpty)
    }

    // MARK: - mapSong

    func testMapSongFromEmptyRenderer() {
        let renderer = MusicResponsiveListItemRenderer(flexColumns: nil, fixedColumns: nil, thumbnail: nil, overlay: nil, navigationEndpoint: nil, playlistItemData: nil, badges: nil, musicItemRendererDisplayPolicy: nil)
        let song = SearchResponseMapper.mapSong(from: renderer)
        XCTAssertNil(song)
    }

    // MARK: - mapAlbum

    func testMapAlbumFromEmptyRenderer() {
        let renderer = MusicResponsiveListItemRenderer(flexColumns: nil, fixedColumns: nil, thumbnail: nil, overlay: nil, navigationEndpoint: nil, playlistItemData: nil, badges: nil, musicItemRendererDisplayPolicy: nil)
        let album = SearchResponseMapper.mapAlbum(from: renderer)
        XCTAssertNil(album)
    }

    // MARK: - mapArtist

    func testMapArtistFromEmptyRenderer() {
        let renderer = MusicResponsiveListItemRenderer(flexColumns: nil, fixedColumns: nil, thumbnail: nil, overlay: nil, navigationEndpoint: nil, playlistItemData: nil, badges: nil, musicItemRendererDisplayPolicy: nil)
        let artist = SearchResponseMapper.mapArtist(from: renderer)
        XCTAssertNil(artist)
    }

    // MARK: - mapPlaylist

    func testMapPlaylistFromEmptyRenderer() {
        let renderer = MusicResponsiveListItemRenderer(flexColumns: nil, fixedColumns: nil, thumbnail: nil, overlay: nil, navigationEndpoint: nil, playlistItemData: nil, badges: nil, musicItemRendererDisplayPolicy: nil)
        let playlist = SearchResponseMapper.mapPlaylist(from: renderer)
        XCTAssertNil(playlist)
    }
}
