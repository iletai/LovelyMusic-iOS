import SwiftUI

/// Environment key exposing the current `ScrollPhase` of the nearest
/// enclosing `ScrollView` that has `trackScrollPhase()` applied.
///
/// Consumers (`AsyncThumbnail`, pagination guards, image prefetcher)
/// read this to gate work on scroll state without each needing to register
/// its own `.onScrollPhaseChange` handler.
///
/// Defaults to `.idle` when no tracker is installed — consumers can treat
/// the absence of a tracker as "safe to work" rather than blocking.
private struct ScrollPhaseKey: EnvironmentKey {
    static let defaultValue: ScrollPhase = .idle
}

extension EnvironmentValues {
    var scrollPhase: ScrollPhase {
        get { self[ScrollPhaseKey.self] }
        set { self[ScrollPhaseKey.self] = newValue }
    }
}

/// Observes `.onScrollPhaseChange` on an enclosing `ScrollView` and
/// publishes the current phase down the view tree via
/// `EnvironmentValues.scrollPhase`.
struct ScrollPhaseTrackingModifier: ViewModifier {
    @State private var phase: ScrollPhase = .idle

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in
                if newPhase != phase { phase = newPhase }
            }
            .environment(\.scrollPhase, phase)
    }
}

extension View {
    /// Install a scroll-phase tracker on a `ScrollView` subtree. Descendants
    /// can then read `@Environment(\.scrollPhase)` to react to fling /
    /// deceleration / idle state without each owning its own observer.
    ///
    /// Apply this on the outer container of a `ScrollView`. It is a no-op
    /// on non-scrollable views.
    func trackScrollPhase() -> some View {
        modifier(ScrollPhaseTrackingModifier())
    }
}

/// Convenience helpers for mapping `ScrollPhase` to semantic booleans used
/// throughout the scroll stack. Keep these here so each consumer doesn't
/// re-derive the same switch.
extension ScrollPhase {
    /// `true` while the user's finger is actively dragging, the scroll is
    /// decelerating after a fling, or a programmatic animation is in flight.
    /// Equivalent to "not idle". Used to fast-fade thumbnails and defer
    /// pagination trigger.
    var isActive: Bool {
        self != .idle
    }

    /// `true` specifically during finger-off deceleration (the "fling"
    /// phase). This is when image decode can visibly drop frames, so
    /// consumers should pick the cheapest rendering path.
    var isFlinging: Bool {
        self == .decelerating
    }
}
