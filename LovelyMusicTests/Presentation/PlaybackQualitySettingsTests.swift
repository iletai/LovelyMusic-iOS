import Foundation
import XCTest

@testable import LovelyMusic

@MainActor
final class PlaybackQualitySettingsTests: XCTestCase {
    func testExistingExplicitGlobalQualityMigratesToAllNetworksOnce() throws {
        let fixture = try makeDefaults()
        fixture.defaults.set("medium", forKey: "audioQuality")

        let settings = PlaybackQualitySettings(defaults: fixture.defaults)

        XCTAssertEqual(settings.wifi, .medium)
        XCTAssertEqual(settings.cellular, .medium)
        XCTAssertEqual(settings.constrained, .medium)
        XCTAssertEqual(settings.download, .medium)
        XCTAssertTrue(fixture.defaults.bool(forKey: "audioQualityPerNetworkMigrationV1"))
    }

    func testFreshInstallUsesNetworkDefaults() throws {
        let fixture = try makeDefaults()

        let settings = PlaybackQualitySettings(defaults: fixture.defaults)

        XCTAssertEqual(settings.wifi, .high)
        XCTAssertEqual(settings.cellular, .medium)
        XCTAssertEqual(settings.constrained, .low)
        XCTAssertEqual(settings.download, .high)
    }

    func testMigrationIsIdempotentAndDoesNotReapplyChangedLegacyValue() throws {
        let fixture = try makeDefaults()
        fixture.defaults.set("medium", forKey: "audioQuality")
        let first = PlaybackQualitySettings(defaults: fixture.defaults)
        first.wifi = .low
        fixture.defaults.set("high", forKey: "audioQuality")

        let relaunched = PlaybackQualitySettings(defaults: fixture.defaults)

        XCTAssertEqual(relaunched.wifi, .low)
        XCTAssertEqual(relaunched.cellular, .medium)
        XCTAssertEqual(relaunched.download, .medium)
    }

    func testEachQualityPersistsIndependently() throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)
        settings.wifi = .medium
        settings.cellular = .low
        settings.constrained = .medium
        settings.download = .low

        let relaunched = PlaybackQualitySettings(defaults: fixture.defaults)

        XCTAssertEqual(relaunched.wifi, .medium)
        XCTAssertEqual(relaunched.cellular, .low)
        XCTAssertEqual(relaunched.constrained, .medium)
        XCTAssertEqual(relaunched.download, .low)
    }

    func testFreeTierCapIsAppliedWithoutOverwritingStoredIntent() throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)
        settings.wifi = .high
        settings.download = .high

        XCTAssertEqual(
            settings.effectiveStreamingQuality(
                for: .wifi(expensive: false, constrained: false),
                isPremium: false
            ),
            .medium
        )
        XCTAssertEqual(settings.effectiveDownloadQuality(isPremium: false), .medium)
        XCTAssertEqual(settings.wifi, .high)
        XCTAssertEqual(settings.download, .high)
        XCTAssertEqual(fixture.defaults.string(forKey: "audioQualityWiFiV1"), "high")
        XCTAssertEqual(fixture.defaults.string(forKey: "audioQualityDownloadV1"), "high")
    }

    func testNetworkSelectionUsesConstrainedBeforeInterfaceAndOfflineFailsLow() throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)

        XCTAssertEqual(
            settings.effectiveStreamingQuality(
                for: .wifi(expensive: false, constrained: false),
                isPremium: true
            ),
            .high
        )
        XCTAssertEqual(
            settings.effectiveStreamingQuality(
                for: .cellular(constrained: false),
                isPremium: true
            ),
            .medium
        )
        XCTAssertEqual(
            settings.effectiveStreamingQuality(
                for: .wifi(expensive: false, constrained: true),
                isPremium: true
            ),
            .low
        )
        XCTAssertEqual(
            settings.effectiveStreamingQuality(for: .offline, isPremium: true),
            .low
        )
        XCTAssertEqual(
            settings.effectiveStreamingQuality(
                for: .wifi(expensive: true, constrained: false),
                isPremium: true
            ),
            .low
        )
    }

    func testPostMigrationChangesNeverWriteRetiredGlobalKey() throws {
        let fixture = try makeDefaults()
        fixture.defaults.set("medium", forKey: "audioQuality")
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)

        settings.wifi = .low
        settings.cellular = .high
        settings.download = .low

        XCTAssertEqual(fixture.defaults.string(forKey: "audioQuality"), "medium")
        XCTAssertEqual(settings.legacyGlobalProjection, .medium)
    }

    func testSettingsViewModelCompatibilityProjectionDoesNotMutateHighIntentForFreeUser() throws {
        let fixture = try makeDefaults()
        let settings = PlaybackQualitySettings(defaults: fixture.defaults)
        settings.wifi = .high
        let viewModel = SettingsViewModel(
            authManager: YouTubeAuthManager(),
            playbackQualitySettings: settings
        )

        XCTAssertEqual(viewModel.audioQuality, .high)
        XCTAssertEqual(viewModel.effectiveQuality(isPremium: false), .medium)
        viewModel.capQualityIfNeeded(isPremium: false)
        XCTAssertEqual(viewModel.audioQuality, .high)
        XCTAssertEqual(settings.wifi, .high)
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PlaybackQualitySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return (defaults, suiteName)
    }
}
