import SwiftUI

// MARK: - Page 1: Spinning Vinyl with Floating Notes

struct WelcomeIconView: View {
    var isActive: Bool = true
    @State private var isAppeared = false
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    var body: some View {
        ZStack {
            if !reduceMotion {
                floatingNotes
            }
            vinylRecord
        }
        .frame(width: 220, height: 220)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                isAppeared = true
            }
        }
    }

    private var vinylRecord: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isActive || reduceMotion)) { timeline in
            let rotation = (reduceMotion || !isActive) ? 0 : timeline.date.timeIntervalSinceReferenceDate * 30
            ZStack {
                // Outer disc
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(white: 0.18),
                                Color(white: 0.08),
                                Color(white: 0.14),
                                Color(white: 0.06),
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 90
                        )
                    )
                    .frame(width: 160, height: 160)
                    .overlay(
                        // Grooves
                        ZStack {
                            ForEach(0..<5, id: \.self) { i in
                                Circle()
                                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                                    .frame(
                                        width: CGFloat(70 + i * 16), height: CGFloat(70 + i * 16))
                            }
                        }
                    )
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                // Center artwork
                Circle()
                    .fill(Theme.Colors.brandGradient)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .overlay(
                        Circle().stroke(Theme.Colors.overlayDark, lineWidth: 2)
                    )

                // Center hole
                Circle()
                    .fill(Color.black.opacity(0.8))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            }
            .rotationEffect(.degrees(rotation))
            .drawingGroup()
        }
        .scaleEffect(isAppeared ? 1 : 0.5)
        .opacity(isAppeared ? 1 : 0)
    }

    private var floatingNotes: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<6, id: \.self) { i in
                    let angle = (t * 0.5 + Double(i) * .pi / 3)
                    let radius: CGFloat = 85 + CGFloat(sin(t * 0.8 + Double(i))) * 15
                    let x = cos(angle) * Double(radius)
                    let y = sin(angle) * Double(radius)
                    let noteOpacity = 0.3 + 0.3 * sin(t * 1.2 + Double(i) * 0.7)

                    Text(i % 2 == 0 ? "♪" : "♫")
                        .font(.system(size: CGFloat(14 + i * 2)))
                        .foregroundStyle(
                            Theme.Colors.brandGradientStart.opacity(noteOpacity)
                        )
                        .offset(x: CGFloat(x), y: CGFloat(y))
                        .rotationEffect(.degrees(t * 20 + Double(i * 60)))
                }
            }
            .drawingGroup()
        }
    }
}

// MARK: - Page 2: Pulsing Ripple / Sound Wave

struct DiscoverIconView: View {
    var isActive: Bool = true
    @State private var isAppeared = false
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    var body: some View {
        ZStack {
            if !reduceMotion {
                pulsingRipples
            } else {
                staticRipples
            }
            searchIcon
        }
        .frame(width: 220, height: 220)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                isAppeared = true
            }
        }
    }

    private var pulsingRipples: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    let phase = (t * 0.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 3.0)
                    let scale = 0.3 + phase * 0.35
                    let opacity = max(0, 0.35 - phase * 0.12)

                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Theme.Colors.brandGradientStart.opacity(opacity),
                                    Theme.Colors.brandGradientEnd.opacity(opacity * 0.6),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 200, height: 200)
                        .scaleEffect(CGFloat(scale))
                }
            }
            .drawingGroup()
        }
    }

    private var staticRipples: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(
                        Theme.Colors.brandGradientStart.opacity(0.15 - Double(i) * 0.04),
                        lineWidth: 1.5
                    )
                    .frame(width: CGFloat(80 + i * 40), height: CGFloat(80 + i * 40))
            }
        }
    }

    private var searchIcon: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.Colors.brandGradientStart.opacity(0.25),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 50
                    )
                )
                .frame(width: 90, height: 90)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Colors.brandGradient)
        }
        .scaleEffect(isAppeared ? 1 : 0.3)
        .opacity(isAppeared ? 1 : 0)
    }
}

// MARK: - Page 3: Stacked Album Cards with 3D Fan

