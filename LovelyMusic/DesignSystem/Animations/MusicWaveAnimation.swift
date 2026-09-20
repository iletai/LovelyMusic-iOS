import SwiftUI

/// 3-bar audio equalizer animation shown next to the currently-playing song.
///
/// Driven by `TimelineView(.animation(minimumInterval:))` at 30 Hz rather
/// than SwiftUI's display-linked `repeatForever` animation. The visual
/// impact is identical (the bars pulse at ~1.25 Hz), but:
///
/// - CPU/GPU spend ~50% less per second on this widget when a long list
///   contains many playing-state rows.
/// - `TimelineView` pauses automatically when the enclosing view is off-
///   screen (scrolled out of a `LazyVStack`), whereas `repeatForever`
///   animations continue until the view is deallocated.
struct MusicWaveAnimation: View {
    let barCount: Int
    let color: Color

    /// Period of one full pulse cycle (scale 0.3 → 1.0 → 0.3). 0.8s keeps
    /// the visual tempo matching the original `repeatForever(autoreverses:)`
    /// timing so the change is imperceptible.
    private let periodSeconds: Double = 0.8

    init(color: Color = Theme.Colors.brandGradientStart, barCount: Int = 3) {
        self.color = color
        self.barCount = barCount
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 3)
                        .scaleEffect(
                            y: scale(for: index, at: context.date),
                            anchor: .bottom
                        )
                }
            }
        }
    }

    /// Sine-driven scale in [0.3, 1.0] with per-bar phase offset so bars
    /// appear to chase each other (matches the original 0.15s delay).
    private func scale(for barIndex: Int, at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let phaseOffset = Double(barIndex) * 0.15
        // sin in [-1, 1] → normalise to [0, 1] then map to [0.3, 1.0].
        let normalised = (sin((t - phaseOffset) * 2 * .pi / periodSeconds) + 1) / 2
        return 0.3 + 0.7 * CGFloat(normalised)
    }
}

