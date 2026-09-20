import Foundation
import GoogleMobileAds
import UIKit
import os

// MARK: - Ad Unit ID Provider

/// Source of AdMob ad unit IDs. The default implementation reads from
/// `SecretsProvider` (`Secrets.plist`). Tests can inject a stub.
protocol AdUnitIDProviding {
    var bannerAdUnitID: String? { get }
    var interstitialAdUnitID: String? { get }
}

/// Resolved ad unit IDs after applying the production-or-test-fallback policy.
/// Use `AdUnitResolver.resolve(_:)` to compute once at construction time so
/// `AdManager` does not have to repeat the fallback decision per access.
struct ResolvedAdUnitIDs {
    let banner: String
    let interstitial: String
    /// True when at least one ad unit fell back to Google's public test IDs.
    /// Surfaces a warning log so we never ship empty / placeholder IDs silently.
    let usedTestFallback: Bool
}

enum AdUnitResolver {
    /// Google's official public test ad unit IDs. Safe to use in dev / when
    /// Secrets.plist has no real keys configured. Source:
    /// https://developers.google.com/admob/ios/test-ads
    enum GoogleTestIDs {
        static let banner = "ca-app-pub-4751845849553335/8688961650"
        static let interstitial = "ca-app-pub-4751845849553335/5538458240"
    }

    static func resolve(_ provider: AdUnitIDProviding) -> ResolvedAdUnitIDs {
        let banner = provider.bannerAdUnitID
        let interstitial = provider.interstitialAdUnitID
        let fellBack = (banner == nil) || (interstitial == nil)
        if fellBack {
            Log.ads.warning(
                "AdMob ad unit IDs missing in Secrets.plist; falling back to Google test IDs. Configure AdMobBannerUnitID and AdMobInterstitialUnitID before release."
            )
        }
        return ResolvedAdUnitIDs(
            banner: banner ?? GoogleTestIDs.banner,
            interstitial: interstitial ?? GoogleTestIDs.interstitial,
            usedTestFallback: fellBack
        )
    }
}

/// Default provider that reads from `SecretsProvider` (`Secrets.plist`).
struct SecretsAdUnitIDProvider: AdUnitIDProviding {
    var bannerAdUnitID: String? { SecretsProvider.adMobBannerUnitID }
    var interstitialAdUnitID: String? { SecretsProvider.adMobInterstitialUnitID }
}

// MARK: - AdManager

/// Centralized ad management for Google AdMob integration.
/// Respects THREE gates before showing any ad:
/// 1. CMS flag `ads_enabled` (kill switch for App Store review)
/// 2. Premium status (premium users never see ads)
/// 3. Interstitial frequency from CMS `ads_skip_frequency`
///
/// ## Setup checklist (do these ONCE before shipping):
/// 1. Info.plist → `GADApplicationIdentifier` must be a real AdMob App ID
/// 2. AppDelegate → `MobileAds.shared.start()` called in didFinishLaunching
/// 3. Add `AdMobBannerUnitID` and `AdMobInterstitialUnitID` to `Secrets.plist`
///    (see `Secrets.plist.example`). Missing keys fall back to Google test IDs
///    with a warning log — never empty / placeholder.
/// 4. MicroCMS → Create `ads_enabled` (Bool) and `ads_skip_frequency` (Int) fields
@MainActor
@Observable
final class AdManager: NSObject {
    // MARK: - State

    private let resolvedAdUnitIDs: ResolvedAdUnitIDs
    private var interstitialAd: InterstitialAd?
    private(set) var isInterstitialReady = false
    private var skipCount = 0

    // Strong refs — same lifetime as DIContainer, no retain cycle risk
    private let premiumManager: PremiumManager
    private let featureFlagManager: FeatureFlagManager

    // MARK: - Init

    /// Designated initializer. Inject an `AdUnitIDProviding` for tests; the
    /// default `SecretsAdUnitIDProvider` reads from `Secrets.plist`.
    init(
        premiumManager: PremiumManager,
        featureFlagManager: FeatureFlagManager,
        adUnitIDProvider: AdUnitIDProviding = SecretsAdUnitIDProvider()
    ) {
        self.premiumManager = premiumManager
        self.featureFlagManager = featureFlagManager
        self.resolvedAdUnitIDs = AdUnitResolver.resolve(adUnitIDProvider)
        super.init()
    }

    // MARK: - Banner

    var bannerAdUnitID: String { resolvedAdUnitIDs.banner }

    /// Master gate: ads only show when CMS flag is ON and user is NOT premium.
    /// Fail-safe: if either dependency is unavailable, ads are DISABLED (safe direction).
    var shouldShowAds: Bool {
        featureFlagManager.isAdsEnabled && !premiumManager.isPremium
    }

    /// Interstitial frequency from CMS (default 4 = every 4 skips)
    private var interstitialFrequency: Int {
        featureFlagManager.adsSkipFrequency
    }

    // MARK: - Interstitial

    func preloadInterstitial() async {
        guard shouldShowAds else { return }
        do {
            interstitialAd = try await InterstitialAd.load(
                with: resolvedAdUnitIDs.interstitial,
                request: Request()
            )
            interstitialAd?.fullScreenContentDelegate = self
            isInterstitialReady = true
        } catch {
            Log.ads.error(
                "Failed to load interstitial: \(error.localizedDescription, privacy: .public)")
            isInterstitialReady = false
        }
    }

    /// Call after a skip action. Shows interstitial every `interstitialFrequency` skips.
    func recordSkipAndShowIfNeeded(from viewController: UIViewController? = nil) {
        guard shouldShowAds else { return }
        skipCount += 1
        guard skipCount >= interstitialFrequency else { return }
        skipCount = 0
        showInterstitial(from: viewController)
    }

    /// Show interstitial ad on-demand (e.g. after download completes)
    func showInterstitialNow(from viewController: UIViewController? = nil) {
        guard shouldShowAds else { return }
        showInterstitial(from: viewController)
    }

    private func showInterstitial(from viewController: UIViewController?) {
        guard let ad = interstitialAd,
            let vc = viewController ?? UIApplication.topViewController
        else {
            Task { await preloadInterstitial() }
            return
        }
        ad.present(from: vc)
    }
}

// MARK: - FullScreenContentDelegate

extension AdManager: FullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor [weak self] in
            self?.isInterstitialReady = false
            await self?.preloadInterstitial()
        }
    }

    nonisolated func ad(
        _ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.isInterstitialReady = false
            await self?.preloadInterstitial()
        }
    }
}

// MARK: - UIApplication Helper

extension UIApplication {
    /// Finds the topmost presented view controller by traversing the hierarchy.
    /// Handles UINavigationController, UITabBarController, and SwiftUI hosting controllers.
    fileprivate static var topViewController: UIViewController? {
        guard
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let root = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }

        return findTopViewController(from: root)
    }

    private static func findTopViewController(from vc: UIViewController) -> UIViewController {
        // Walk through presented view controllers first
        if let presented = vc.presentedViewController {
            return findTopViewController(from: presented)
        }
        // UINavigationController → use visible (topmost) child
        if let nav = vc as? UINavigationController,
            let visible = nav.visibleViewController
        {
            return findTopViewController(from: visible)
        }
        // UITabBarController → use selected tab's child
        if let tab = vc as? UITabBarController,
            let selected = tab.selectedViewController
        {
            return findTopViewController(from: selected)
        }
        return vc
    }
}

// MARK: - Log Category

extension Log {
    static let ads = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lovelymusic.app", category: "Ads")
}