struct LibraryIconView: View {
    var isActive: Bool = true
    @State private var isAppeared = false
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    private let cardColors: [LinearGradient] = [
        LinearGradient(
            colors: [Color(hex: "#6366F1"), Color(hex: "#8B5CF6")], startPoint: .topLeading,
            endPoint: .bottomTrailing),
        LinearGradient(
            colors: [Color(hex: "#EC4899"), Color(hex: "#F43F5E")], startPoint: .topLeading,
            endPoint: .bottomTrailing),
        LinearGradient(
            colors: [Color(hex: "#3B82F6"), Color(hex: "#06B6D4")], startPoint: .topLeading,
            endPoint: .bottomTrailing),
        LinearGradient(
            colors: [Color(hex: "#8B5CF6"), Color(hex: "#A855F7")], startPoint: .topLeading,
            endPoint: .bottomTrailing),
    ]

    private let cardIcons = ["music.note", "guitars", "pianokeys", "music.mic"]

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                let reverseIndex = 3 - i
                albumCard(index: reverseIndex)
            }
        }
        .frame(width: 220, height: 220)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.1)) {
                isAppeared = true
            }
        }
    }

    private func albumCard(index: Int) -> some View {
        let fanAngle: Double = isAppeared ? Double(index - 1) * (reduceMotion ? 5 : 8) : 0
        let yOffset: CGFloat = isAppeared ? CGFloat(index) * -4 : CGFloat(index) * -2
        let xOffset: CGFloat = isAppeared ? CGFloat(index - 1) * (reduceMotion ? 8 : 14) : 0

        return RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
            .fill(cardColors[index % cardColors.count])
            .frame(width: 100, height: 100)
            .overlay(
                Image(systemName: cardIcons[index % cardIcons.count])
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .rotation3DEffect(
                .degrees(isAppeared ? Double(index - 1) * (reduceMotion ? 3 : 6) : 0),
                axis: (x: 0.1, y: 1, z: 0),
                perspective: 0.4
            )
            .rotationEffect(.degrees(fanAngle))
            .offset(x: xOffset, y: yOffset)
            .scaleEffect(isAppeared ? 1 : 0.8)
            .opacity(isAppeared ? 1 : 0)
            .animation(
                .spring(response: 0.7, dampingFraction: 0.7)
                    .delay(Double(index) * 0.08),
                value: isAppeared
            )
    }
}

// MARK: - Page 4: Glowing Crown with Sparkles

struct PremiumIconView: View {
    var isActive: Bool = true
    @State private var isAppeared = false
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    var body: some View {
        ZStack {
            if !reduceMotion {
                sparkles
                glowEffect
            } else {
                staticGlow
            }
            crownIcon
        }
        .frame(width: 220, height: 220)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                isAppeared = true
            }
        }
    }

    private var glowEffect: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulseScale = 1.0 + 0.08 * sin(t * 2.0)
            let pulseOpacity = 0.25 + 0.1 * sin(t * 1.5)

            // Round 2 Q2: gold scoped to paywall only — onboarding crown uses brand purple.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.Colors.brandGradientStart.opacity(pulseOpacity),
                            Theme.Colors.brandGradientEnd.opacity(pulseOpacity * 0.5),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .scaleEffect(CGFloat(pulseScale))
                .drawingGroup()
        }
    }

    private var staticGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Theme.Colors.brandGradientStart.opacity(0.2),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 100
                )
            )
            .frame(width: 200, height: 200)
    }

    private var sparkles: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let angle = Double(i) * .pi / 4.0 + t * 0.3
                    let dist: CGFloat = 70 + CGFloat(sin(t * 1.5 + Double(i))) * 15
                    let sparkleOpacity = 0.4 + 0.4 * sin(t * 2.5 + Double(i) * 0.9)
                    let sparkleScale = 0.5 + 0.5 * sin(t * 2.0 + Double(i) * 1.1)

                    Image(systemName: "sparkle")
                        .font(.system(size: 10 + CGFloat(i % 3) * 3))
                        .foregroundStyle(
                            i % 2 == 0
                                ? Theme.Colors.brandGradientStart.opacity(sparkleOpacity)
                                : Theme.Colors.brandGradientEnd.opacity(sparkleOpacity)
                        )
                        .scaleEffect(CGFloat(sparkleScale))
                        .offset(
                            x: cos(angle) * Double(dist),
                            y: sin(angle) * Double(dist)
                        )
                }
            }
            .drawingGroup()
        }
    }

    private var crownIcon: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 56, weight: .light))
            .foregroundStyle(Theme.Colors.brandGradient)
            .shadow(color: Theme.Colors.brandGradientStart.opacity(0.4), radius: 16, y: 0)
            .scaleEffect(isAppeared ? 1 : 0.4)
            .opacity(isAppeared ? 1 : 0)
    }
}
