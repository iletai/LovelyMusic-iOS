import SwiftUI

/// Wraps Home shelf carousel items in a `surfaceCard` plane with `Shadows.small`
/// and `CornerRadius.medium` per Round 2 DESIGN row 8 (§6.3 light treatment).
///
/// Why a modifier: the home shelf currently renders 4 item kinds (song / album /
/// artist / playlist) inline in `HomeView.musicSectionItemView`. Each one has
/// the same outer chrome — extract the chrome only, leave data flow alone.
struct HomeShelfCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.md)  // 12pt internal padding (§8 row 8)
            .background(
                Theme.Colors.surfaceCard,
                in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
            )
            .shadow(
                color: Theme.Shadows.small.color,
                radius: Theme.Shadows.small.radius,
                x: Theme.Shadows.small.x,
                y: Theme.Shadows.small.y
            )
    }
}

extension View {
    /// Apply the Round 2 home-shelf card surface (solid white + soft shadow + medium corner).
    func homeShelfCard() -> some View {
        modifier(HomeShelfCardModifier())
    }
}
