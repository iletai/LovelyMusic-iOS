import XCTest
@testable import LovelyMusic

final class APNsManagerPayloadTests: XCTestCase {
    func testParseAlbumRoute() {
        let payload: [AnyHashable: Any] = ["route": "album", "browse_id": "MPREb_xyz123"]
        let route = APNsManager.parseRoute(from: payload)
        XCTAssertEqual(route, Route.album(browseId: "MPREb_xyz123"))
    }

    func testParseArtistRoute() {
        let payload: [AnyHashable: Any] = ["route": "artist", "browse_id": "UC_xyz123"]
        let route = APNsManager.parseRoute(from: payload)
        XCTAssertEqual(route, Route.artist(browseId: "UC_xyz123"))
    }

    func testParsePlaylistRoute() {
        let payload: [AnyHashable: Any] = ["route": "playlist", "playlist_id": "VL_xyz123"]
        let route = APNsManager.parseRoute(from: payload)
        XCTAssertEqual(route, Route.playlist(playlistId: "VL_xyz123"))

        let camelPayload: [AnyHashable: Any] = ["route": "playlist", "browse_id": "VL_fallback456"]
        let fallbackRoute = APNsManager.parseRoute(from: camelPayload)
        XCTAssertEqual(fallbackRoute, Route.playlist(playlistId: "VL_fallback456"))
    }

    func testParseCamelCaseKeys() {
        let payload: [AnyHashable: Any] = ["route": "album", "browseId": "MPREb_camel"]
        let route = APNsManager.parseRoute(from: payload)
        XCTAssertEqual(route, Route.album(browseId: "MPREb_camel"))
    }

    func testParseDownloadsRoute() {
        let payload: [AnyHashable: Any] = ["route": "downloads"]
        let route = APNsManager.parseRoute(from: payload)
        XCTAssertEqual(route, Route.downloads)
    }

    func testParseLikedSongsRoute() {
        let payload: [AnyHashable: Any] = ["route": "likedSongs"]
        let route = APNsManager.parseRoute(from: payload)
        XCTAssertEqual(route, Route.likedSongs)
    }

    func testParseInvalidRouteReturnsNil() {
        let payload: [AnyHashable: Any] = ["route": "unknown_route"]
        let route = APNsManager.parseRoute(from: payload)
        XCTAssertNil(route)
    }
}
