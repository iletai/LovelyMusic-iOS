import SwiftUI
import XCTest

@testable import LovelyMusic

/// Tests covering the polish-A2 / polish-A3 `.dockSafeBottom()` modifier and
/// the polish-E5 AdManager ad-unit-ID resolution flow.
@MainActor
final class DockSafeBottomTests: XCTestCase {

    // MARK: - polish-A2 / A3 — DockSafeBottom modifier

    /// The modifier must compose cleanly onto a SwiftUI `ScrollView` without
    /// crashing during view-tree construction.
    func test_dockSafeBottom_appliedToScrollView_doesNotCrash() {
        let view = ScrollView {
            VStack {
                ForEach(0..<10, id: \.self) { Text("Row \($0)") }
            }
        }
        .dockSafeBottom()

        // Construct the underlying body. If the modifier produces an invalid
        // tree the call below traps; reaching the assertion proves the tree
        // was built successfully.
        _ = UIHostingController(rootView: view)
        XCTAssertNotNil(view)
    }

    // MARK: - polish-E5 — AdManager ad unit ID resolution

    /// Stub that returns whatever IDs the test supplies. Mirrors the
    /// production `SecretsAdUnitIDProvider` shape.
    private struct StubAdUnitIDProvider: AdUnitIDProviding {
        var bannerAdUnitID: String?
        var interstitialAdUnitID: String?
    }

    /// FeatureFlagManager isn't required for ID resolution, but its `init()`
    /// is cheap and side-effect-free, so we use a real instance.
    private func makeAdManager(provider: AdUnitIDProviding) -> AdManager {
        let flags = FeatureFlagManager()
        let premium = PremiumManager(featureFlagManager: flags)
        return AdManager(
            premiumManager: premium,
            featureFlagManager: flags,
            adUnitIDProvider: provider
        )
    }

    func test_adManager_loadsAdUnitIDs_fromSecretsProvider() {
        let knownBanner = "ca-app-pub-1111111111111111/1111111111"
        let knownInterstitial = "ca-app-pub-2222222222222222/2222222222"
        let stub = StubAdUnitIDProvider(
            bannerAdUnitID: knownBanner,
            interstitialAdUnitID: knownInterstitial
        )

        let adManager = makeAdManager(provider: stub)

        XCTAssertEqual(
            adManager.bannerAdUnitID, knownBanner,
            "AdManager.bannerAdUnitID should expose the value supplied by the provider")
    }

    func test_adManager_fallsBackToGoogleTestID_whenSecretMissing() {
        let stub = StubAdUnitIDProvider(
            bannerAdUnitID: nil,
            interstitialAdUnitID: nil
        )

        let adManager = makeAdManager(provider: stub)

        XCTAssertEqual(
            adManager.bannerAdUnitID,
            AdUnitResolver.GoogleTestIDs.banner,
            "When provider returns nil, AdManager must fall back to Google's public test banner ID — never empty / placeholder."
        )

        // Also exercise the resolver directly to assert the test-fallback flag
        // is set and the interstitial fallback is wired.
        let resolved = AdUnitResolver.resolve(stub)
        XCTAssertTrue(resolved.usedTestFallback)
        XCTAssertEqual(resolved.interstitial, AdUnitResolver.GoogleTestIDs.interstitial)
    }
}
