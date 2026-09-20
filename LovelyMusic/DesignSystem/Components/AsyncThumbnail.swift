import SwiftUI
import NukeUI
import Nuke

struct AsyncThumbnail: View {
    let url: String?
    let size: CGFloat
    let cornerRadius: CGFloat
    // Use Environment for non-deprecated display scale instead of UIScreen.main.scale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scrollPhase) private var scrollPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(FeatureFlagManager.self) private var featureFlags

    init(url: String?, size: CGFloat = 48, cornerRadius: CGFloat = Theme.CornerRadius.small) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let url, let imageURL = thumbnailURL(url) {
                LazyImage(request: imageRequest(for: imageURL)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity.animation(.easeInOut(duration: fadeDuration)))
                    } else if state.error != nil {
                        placeholder
                    } else {
                        shimmerPlaceholder
                            .transition(.opacity)
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Fade-in duration driven by scroll state + a11y:
    /// - Reduce Motion: instant (0s) — no crossfade.
    /// - Decelerating (fling) with flag on: 60ms quick fade — avoids pop-in
    ///   when dozens of thumbnails resolve within one 16ms frame.
    /// - Otherwise: 200ms standard fade.
    private var fadeDuration: Double {
        if reduceMotion { return 0 }
        if featureFlags.scrollFastFadeDuringFling && scrollPhase.isFlinging {
            return 0.06
        }
        return 0.20
    }

    /// Shimmer with optional 3s timeout → music-note fallback. Prevents
    /// indefinite shimmer from reading as "app is broken" when the image
    /// request stalls silently. Gate behind the CMS flag so we can disable
    /// the timeout remotely if it proves too aggressive on slow networks.
    @ViewBuilder
    private var shimmerPlaceholder: some View {
        if featureFlags.scrollShimmerTimeoutEnabled {
            ShimmerView()
                .shimmerTimeout(seconds: 3) {
                    placeholder
                }
        } else {
            ShimmerView()
        }
    }

    /// Build ImageRequest with resize processor matching display size
    private func imageRequest(for url: URL) -> ImageRequest {
        ImageRequest(
            url: url,
            processors: [.resize(size: CGSize(width: size, height: size), contentMode: .aspectFill, crop: true)]
        )
    }

    /// Server-side resize for Google-hosted thumbnails.
    /// lh3.googleusercontent.com and yt3.ggpht.com support =w{size} suffix.
    /// i.ytimg.com uses path-based sizing — don't modify.
    private func thumbnailURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
            let scheme = url.scheme,
            scheme == "http" || scheme == "https"
        else {
            return nil
        }
        if urlString.contains("lh3.googleusercontent.com") || urlString.contains("yt3.ggpht.com") {
            let pixelSize = Int(size * displayScale)
            // Strip everything from '=' onwards, then append =w{size}
            let base = urlString.replacingOccurrences(of: #"=.*$"#, with: "", options: .regularExpression)
            return URL(string: "\(base)=w\(pixelSize)")
        }
        return url
    }

    private var placeholder: some View {
        ZStack {
            Color(light: Color(hex: "#C5BEE3"), dark: Color.white.opacity(0.04))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.3))
                .foregroundStyle(Color(light: Color(hex: "#8B5CF6").opacity(0.40), dark: Color.white.opacity(0.15)))
        }
    }
}

