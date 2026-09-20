import XCTest
@testable import LovelyMusic

final class NextPageTests: XCTestCase {
    func testParseEmptyData() {
        XCTAssertThrowsError(try NextResponseMapper.map(Data()))
    }

    func testParseInvalidJSON() {
        let data = "invalid".data(using: .utf8)!
        XCTAssertThrowsError(try NextResponseMapper.map(data))
    }

    func testParseEmptyJSON() throws {
        let data = "{}".data(using: .utf8)!
        let songs = try NextResponseMapper.map(data)
        XCTAssertTrue(songs.isEmpty)
    }

    func testParseEmptyContents() throws {
        let json = """
        {"contents": {}}
        """
        let data = json.data(using: .utf8)!
        let songs = try NextResponseMapper.map(data)
        XCTAssertTrue(songs.isEmpty)
    }
}
