import XCTest
@testable import LovelyMusic

final class SearchFilterTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(SearchFilter.songs.displayName, "Songs")
        XCTAssertEqual(SearchFilter.albums.displayName, "Albums")
        XCTAssertEqual(SearchFilter.artists.displayName, "Artists")
        XCTAssertEqual(SearchFilter.playlists.displayName, "Playlists")
    }

    func testAllCases() {
        XCTAssertEqual(SearchFilter.allCases.count, 4)
    }

    func testFilterMappingProducesValidParams() {
        // Verify that SearchFilterMapper produces non-empty API params for each filter
        for filter in SearchFilter.allCases {
            let params = SearchFilterMapper.toParams(filter)
            XCTAssertFalse(params.isEmpty, "\(filter) should produce non-empty API params")
            XCTAssertTrue(params.contains("EgW"), "\(filter) params should contain InnerTube prefix")
        }
    }

    func testFilterMappingUnique() {
        let params = SearchFilter.allCases.map { SearchFilterMapper.toParams($0) }
        XCTAssertEqual(Set(params).count, params.count, "Each filter should map to a unique API param")
    }
}
