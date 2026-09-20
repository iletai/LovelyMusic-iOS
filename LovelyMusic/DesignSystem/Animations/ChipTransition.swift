import SwiftUI

/// Staggered horizontal slide-in animation tailored for chip elements.
/// Each chip slides from the leading edge with a cascading delay.
struct ChipAppearModifier: ViewModifier {
    let index: Int

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(x: isVisible ? 0 : -16)
            .scaleEffect(isVisible ? 1 : 0.92, anchor: .leading)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.82)
                    .delay(Double(index) * 0.04),
                value: isVisible
            )
            .onAppear {
                guard !isVisible else { return }
                isVisible = true
            }
    }
}

extension View {
    func chipAppear(index: Int) -> some View {
        modifier(ChipAppearModifier(index: index))
    }
}
