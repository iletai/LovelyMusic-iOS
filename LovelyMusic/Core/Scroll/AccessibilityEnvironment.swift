import SwiftUI
import UIKit

/// Central readers for accessibility signals that scroll components need
/// beyond what SwiftUI exposes natively.
///
/// SwiftUI already exposes `\.accessibilityReduceMotion`,
/// `\.accessibilityReduceTransparency`, `\.accessibilityDifferentiateWithoutColor`,
/// and `\.accessibilityVoiceOverEnabled`. This file adds:
///
/// - `\.accessibilityAssistiveTouchRunning` — not yet in SwiftUI as of iOS 18.
/// - `MotionGate` — aggregated "should motion run?" decision so each scroll
///   component doesn't re-derive the same OR-chain.

// MARK: - AssistiveTouch environment key

private struct AssistiveTouchKey: EnvironmentKey {
    @MainActor
    static var defaultValue: Bool { UIAccessibility.isAssistiveTouchRunning }
}

extension EnvironmentValues {
    /// `true` when AssistiveTouch is currently active. Kept as a separate
    /// key so Views can choose to disable custom scroll physics that might
    /// trap users who rely on AssistiveTouch auto-tap sequences.
    var accessibilityAssistiveTouchRunning: Bool {
        get { self[AssistiveTouchKey.self] }
        set { self[AssistiveTouchKey.self] = newValue }
    }
}

// MARK: - Motion gate

/// Aggregate signal: "is it safe to run non-essential motion?"
///
/// Returns `false` when any of:
/// - Reduce Motion is on
/// - AssistiveTouch is running (custom physics can trap auto-tap sequences)
///
/// Components should fall back to identity transitions / instant positioning
/// when `allowsMotion` is `false`.
struct MotionGate {
    let reduceMotion: Bool
    let assistiveTouchRunning: Bool

    /// `true` when motion effects (parallax, scrollTransition scale/opacity,
    /// lyrics smooth-scroll, custom scroll-target physics) should run.
    var allowsMotion: Bool {
        !reduceMotion && !assistiveTouchRunning
    }

    /// `true` when haptic feedback should fire. Haptics are treated as
    /// motion-adjacent signals and respect Reduce Motion.
    var allowsHaptics: Bool {
        !reduceMotion
    }
}

extension EnvironmentValues {
    /// Convenience aggregator reading Reduce Motion plus AssistiveTouch.
    /// Prefer this in scroll components over re-deriving the OR-chain.
    var motionGate: MotionGate {
        MotionGate(
            reduceMotion: self.accessibilityReduceMotion,
            assistiveTouchRunning: self.accessibilityAssistiveTouchRunning
        )
    }
}
