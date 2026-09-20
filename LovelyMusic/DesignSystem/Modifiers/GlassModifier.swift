import SwiftUI

struct GlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background(Theme.Colors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        Color(light: Color(hex: "#8B5CF6").opacity(0.20), dark: Color.white.opacity(0.06)),
                        lineWidth: 0.5
                    )
            )
    }
}

extension View {
    func glass(cornerRadius: CGFloat = Theme.CornerRadius.medium) -> some View {
        modifier(GlassModifier(cornerRadius: cornerRadius))
    }
}
