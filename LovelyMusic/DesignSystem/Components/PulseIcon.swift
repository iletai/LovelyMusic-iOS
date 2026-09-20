import SwiftUI

/// LovelyMusic's bespoke 24pt icon family, based on the Stitch "Pulse Line" system.
struct PulseIcon: View {
    let kind: PulseIconKind
    let size: CGFloat
    let color: Color
    let usesBrandGradient: Bool
    let lineWidth: CGFloat

    init(
        _ kind: PulseIconKind,
        size: CGFloat = Theme.SizeTokens.iconMedium,
        color: Color = Theme.Colors.textSecondary,
        usesBrandGradient: Bool = false,
        lineWidth: CGFloat = 1.75
    ) {
        self.kind = kind
        self.size = size
        self.color = color
        self.usesBrandGradient = usesBrandGradient
        self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { context, canvasSize in
            draw(in: &context, canvasSize: canvasSize)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, canvasSize: CGSize) {
        let unit = min(canvasSize.width, canvasSize.height) / 24
        let origin = CGPoint(
            x: (canvasSize.width - (24 * unit)) / 2,
            y: (canvasSize.height - (24 * unit)) / 2
        )
        let shading = shading(in: canvasSize)
        let strokeStyle = StrokeStyle(
            lineWidth: lineWidth * unit,
            lineCap: .round,
            lineJoin: .round
        )

        switch kind {
        case .home:
            context.stroke(
                homePath(origin: origin, unit: unit),
                with: shading,
                style: strokeStyle
            )
        case .search:
            context.stroke(
                searchPath(origin: origin, unit: unit),
                with: shading,
                style: strokeStyle
            )
        case .library:
            for path in libraryPaths(origin: origin, unit: unit) {
                context.stroke(path, with: shading, style: strokeStyle)
            }
        case .previous, .next:
            for path in skipPaths(origin: origin, unit: unit) {
                context.fill(path, with: shading)
            }
        case .play:
            context.fill(playPath(origin: origin, unit: unit), with: shading)
        case .pause:
            for path in pausePaths(origin: origin, unit: unit) {
                context.fill(path, with: shading)
            }
        }
    }

    private func shading(in canvasSize: CGSize) -> GraphicsContext.Shading {
        if usesBrandGradient {
            .linearGradient(
                Gradient(colors: [
                    Theme.Colors.brandGradientStart,
                    Theme.Colors.brandGradientEnd,
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)
            )
        } else {
            .color(color)
        }
    }

    private func homePath(origin: CGPoint, unit: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(2.8, 10.4, origin: origin, unit: unit))
        path.addLine(to: point(12, 2.9, origin: origin, unit: unit))
        path.addLine(to: point(21.2, 10.4, origin: origin, unit: unit))

        path.move(to: point(4.5, 9, origin: origin, unit: unit))
        path.addLine(to: point(4.5, 20.5, origin: origin, unit: unit))
        path.addLine(to: point(19.5, 20.5, origin: origin, unit: unit))
        path.addLine(to: point(19.5, 9, origin: origin, unit: unit))

        // A single pulse cut keeps the destination recognisable while adding
        // LovelyMusic's sonic signature.
        path.move(to: point(7.6, 13, origin: origin, unit: unit))
        path.addLine(to: point(9.5, 13, origin: origin, unit: unit))
        path.addLine(to: point(10.7, 10.2, origin: origin, unit: unit))
        path.addLine(to: point(12.3, 15.7, origin: origin, unit: unit))
        path.addLine(to: point(13.7, 12, origin: origin, unit: unit))
        path.addLine(to: point(16.3, 12, origin: origin, unit: unit))
        return path
    }

    private func searchPath(origin: CGPoint, unit: CGFloat) -> Path {
        var path = Path()
        path.addEllipse(in: rect(4, 4, 12.5, 12.5, origin: origin, unit: unit))
        path.move(to: point(14.6, 14.6, origin: origin, unit: unit))
        path.addLine(to: point(20.3, 20.3, origin: origin, unit: unit))

        // The subtle four-point accent is present in every state, so selection
        // never changes the destination's meaning.
        path.move(to: point(18.5, 3.3, origin: origin, unit: unit))
        path.addLine(to: point(18.5, 7.1, origin: origin, unit: unit))
        path.move(to: point(16.6, 5.2, origin: origin, unit: unit))
        path.addLine(to: point(20.4, 5.2, origin: origin, unit: unit))
        return path
    }

    private func libraryPaths(origin: CGPoint, unit: CGFloat) -> [Path] {
        // Only the exposed top/right edges of the rear sleeves are drawn.
        // Complete overlapping outlines become visually dense at 20–24pt and
        // can read as a camera or container instead of an album collection.
        var back = Path()
        back.move(to: point(10, 3, origin: origin, unit: unit))
        back.addLine(to: point(18, 3, origin: origin, unit: unit))
        back.addQuadCurve(
            to: point(20, 5, origin: origin, unit: unit),
            control: point(20, 3, origin: origin, unit: unit)
        )
        back.addLine(to: point(20, 17, origin: origin, unit: unit))

        var middle = Path()
        middle.move(to: point(7.8, 5, origin: origin, unit: unit))
        middle.addLine(to: point(16.6, 5, origin: origin, unit: unit))
        middle.addQuadCurve(
            to: point(18.7, 7.1, origin: origin, unit: unit),
            control: point(18.7, 5, origin: origin, unit: unit)
        )
        middle.addLine(to: point(18.7, 19.8, origin: origin, unit: unit))

        let front = Path(
            roundedRect: rect(3.5, 7, 13.5, 14, origin: origin, unit: unit),
            cornerRadius: 2.2 * unit
        )
        return [back, middle, front]
    }

    private func skipPaths(origin: CGPoint, unit: CGFloat) -> [Path] {
        let isPrevious = kind == .previous
        let barX: CGFloat = isPrevious ? 4.3 : 17.7
        let bar = Path(
            roundedRect: rect(barX, 5.2, 2.4, 13.6, origin: origin, unit: unit),
            cornerRadius: 1.2 * unit
        )

        var triangle = Path()
        if isPrevious {
            triangle.move(to: point(18.8, 5.2, origin: origin, unit: unit))
            triangle.addLine(to: point(18.8, 18.8, origin: origin, unit: unit))
            triangle.addLine(to: point(7.2, 12, origin: origin, unit: unit))
        } else {
            triangle.move(to: point(5.2, 5.2, origin: origin, unit: unit))
            triangle.addLine(to: point(5.2, 18.8, origin: origin, unit: unit))
            triangle.addLine(to: point(16.8, 12, origin: origin, unit: unit))
        }
        triangle.closeSubpath()
        return [bar, triangle]
    }

    private func playPath(origin: CGPoint, unit: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(8.2, 5.1, origin: origin, unit: unit))
        path.addLine(to: point(18.8, 12, origin: origin, unit: unit))
        path.addLine(to: point(8.2, 18.9, origin: origin, unit: unit))
        path.closeSubpath()
        return path
    }

