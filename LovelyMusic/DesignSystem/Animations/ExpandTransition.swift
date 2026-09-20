import SwiftUI

struct ExpandTransition: ViewModifier {
    let isExpanded: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isExpanded ? 1 : 0.9)
            .opacity(isExpanded ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
    }
}

extension View {
    func expandTransition(isExpanded: Bool) -> some View {
        modifier(ExpandTransition(isExpanded: isExpanded))
    }
}
