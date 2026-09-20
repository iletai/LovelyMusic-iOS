import SwiftUI

// MARK: - Worm-Style Page Indicator

struct OnboardingWormIndicator: View {
    let pageCount: Int
    let currentPage: Int

    private let dotSize: CGFloat = 8
    private let expandedWidth: CGFloat = 28
    private let spacing: CGFloat = 10

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(
                        index == currentPage
                            ? AnyShapeStyle(Theme.Colors.brandGradient)
                            : AnyShapeStyle(Color.white.opacity(0.25))
                    )
                    .frame(
                        width: index == currentPage ? expandedWidth : dotSize,
                        height: dotSize
                    )
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.7),
                        value: currentPage
                    )
            }
        }
    }
}

// MARK: - Animated Gradient Text

struct AnimatedGradientText: View {
    let text: LocalizedStringKey
    let font: Font
    let pageIndex: Int

    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    private var gradientColors: [Color] {
        // Q2: gold scoped to paywall only — all onboarding pages use brand purple.
        return [
            Theme.Colors.brandGradientStart, Theme.Colors.brandGradientEnd,
            Theme.Colors.brandGradientStart,
        ]
    }

    var body: some View {
        if reduceMotion {
            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(
                        colors: Array(gradientColors.prefix(2)),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .multilineTextAlignment(.center)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let offset = CGFloat(sin(t * 0.5)) * 0.3 + 0.5

                Text(text)
                    .font(font)
                    .foregroundStyle(
                        LinearGradient(
                            colors: gradientColors,
                            startPoint: UnitPoint(x: offset - 0.3, y: 0),
                            endPoint: UnitPoint(x: offset + 0.7, y: 1)
                        )
                    )
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Stagger-In Content Wrapper

struct StaggeredContentView<Icon: View>: View {
    let icon: Icon
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let pageIndex: Int
    let isActive: Bool

    @State private var showIcon = false
    @State private var showTitle = false
    @State private var showSubtitle = false
    @State private var floatOffset: CGFloat = 0

    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    init(
        @ViewBuilder icon: () -> Icon,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        pageIndex: Int,
        isActive: Bool
    ) {
        self.icon = icon()
        self.title = title
        self.subtitle = subtitle
        self.pageIndex = pageIndex
        self.isActive = isActive
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            // Animated icon
            icon
                .scaleEffect(showIcon ? 1 : 0.6)
                .opacity(showIcon ? 1 : 0)
                .offset(y: reduceMotion ? 0 : floatOffset)

            VStack(spacing: Theme.Spacing.md) {
                // Gradient animated title
                AnimatedGradientText(
                    text: title,
                    font: Theme.Typography.largeTitle,
                    pageIndex: pageIndex
                )
                .opacity(showTitle ? 1 : 0)
                .offset(y: showTitle ? 0 : 16)

                // Subtitle
                Text(subtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .opacity(showSubtitle ? 1 : 0)
                    .offset(y: showSubtitle ? 0 : 12)
            }

            Spacer()
            Spacer()
        }
        .onChange(of: isActive) { _, active in
            if active {
                animateIn()
            } else {
                resetState()
            }
        }
        .onAppear {
            if isActive {
                animateIn()
            }
            if !reduceMotion {
                startFloating()
            }
        }
    }

    private func animateIn() {
        showIcon = false
        showTitle = false
        showSubtitle = false

        let baseDelay = reduceMotion ? 0.0 : 0.1
        let stagger = reduceMotion ? 0.05 : 0.15

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(baseDelay)) {
            showIcon = true
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(baseDelay + stagger)) {
            showTitle = true
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(baseDelay + stagger * 2)) {
            showSubtitle = true
        }
    }

    private func resetState() {
        showIcon = false
        showTitle = false
        showSubtitle = false
    }

    private func startFloating() {
        withAnimation(
            .easeInOut(duration: 3.0)
                .repeatForever(autoreverses: true)
        ) {
            floatOffset = -6
        }
    }
}

// MARK: - Pulsing Button Glow

struct PulsingGlowButtonStyle: ButtonStyle {
    let isActive: Bool
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .background(
                Group {
                    if isActive && !reduceMotion {
                        PulsingGlowBackground()
                    }
                }
            )
    }
}

private struct PulsingGlowBackground: View {
    @State private var glowScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
            .fill(Theme.Colors.brandGradient)
            .scaleEffect(glowScale)
            .opacity(glowOpacity)
            .blur(radius: 12)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.5)
                        .repeatForever(autoreverses: true)
                ) {
                    glowScale = 1.08
                    glowOpacity = 0.5
                }
            }
    }
}
