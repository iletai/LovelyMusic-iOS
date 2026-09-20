import SwiftUI

/// Round 2 light-mode redesign:
/// - **Light mode**: solid `surfaceCard` (pure white) + 1px hairline `divider` (neutral 8% black)
///   + `Shadows.small` for soft elevation. No `.ultraThinMaterial` — depth comes from luminance.
/// - **Dark mode**: unchanged — translucent material over `surfaceCard` tint.
struct GlassmorphicCard<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if colorScheme == .light {
            content
                .background(Theme.Colors.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
                )
                .shadow(
                    color: Theme.Shadows.small.color,
                    radius: Theme.Shadows.small.radius,
                    x: Theme.Shadows.small.x,
                    y: Theme.Shadows.small.y
                )
        } else {
            content
                .background(.ultraThinMaterial)
                .background(Theme.Colors.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .drawingGroup()
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
    }
}
