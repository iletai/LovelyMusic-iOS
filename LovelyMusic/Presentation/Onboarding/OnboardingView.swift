import SwiftUI

struct OnboardingView: View {
    @State private var currentPage = 0
    @State private var dragOffset: CGFloat = 0
    @State private var buttonScale: CGFloat = 1.0

    var onComplete: () -> Void

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to LovelyMusic",
            subtitle: "Discover and stream millions of songs for free",
            particleSymbols: ["♪", "♫", "♬", "♩"]
        ),
        OnboardingPage(
            title: "Discover Music",
            subtitle: "Search millions of songs, albums, and artists",
            particleSymbols: ["◉", "◎", "○", "●"]
        ),
        OnboardingPage(
            title: "Your Library",
            subtitle: "Save playlists, track history, and build your collection",
            particleSymbols: ["▪", "◆", "■", "◇"]
        ),
        OnboardingPage(
            title: "Premium Experience",
            subtitle: "Equalizer, lyrics, high quality audio & more",
            particleSymbols: ["✦", "✧", "★", "⟡"]
        ),
    ]

    private var isLastPage: Bool {
        currentPage == pages.count - 1
    }

    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    var body: some View {
        ZStack {
            // Layer 1: Animated gradient mesh background
            OnboardingGradientMeshView(
                pageIndex: currentPage,
                pageCount: pages.count,
                dragOffset: dragOffset
            )

            // Layer 2: Floating particles — Q2: gold paywall-only, brand purple here.
            OnboardingParticleSystemView(
                symbols: pages[currentPage].particleSymbols,
                particleCount: reduceMotion ? 0 : 25,
                baseColor: Theme.Colors.brandGradientStart
            )
            .id(currentPage)

            // Layer 3: Main content
            VStack(spacing: 0) {
                skipButton

                // Paged content with parallax
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageContent(page: page, index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.85),
                    value: currentPage
                )

                // Worm-style page indicator
                OnboardingWormIndicator(
                    pageCount: pages.count,
                    currentPage: currentPage
                )
                .padding(.bottom, Theme.Spacing.xxl)

                actionButton
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Skip Button

    private var skipButton: some View {
        HStack {
            Spacer()
            if !isLastPage {
                Button {
                    onComplete()
                } label: {
                    Text("Skip")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.overlayUltraLight)
                        )
                }
                .padding(.trailing, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
                .transition(.opacity)
            } else {
                Color.clear.frame(height: 20)
                    .padding(.top, Theme.Spacing.sm)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isLastPage)
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageContent(page: OnboardingPage, index: Int) -> some View {
        StaggeredContentView(
            icon: { iconForPage(index: index) },
            title: page.title,
            subtitle: page.subtitle,
            pageIndex: index,
            isActive: currentPage == index
        )
    }

    @ViewBuilder
    private func iconForPage(index: Int) -> some View {
        let active = currentPage == index
        switch index {
        case 0: WelcomeIconView(isActive: active)
        case 1: DiscoverIconView(isActive: active)
        case 2: LibraryIconView(isActive: active)
        case 3: PremiumIconView(isActive: active)
        default: EmptyView()
        }
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button {
            if isLastPage {
                onComplete()
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    currentPage += 1
                }
            }
        } label: {
            Text(
                isLastPage
                    ? String(localized: "Get Started")
                    : String(localized: "Next")
            )
            .font(Theme.Typography.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            // Q2: gold paywall-only — onboarding CTA stays brand on every page.
            .background(AnyShapeStyle(Theme.Colors.brandGradient))
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        }
        .buttonStyle(PulsingGlowButtonStyle(isActive: isLastPage))
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xxxl)
        .animation(.easeInOut(duration: 0.4), value: isLastPage)
    }
}

// MARK: - Page Model

private struct OnboardingPage {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let particleSymbols: [String]
}
