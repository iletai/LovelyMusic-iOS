import XCTest
@testable import LovelyMusic

final class HomePageTests: XCTestCase {
    func testParseEmptyData() {
        XCTAssertThrowsError(try BrowseResponseMapper.mapHome(Data()))
    }

    func testParseInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try BrowseResponseMapper.mapHome(data))
    }

    func testParseEmptyJSON() throws {
        let data = "{}".data(using: .utf8)!
        let result = try BrowseResponseMapper.mapHome(data)
        XCTAssertTrue(result.sections.isEmpty)
    }

    func testParseEmptyContents() throws {
        let json = """
        {"contents": {}}
        """
        let data = json.data(using: .utf8)!
        let result = try BrowseResponseMapper.mapHome(data)
        XCTAssertTrue(result.sections.isEmpty)
    }
}
