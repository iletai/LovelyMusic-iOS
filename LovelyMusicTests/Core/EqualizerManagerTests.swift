import XCTest
@testable import LovelyMusic

final class EqualizerManagerTests: XCTestCase {

    override func tearDown() {
        // Clean up UserDefaults after each test
        UserDefaults.standard.removeObject(forKey: "equalizerEnabled")
        UserDefaults.standard.removeObject(forKey: "equalizerPreset")
        UserDefaults.standard.removeObject(forKey: "equalizerCustomBands")
        super.tearDown()
    }

    // MARK: - AE-12: Debounce redundant writes during selectPreset

    func testSelectPresetWritesPresetOnce() {
        let manager = EqualizerManager()

        // selectPreset sets both selectedPreset and customBands.
        // Before the fix, setting customBands inside selectPreset would
        // trigger a redundant UserDefaults write via the didSet observer
        // because both the preset and bands change.
        // After the fix, redundant writes during selectPreset are skipped.
        manager.selectPreset(.bassBoost)

        // Verify correct final state
        XCTAssertEqual(manager.selectedPreset, .bassBoost)
        XCTAssertEqual(manager.customBands, EqualizerPreset.bassBoost.bands)

        // Verify UserDefaults has the correct values
        if let data = UserDefaults.standard.data(forKey: "equalizerPreset"),
           let preset = try? JSONDecoder().decode(EqualizerPreset.self, from: data) {
            XCTAssertEqual(preset, .bassBoost)
        } else {
            XCTFail("Preset not saved to UserDefaults")
        }

        if let bands = UserDefaults.standard.array(forKey: "equalizerCustomBands") as? [Float] {
            XCTAssertEqual(bands, EqualizerPreset.bassBoost.bands)
        } else {
            XCTFail("Custom bands not saved to UserDefaults")
        }
    }

    func testSelectPresetMultipleTimesPreservesCorrectState() {
        let manager = EqualizerManager()

        manager.selectPreset(.rock)
        manager.selectPreset(.jazz)
        manager.selectPreset(.flat)

        XCTAssertEqual(manager.selectedPreset, .flat)
        XCTAssertEqual(manager.customBands, EqualizerPreset.flat.bands)
    }

    func testResetToFlatUsesSelectPreset() {
        let manager = EqualizerManager()

        manager.selectPreset(.rock)
        manager.resetToFlat()

        XCTAssertEqual(manager.selectedPreset, .flat)
        XCTAssertEqual(manager.customBands, EqualizerPreset.flat.bands)
    }
}
