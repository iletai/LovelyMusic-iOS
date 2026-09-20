import SwiftUI

struct ParallaxEffect: ViewModifier {
    let offset: CGFloat
    let multiplier: CGFloat

    init(offset: CGFloat, multiplier: CGFloat = 0.5) {
        self.offset = offset
        self.multiplier = multiplier
    }

    func body(content: Content) -> some View {
        content
            .offset(y: offset * multiplier)
    }
}

extension View {
    func parallax(offset: CGFloat, multiplier: CGFloat = 0.5) -> some View {
        modifier(ParallaxEffect(offset: offset, multiplier: multiplier))
    }

    func stickyHeaderParallax(offset: CGFloat) -> some View {
        modifier(ParallaxEffect(offset: offset > 0 ? -offset : 0, multiplier: 1.0))
    }
}
