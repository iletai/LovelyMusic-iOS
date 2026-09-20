import SwiftUI
import GoogleMobileAds

/// A SwiftUI wrapper for a GADBannerView that displays Google AdMob anchored adaptive banner ads.
/// Uses `currentOrientationAnchoredAdaptiveBanner(width:)` per the latest SDK API.
struct BannerAdView: UIViewRepresentable {
    let adUnitID: String
    let width: CGFloat
    /// When true, disables AdMob's auto-refresh to reduce ad requests.
    /// Use for inline feed ads that scroll in/out quickly.
    let disableAutoRefresh: Bool

    init(adUnitID: String, width: CGFloat = UIScreen.main.bounds.width, disableAutoRefresh: Bool = false) {
        self.adUnitID = adUnitID
        self.width = width
        self.disableAutoRefresh = disableAutoRefresh
    }

    func makeUIView(context: Context) -> BannerView {
        let adSize = currentOrientationAnchoredAdaptiveBanner(width: width)
        let bannerView = BannerView(adSize: adSize)
        bannerView.adUnitID = adUnitID
        bannerView.delegate = context.coordinator
        if disableAutoRefresh {
            bannerView.isAutoloadEnabled = false
        }
        // rootViewController set in updateUIView to stay current
        return bannerView
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        // Refresh rootViewController each update cycle so it stays current
        // across iPad split-view / stage manager transitions.
        let currentRoot = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: \.isKeyWindow)?.rootViewController
        if uiView.rootViewController !== currentRoot {
            uiView.rootViewController = currentRoot
        }
        // Load ad only once per view lifecycle. Skip if already filled or previously loaded.
        // This prevents excessive ad requests when multiple InlineFeedAdViews exist in a feed.
        if context.coordinator.needsInitialLoad && !context.coordinator.hasReceivedAd {
            context.coordinator.needsInitialLoad = false
            uiView.load(Request())
        }
    }

    func makeCoordinator() -> BannerCoordinator {
        BannerCoordinator()
    }
}

// MARK: - Coordinator

final class BannerCoordinator: NSObject, BannerViewDelegate {
    /// Ensures we only load once per view lifecycle, not on every updateUIView.
    var needsInitialLoad = true
    /// Track whether this view has a filled ad to avoid re-requests on reappear.
    var hasReceivedAd = false

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        hasReceivedAd = true
    }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        Log.ads.error("Banner ad failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Inline Feed Ad (between list items)

/// A banner ad styled to blend into a vertical feed/list.
/// Insert between ForEach items at regular intervals.
///
/// Reads AdManager from the Environment instead of DIContainer to avoid
/// architecture violations (DesignSystem should not depend on App layer).
struct InlineFeedAdView: View {
    @Environment(AdManager.self) private var adManager

    var body: some View {
        if adManager.shouldShowAds {
            BannerAdView(adUnitID: adManager.bannerAdUnitID, disableAutoRefresh: true)
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

// MARK: - View Modifier (bottom banner)

/// Convenience modifier to show a banner ad at the bottom of any view.
struct BannerAdModifier: ViewModifier {
    @Environment(AdManager.self) private var adManager
    let adUnitID: String

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if adManager.shouldShowAds {
                    GeometryReader { geo in
                        let adSize = currentOrientationAnchoredAdaptiveBanner(width: geo.size.width)
                        BannerAdView(adUnitID: adUnitID, width: geo.size.width)
                            .frame(width: adSize.size.width, height: adSize.size.height)
                    }
                    .frame(height: 50)
                    .background(Theme.Colors.backgroundPrimary)
                }
            }
    }
}

extension View {
    /// Attach a banner ad to the bottom of this view. Hidden for premium users.
    func bannerAd(unitID: String) -> some View {
        modifier(BannerAdModifier(adUnitID: unitID))
    }
}
