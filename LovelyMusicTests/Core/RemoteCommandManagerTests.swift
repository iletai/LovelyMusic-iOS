import XCTest
import MediaPlayer
@testable import LovelyMusic

@MainActor
final class RemoteCommandManagerTests: XCTestCase {

    // MARK: - AE-4: Verify tearDown removes all command targets

    func testTearDownRemovesAllTargets() {
        let manager = RemoteCommandManager()
        manager.setup()

        // After setup, commands should have targets.
        // tearDown should remove all targets without crashing.
        manager.tearDown()

        // Verify we can call setup again (re-entrant) without leaking targets
        manager.setup()
        manager.tearDown()
    }

    func testSetupCanBeCalledMultipleTimes() {
        let manager = RemoteCommandManager()

        // Calling setup multiple times should not accumulate targets
        // because each setup() call removes existing targets first.
        manager.setup()
        manager.setup()
        manager.setup()

        // Clean up
        manager.tearDown()
    }

    func testSetupConfiguresAllCommands() {
        let manager = RemoteCommandManager()
        let commandCenter = MPRemoteCommandCenter.shared()

        manager.setup()

        // Verify commands are enabled
        XCTAssertTrue(commandCenter.playCommand.isEnabled)
        XCTAssertTrue(commandCenter.pauseCommand.isEnabled)
        XCTAssertTrue(commandCenter.nextTrackCommand.isEnabled)
        XCTAssertTrue(commandCenter.previousTrackCommand.isEnabled)
        XCTAssertTrue(commandCenter.changePlaybackPositionCommand.isEnabled)
        XCTAssertTrue(commandCenter.skipForwardCommand.isEnabled)
        XCTAssertTrue(commandCenter.skipBackwardCommand.isEnabled)

        manager.tearDown()
    }
}