    private func pausePaths(origin: CGPoint, unit: CGFloat) -> [Path] {
        [
            Path(
                roundedRect: rect(6.7, 5.2, 4.2, 13.6, origin: origin, unit: unit),
                cornerRadius: 2.1 * unit
            ),
            Path(
                roundedRect: rect(13.1, 5.2, 4.2, 13.6, origin: origin, unit: unit),
                cornerRadius: 2.1 * unit
            ),
        ]
    }

    private func point(
        _ x: CGFloat,
        _ y: CGFloat,
        origin: CGPoint,
        unit: CGFloat
    ) -> CGPoint {
        CGPoint(x: origin.x + (x * unit), y: origin.y + (y * unit))
    }

    private func rect(
        _ x: CGFloat,
        _ y: CGFloat,
        _ width: CGFloat,
        _ height: CGFloat,
        origin: CGPoint,
        unit: CGFloat
    ) -> CGRect {
        CGRect(
            x: origin.x + (x * unit),
            y: origin.y + (y * unit),
            width: width * unit,
            height: height * unit
        )
    }
}

#Preview("Pulse Line") {
    HStack(spacing: Theme.Spacing.xl) {
        PulseIcon(.home, usesBrandGradient: true)
        PulseIcon(.search)
        PulseIcon(.library)
        PulseIcon(.previous, color: Theme.Colors.textPrimary)
        PulseIcon(.play, color: Theme.Colors.textPrimary)
        PulseIcon(.pause, color: Theme.Colors.textPrimary)
        PulseIcon(.next, color: Theme.Colors.textPrimary)
    }
    .padding()
    .background(Theme.Colors.backgroundPrimary)
}
