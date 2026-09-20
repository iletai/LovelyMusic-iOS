import XCTest
@testable import LovelyMusic

final class PlayerStateTests: XCTestCase {
    func testIsActiveStates() {
        XCTAssertTrue(PlayerState.playing.isActive)
        XCTAssertTrue(PlayerState.paused.isActive)
        XCTAssertTrue(PlayerState.buffering.isActive)
    }

    func testIsNotActiveStates() {
        XCTAssertFalse(PlayerState.idle.isActive)
        XCTAssertFalse(PlayerState.loading.isActive)
        XCTAssertFalse(PlayerState.error("test").isActive)
    }

    func testEquality() {
        XCTAssertEqual(PlayerState.idle, PlayerState.idle)
        XCTAssertEqual(PlayerState.playing, PlayerState.playing)
        XCTAssertEqual(PlayerState.error("msg"), PlayerState.error("msg"))
        XCTAssertNotEqual(PlayerState.playing, PlayerState.paused)
        XCTAssertNotEqual(PlayerState.error("a"), PlayerState.error("b"))
    }
}
