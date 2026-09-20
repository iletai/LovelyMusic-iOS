import XCTest
@testable import LovelyMusic

@MainActor
final class SettingsViewModelTests: XCTestCase {
    var viewModel: SettingsViewModel!
    var authManager: YouTubeAuthManager!

    override func setUp() {
        super.setUp()
        authManager = YouTubeAuthManager()
        viewModel = SettingsViewModel(authManager: authManager)
    }

    override func tearDown() {
        viewModel = nil
        authManager = nil
        super.tearDown()
    }

    func testResetAllSettingsRestoresDefaults() {
        viewModel.skipSilence = true
        viewModel.audioNormalization = true
        viewModel.persistentQueue = true
        viewModel.autoSkipOnError = false
        viewModel.crossfadeDuration = 8
        viewModel.hideExplicitContent = true
        viewModel.disableScreenshots = true
        viewModel.videoQuality = .hd720

        viewModel.resetAllSettings()

        XCTAssertFalse(viewModel.skipSilence)
        XCTAssertFalse(viewModel.audioNormalization)
        XCTAssertFalse(viewModel.persistentQueue)
        XCTAssertTrue(viewModel.autoSkipOnError)
        XCTAssertEqual(viewModel.crossfadeDuration, 0)
        XCTAssertFalse(viewModel.hideExplicitContent)
        XCTAssertFalse(viewModel.disableScreenshots)
        XCTAssertEqual(viewModel.videoQuality, .auto)
    }

    func testAudioNormalizationPostsNotification() {
        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .audioNormalizationChanged,
            object: nil,
            queue: .main
        ) { _ in notified = true }

        viewModel.audioNormalization = true
        XCTAssertTrue(notified)
        NotificationCenter.default.removeObserver(token)
    }

    func testSkipSilencePostsNotification() {
        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .skipSilenceChanged,
            object: nil,
            queue: .main
        ) { _ in notified = true }

        viewModel.skipSilence = true
        XCTAssertTrue(notified)
        NotificationCenter.default.removeObserver(token)
    }

    func testCrossfadeDurationPostsNotification() {
        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .crossfadeDurationChanged,
            object: nil,
            queue: .main
        ) { _ in notified = true }

        viewModel.crossfadeDuration = 5
        XCTAssertTrue(notified)
        NotificationCenter.default.removeObserver(token)
    }

    func testHideExplicitContentPostsNotification() {
        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { _ in notified = true }

        viewModel.hideExplicitContent = true
        XCTAssertTrue(notified)
        NotificationCenter.default.removeObserver(token)
    }

    func testDisableScreenshotsPostsNotification() {
        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { _ in notified = true }

        viewModel.disableScreenshots = true
        XCTAssertTrue(notified)
        NotificationCenter.default.removeObserver(token)
    }

    func testAutoplayRelatedSongsPostsNotification() {
        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { _ in notified = true }

        viewModel.autoplayRelatedSongs = false
        XCTAssertTrue(notified)
        NotificationCenter.default.removeObserver(token)
    }

    func testRegionAndLanguagePostNotification() {
        var regionNotified = false
        var languageNotified = false

        let token = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { _ in }

        let regionToken = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { _ in regionNotified = true }

        viewModel.region = "US"
        XCTAssertTrue(regionNotified)
        NotificationCenter.default.removeObserver(regionToken)

        let langToken = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { _ in languageNotified = true }

        viewModel.language = "en"
        XCTAssertTrue(languageNotified)
        NotificationCenter.default.removeObserver(langToken)
        NotificationCenter.default.removeObserver(token)
    }

    func testEffectiveQualityForFreeVsPremium() {
        viewModel.audioQuality = .high

        let freeQuality = viewModel.effectiveQuality(isPremium: false)
        let premiumQuality = viewModel.effectiveQuality(isPremium: true)

        XCTAssertEqual(freeQuality, .medium)
        XCTAssertEqual(premiumQuality, .high)
    }

    func testAudioEngineUpdatesOnSettingsNotifications() {
        let engine = AudioEngine()

        viewModel.audioNormalization = true
        XCTAssertTrue(engine.normalizationEnabled)

        viewModel.audioNormalization = false
        XCTAssertFalse(engine.normalizationEnabled)

        viewModel.skipSilence = true
        XCTAssertTrue(engine.skipSilenceEnabled)

        viewModel.skipSilence = false
        XCTAssertFalse(engine.skipSilenceEnabled)

        viewModel.crossfadeDuration = 6.0
        XCTAssertEqual(engine.crossfadeManager.crossfadeDuration, 6.0)

        viewModel.crossfadeDuration = 0.0
        XCTAssertEqual(engine.crossfadeManager.crossfadeDuration, 0.0)
    }
}
