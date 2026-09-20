import SwiftUI

// MARK: - Particle Model

struct OnboardingParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var opacity: Double
    var speed: CGFloat
    var symbol: String
    var rotation: Double
    var rotationSpeed: Double
    var horizontalDrift: CGFloat
}

// MARK: - Particle System View

struct OnboardingParticleSystemView: View {
    let symbols: [String]
    let particleCount: Int
    let baseColor: Color

    @State private var particles: [OnboardingParticle] = []
    @State private var time: TimeInterval = 0

    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    init(
        symbols: [String] = ["♪", "♫", "♬", "✦", "◆"],
        particleCount: Int = 25,
        baseColor: Color = Theme.Colors.brandGradientStart
    ) {
        self.symbols = symbols
        self.particleCount = particleCount
        self.baseColor = baseColor
    }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                Canvas { context, size in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    for particle in particles {
                        let yOffset = (elapsed * particle.speed).truncatingRemainder(
                            dividingBy: Double(size.height + 60))
                        let adjustedY = particle.y - CGFloat(yOffset)
                        let wrappedY = adjustedY < -30 ? adjustedY + size.height + 60 : adjustedY

                        let xWave =
                            sin(elapsed * Double(particle.horizontalDrift) + Double(particle.x))
                            * 20
                        let adjustedX = particle.x + CGFloat(xWave)

                        let rot = Angle.degrees(elapsed * particle.rotationSpeed)

                        var textContext = context
                        textContext.opacity = particle.opacity
                        let text = Text(particle.symbol)
                            .font(.system(size: particle.size))
                            .foregroundStyle(baseColor.opacity(particle.opacity))

                        textContext.translateBy(x: adjustedX, y: wrappedY)
                        textContext.rotate(by: rot)
                        textContext.draw(text, at: .zero)
                    }
                }
                .drawingGroup()
            }
            .ignoresSafeArea()
            .onAppear { generateParticles() }
        }
    }

    private func generateParticles() {
        let screenW = UIScreen.main.bounds.width
        let screenH = UIScreen.main.bounds.height
        particles = (0..<particleCount).map { _ in
            OnboardingParticle(
                x: CGFloat.random(in: 0...screenW),
                y: CGFloat.random(in: 0...screenH),
                size: CGFloat.random(in: 8...18),
                opacity: Double.random(in: 0.08...0.25),
                speed: CGFloat.random(in: 8...25),
                symbol: symbols.randomElement() ?? "♪",
                rotation: Double.random(in: 0...360),
                rotationSpeed: Double.random(in: -30...30),
                horizontalDrift: CGFloat.random(in: 0.3...1.2)
            )
        }
    }
}

// MARK: - Animated Gradient Mesh Background

struct OnboardingGradientMeshView: View {
    let pageIndex: Int
    let pageCount: Int
    let dragOffset: CGFloat

    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    private var pageColors: [[Color]] {
        // Q2: gold scoped to paywall only — final onboarding page uses brand palette.
        [
            [
                Theme.Colors.brandGradientStart, Theme.Colors.brandGradientEnd,
                Color(hex: "#4F46E5"),
            ],
            [Color(hex: "#3B82F6"), Theme.Colors.brandGradientStart, Color(hex: "#6366F1")],
            [
                Color(hex: "#6366F1"), Theme.Colors.brandGradientEnd,
                Theme.Colors.brandGradientStart,
            ],
            [
                Theme.Colors.brandGradientStart, Theme.Colors.brandGradientEnd,
                Color(hex: "#4F46E5"),
            ],
        ]
    }

    private var currentColors: [Color] {
        guard pageIndex < pageColors.count else { return pageColors[0] }
        return pageColors[pageIndex]
    }

    var body: some View {
        if reduceMotion {
            staticBackground
        } else {
            animatedBackground
        }
    }

    private var staticBackground: some View {
        ZStack {
            Theme.Colors.backgroundPrimary
            RadialGradient(
                colors: [currentColors[0].opacity(0.15), .clear],
                center: .center,
                startRadius: 50,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: pageIndex)
    }

    private var animatedBackground: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(hex: "#0A0A0A"))
                )

                let normalizedDrag = dragOffset / size.width

                for (i, color) in currentColors.enumerated() {
                    let phase = t * 0.3 + Double(i) * 2.1
                    let cx = size.width * (0.3 + 0.4 * CGFloat(sin(phase))) + normalizedDrag * 30
                    let cy = size.height * (0.2 + 0.3 * CGFloat(cos(phase * 0.7 + Double(i))))
                    let radius =
                        min(size.width, size.height) * CGFloat(0.4 + 0.1 * sin(phase * 0.5))

                    let gradient = Gradient(colors: [
                        color.opacity(0.18), color.opacity(0.05), .clear,
                    ])
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: cx - radius, y: cy - radius,
                                width: radius * 2, height: radius * 1.5
                            )),
                        with: .radialGradient(
                            gradient,
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: pageIndex)
    }
}
