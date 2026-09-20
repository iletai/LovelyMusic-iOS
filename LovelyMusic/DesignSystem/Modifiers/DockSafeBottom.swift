import SwiftUI

// MARK: - DockSafeBottom

/// Adds a baseline bottom margin to a `ScrollView`'s content so the last row
/// is not flush against the floating dock / mini-player / banner ad inset
/// supplied by `ContentView`.
///
/// `ContentView` already publishes a global `safeAreaInset(edge: .bottom)` for
/// the dock and ad banner. This modifier adds a small additional margin
/// (`Theme.Spacing.lg` = 16pt) inside the scroll content so the visually last
/// item has breathing room above that inset, especially during dock-inset
/// transitions (animated reveal/hide, ad-banner load).
///
/// Implementation notes:
/// - iOS 17+ exposes `.contentMargins(_:_:for:)`, which we use against
///   `.scrollContent` so the margin only affects content (not the scroll
///   indicators or the safe-area inset itself).
/// - The deployment target for this project is iOS 18, so the API is always
///   available. We still gate with `if #available` defensively to keep the
///   modifier robust against future deployment-target changes.
struct DockSafeBottomModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentMargins(.bottom, Theme.Spacing.lg, for: .scrollContent)
        } else {
            content
        }
    }
}

extension View {
    /// Adds a 16pt bottom content margin to a `ScrollView` so the last row
    /// clears the global dock/mini-player/ad-banner inset comfortably.
    ///
    /// Apply to top-level `ScrollView`s in routed sub-pages (e.g. settings
    /// detail screens) where rows would otherwise sit visually flush against
    /// the dock during inset transitions.
    func dockSafeBottom() -> some View {
        modifier(DockSafeBottomModifier())
    }
}
