import SwiftUI

struct SelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    isSelected ? Theme.Colors.brandGradientStart : Theme.Colors.textTertiary.opacity(0.4),
                    lineWidth: 2
                )
                .frame(width: 22, height: 22)

            if isSelected {
                Circle()
                    .fill(Theme.Colors.brandGradient)
                    .frame(width: 14, height: 14)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.AnimationPresets.smooth, value: isSelected)
    }
}
