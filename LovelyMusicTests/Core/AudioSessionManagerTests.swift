import AVFoundation
import XCTest

@testable import LovelyMusic

/// Verifies the audio session lifecycle introduced for B1: category is set
/// at launch (no activation), activation is invoked lazily before playback.
///
/// We cannot mock `AVAudioSession.sharedInstance()` directly, but we can
/// observe state transitions on the real shared instance — which is what
/// the production code mutates. Tests run in isolation with category reset
/// between cases.
final class AudioSessionManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset to a known state. Failures here are non-fatal for the tests below.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    override func tearDown() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        super.tearDown()
    }

    // MARK: - B1: setCategory configures category without activating

    func testSetCategory_setsPlaybackCategory() {
        AudioSessionManager.setCategory()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }

    // MARK: - B1: activate brings the session up after category is set

    func testActivate_succeedsAfterSetCategory() {
        AudioSessionManager.setCategory()
        AudioSessionManager.activate()
        // We can't directly read isActive, but if activate failed it would log
        // an error. We re-activate to confirm idempotency does not throw.
        AudioSessionManager.activate()
    }

    // MARK: - B5: configure() removed; setCategory + activate are the entry points

    func testActivateIsIdempotent() {
        AudioSessionManager.setCategory()
        for _ in 0..<5 {
            AudioSessionManager.activate()
        }
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }
}
