import SwiftUI

struct SeasonalParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var speed: CGFloat
    var size: CGFloat
    var opacity: Double
    var swayOffset: CGFloat
    var swaySpeed: CGFloat
}

struct SeasonalParticleView: View {
    let preset: SeasonalThemePreset?
    let count: Int
    let speedMultiplier: Double
    let durationSeconds: Double

    @Environment(\.colorScheme) private var colorScheme
    @State private var particles: [SeasonalParticle] = []
    @State private var overallOpacity: Double = 1.0

    init(
        preset: SeasonalThemePreset?,
        count: Int = 18,
        speedMultiplier: Double = 1.0,
        durationSeconds: Double = 0
    ) {
        self.preset = preset
        self.count = count
        self.speedMultiplier = max(0.2, speedMultiplier)
        self.durationSeconds = durationSeconds
    }

    var body: some View {
        GeometryReader { geo in
            if overallOpacity > 0.01 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        guard !particles.isEmpty else { return }
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        let isDark = colorScheme == .dark

                        for particle in particles {
                            let sway = sin(now * particle.swaySpeed * speedMultiplier + particle.swayOffset) * 15
                            let currentX = (particle.x * size.width + sway).truncatingRemainder(dividingBy: size.width)
                            let currentY = (particle.y * size.height + (now * particle.speed * 40 * speedMultiplier)).truncatingRemainder(dividingBy: size.height)

                            let rect = CGRect(
                                x: currentX,
                                y: currentY,
                                width: particle.size,
                                height: particle.size
                            )

                            var innerContext = context
                            innerContext.opacity = (isDark ? particle.opacity : (particle.opacity * 0.85)) * overallOpacity

                            switch preset {
                            case .christmas:
                                // Dark: white snowflakes. Light: soft ice-blue crystals.
                                innerContext.fill(
                                    Circle().path(in: rect),
                                    with: .color(isDark ? Color.white.opacity(0.85) : Color(hex: "#60A5FA").opacity(0.55))
                                )
                            case .newYear, .tet:
                                // Dark: bright gold / light red. Light: rich gold / crimson.
                                let gold = isDark ? Color(hex: "#FFD166") : Color(hex: "#D97706")
                                let red = isDark ? Color(hex: "#FF4D6D") : Color(hex: "#DC2626")
                                innerContext.fill(
                                    Circle().path(in: rect),
                                    with: .color(particle.speed > 0.6 ? gold : red)
                                )
                            case .autumn, .afternoon:
                                // Dark: copper. Light: rich terracotta.
                                let autumnColor = isDark ? Color(hex: "#FB923C") : Color(hex: "#C2410C")
                                innerContext.fill(
                                    RoundedRectangle(cornerRadius: 2).path(in: rect),
                                    with: .color(autumnColor.opacity(0.75))
                                )
                            case .valentine:
                                // Dark: soft rose. Light: crimson rose.
                                let heartColor = isDark ? Color(hex: "#FF758F") : Color(hex: "#E11D48")
                                innerContext.fill(
                                    Circle().path(in: rect),
                                    with: .color(heartColor.opacity(0.75))
                                )
                            case .halloween:
                                let orange = isDark ? Color(hex: "#FF7518") : Color(hex: "#EA580C")
                                let purple = isDark ? Color(hex: "#A855F7") : Color(hex: "#7E22CE")
                                innerContext.fill(
                                    Circle().path(in: rect),
                                    with: .color(particle.speed > 0.5 ? orange : purple)
                                )
                            case .summer, .morning:
                                let sunColor = isDark ? Color(hex: "#38BDF8") : Color(hex: "#0284C7")
                                innerContext.fill(
                                    Circle().path(in: rect),
                                    with: .color(sunColor.opacity(0.65))
                                )
                            case .evening, .night:
                                let starColor = isDark ? Color(hex: "#A78BFA") : Color(hex: "#7C3AED")
                                innerContext.fill(
                                    Circle().path(in: rect),
                                    with: .color(starColor.opacity(0.7))
                                )
                            case .spring, .none:
                                let blossom = isDark ? Color(hex: "#F472B6") : Color(hex: "#DB2777")
                                innerContext.fill(
                                    Circle().path(in: rect),
                                    with: .color(blossom.opacity(0.7))
                                )
                            }
                        }
                    }
                }
                .opacity(overallOpacity)
                .onAppear {
                    seedParticles()
                    scheduleDismissIfNeeded()
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func seedParticles() {
        particles = (0..<count).map { _ in
            SeasonalParticle(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                speed: CGFloat.random(in: 0.3...1.0),
                size: CGFloat.random(in: 3...7),
                opacity: Double.random(in: 0.3...0.85),
                swayOffset: CGFloat.random(in: 0...(.pi * 2)),
                swaySpeed: CGFloat.random(in: 0.8...2.2)
            )
        }
    }

    private func scheduleDismissIfNeeded() {
        guard durationSeconds > 0 else { return }
        let fadeDelay = max(0.5, durationSeconds - 2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay) {
            withAnimation(.easeOut(duration: 2.0)) {
                overallOpacity = 0.0
            }
        }
    }
}
