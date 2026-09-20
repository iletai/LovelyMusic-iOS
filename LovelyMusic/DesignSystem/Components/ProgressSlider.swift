import SwiftUI

struct ProgressSlider: View {
    @Binding var value: Double
    var accentColor: Color?
    var onEditingChanged: (Bool) -> Void = { _ in }
    // Accessibility: time labels and duration for VoiceOver announcements
    var currentTimeLabel: String = ""
    var totalTimeLabel: String = ""
    var duration: TimeInterval = 0
    /// Whether to show a floating time tooltip above the thumb while dragging
    var showsSeekTooltip: Bool = true

    @State private var isDragging = false
    /// Local override during scrub. While non-nil, takes precedence over `value`
    /// for display so the thumb doesn't snap to stale `playbackProgress.progress`
    /// in the brief window between releasing the gesture and the seek landing.
    @State private var dragValue: Double?

    /// Fraction of the slider to move per VoiceOver increment (10 seconds or 5%)
    private var seekStepFraction: Double {
        guard duration > 0 else { return 0.05 }
        return min(10.0 / duration, 0.25)
    }

    /// VoiceOver value description (e.g., "1:23 of 3:45")
    private var accessibilityValueText: String {
        if !currentTimeLabel.isEmpty, !totalTimeLabel.isEmpty {
            return "\(currentTimeLabel) of \(totalTimeLabel)"
        }
        return "\(Int(value * 100)) percent"
    }

    private var effectiveAccent: Color {
        accentColor ?? Theme.Colors.brandGradientStart
    }

    private var fillGradient: LinearGradient {
        if let accent = accentColor {
            return LinearGradient(
                colors: [accent, accent.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
        }
        return Theme.Colors.brandGradient
    }

    var body: some View {
        let displayValue = dragValue ?? value
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Colors.surfaceCard)
                    .frame(height: 4)

                Capsule()
                    .fill(fillGradient)
                    .frame(width: max(0, geo.size.width * CGFloat(displayValue)), height: 4)
                    .animation(nil, value: displayValue)

                Circle()
                    .fill(Theme.Colors.textPrimary)
                    .frame(width: 14, height: 14)
                    .scaleEffect(isDragging ? 18.0 / 14.0 : 1.0)
                    .shadow(color: effectiveAccent.opacity(0.5), radius: 8)
                    .offset(x: max(0, geo.size.width * CGFloat(displayValue) - 7))
                    .animation(nil, value: displayValue)
                    .animation(.spring(response: 0.2), value: isDragging)

                // Seek tooltip shown above thumb during drag
                if isDragging, showsSeekTooltip, duration > 0, let dv = dragValue {
                    seekTooltip(for: dv, in: geo.size.width)
                }
            }
            .frame(height: 44, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let newValue = max(0, min(1, Double(gesture.location.x / geo.size.width)))
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        dragValue = newValue
                    }
                    .onEnded { _ in
                        let finalValue = dragValue ?? value
                        // Order matters:
                        // 1. value = finalValue   → parent's binding.set runs:
                        //    sliderValue = finalValue, isSeeking = true.
                        // 2. onEditingChanged(false) → parent triggers the seek
                        //    but keeps isSeeking = true until progress catches up.
                        // 3. dragValue = nil      → displayValue now resolves to
                        //    binding.get → sliderValue (isSeeking still true) =
                        //    finalValue. No snap to stale playbackProgress.progress.
                        value = finalValue
                        isDragging = false
                        onEditingChanged(false)
                        dragValue = nil
                    }
            )
        }
        .frame(height: 44)
        .sensoryFeedback(.selection, trigger: isDragging)
        .onDisappear {
            dragValue = nil
            isDragging = false
        }
        // VoiceOver: announce progress and allow seek via swipe up/down
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(1.0, value + seekStepFraction)
                onEditingChanged(true)
                onEditingChanged(false)
            case .decrement:
                value = max(0.0, value - seekStepFraction)
                onEditingChanged(true)
                onEditingChanged(false)
            @unknown default: break
            }
        }
    }

    // MARK: - Seek Tooltip

    @ViewBuilder
    private func seekTooltip(for fraction: Double, in width: CGFloat) -> some View {
        let targetTime = duration * fraction
        let minutes = Int(targetTime) / 60
        let seconds = Int(targetTime) % 60
        let label = String(format: "%d:%02d", minutes, seconds)
        let thumbX = max(0, width * CGFloat(fraction) - 7)

        Text(label)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.75), in: Capsule())
            .offset(x: thumbX - 14, y: -28)
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: fraction)
    }
}
