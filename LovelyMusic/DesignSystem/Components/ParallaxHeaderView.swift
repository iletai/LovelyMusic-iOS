import SwiftUI

/// Parallax scroll header used by Playlist, Album, Artist detail pages.
///
/// Rewritten (Apr 2026) to use `.visualEffect` instead of a root
/// `GeometryReader`. `GeometryReader` invalidates layout on each scroll
/// frame because it publishes its proxy value through `body`;
/// `.visualEffect` runs on the render thread only, leaving layout stable.
/// Scale / offset / opacity are the only transforms needed, all of which
/// `visualEffect` supports.
///
/// Respects Reduce Motion — all stretch / scale / fade gestures collapse
/// to a static header when the user has opted out of non-essential motion.
struct ParallaxHeaderView<Content: View>: View {
    let thumbnailURL: String?
    let height: CGFloat
    let isCircular: Bool
    let topInset: CGFloat
    let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        thumbnailURL: String?,
        height: CGFloat = 380,
        isCircular: Bool = false,
        topInset: CGFloat = 0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.thumbnailURL = thumbnailURL
        self.height = height
        self.isCircular = isCircular
        self.topInset = topInset
        self.content = content
    }

    private var thumbnailSize: CGFloat {
        isCircular ? 200 : 260
    }

    private var thumbnailCorner: CGFloat {
        isCircular ? 100 : Theme.CornerRadius.medium
    }

    private var totalHeight: CGFloat { height + topInset }

    var body: some View {
        ZStack(alignment: .bottom) {
            thumbnailBackground
                .frame(maxWidth: .infinity)
                .frame(height: totalHeight)
                .visualEffect { [reduceMotion] content, proxy in
                    let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    // Reduce Motion: collapse parallax to identity (no
                    // stretch/scale). We still return the same effect type
                    // from both branches so the closure type-checks.
                    let isStretching = minY > 0 && !reduceMotion
                    let scale: CGFloat = isStretching ? 1 + (minY / 800) : 1.0
                    let offset: CGFloat = isStretching ? -minY / 2 : 0
                    return
                        content
                        .scaleEffect(scale, anchor: .bottom)
                        .offset(y: offset)
                }
                .clipped()

            foregroundContent
                .visualEffect { [reduceMotion] content, proxy in
                    let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    // Reduce Motion: identity transform, full opacity.
                    let scale: CGFloat
                    let fadeOpacity: Double
                    if reduceMotion {
                        scale = 1.0
                        fadeOpacity = 1.0
                    } else {
                        scale =
                            minY > 0
                            ? CGFloat(1) + (minY / 1200)
                            : max(CGFloat(0.85), CGFloat(1) + (minY / 600))
                        fadeOpacity =
                            minY > 0
                            ? 1.0
                            : max(0, 1 + Double(minY) / 250)
                    }
                    return
                        content
                        .scaleEffect(scale, anchor: .bottom)
                        .opacity(fadeOpacity)
                }
        }
        .frame(height: totalHeight)
        .contentShape(Rectangle())
    }

    private var foregroundContent: some View {
        VStack(spacing: Theme.Spacing.md) {
            AsyncThumbnail(
                url: thumbnailURL,
                size: thumbnailSize,
                cornerRadius: thumbnailCorner
            )
            .shadow(
                color: Theme.Colors.brandGradientStart.opacity(0.25),
                radius: 24,
                y: 12
            )

            content()
        }
        .padding(.top, topInset)
        .padding(.bottom, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var thumbnailBackground: some View {
        if let url = thumbnailURL, let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 18)
                        .overlay(backgroundGradient)
                        .transition(.opacity)
                case .failure:
                    fallbackBackground
                case .empty:
                    fallbackBackground
                @unknown default:
                    fallbackBackground
                }
            }
        } else {
            fallbackBackground
        }
    }

    /// Round 2: luminance-aware fade strip. The cover renders at full saturation;
    /// only the bottom edge fades into `backgroundPrimary` so the page scroll body
    /// blends seamlessly. No more brand-tinted lavender wash overpowering artwork.
    private var backgroundGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.55),
                .init(color: Theme.Colors.backgroundPrimary.opacity(0.7), location: 0.85),
                .init(color: Theme.Colors.backgroundPrimary, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var fallbackBackground: some View {
        LinearGradient(
            colors: [
                Theme.Colors.backgroundSecondary,
                Theme.Colors.backgroundPrimary,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
