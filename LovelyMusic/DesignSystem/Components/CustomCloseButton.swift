import SwiftUI

/// Custom branded close/dismiss button component for sheets and modals.
struct CustomCloseButton: View {
    var action: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            if let customAction = action {
                customAction()
            } else {
                dismiss()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.Colors.surfaceCard)
                    .overlay(Circle().stroke(Theme.Colors.divider, lineWidth: 0.5))

                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .frame(minWidth: Theme.SizeTokens.touchTarget, minHeight: Theme.SizeTokens.touchTarget)
        }
        .buttonStyle(.bouncy)
        .accessibilityLabel(String(localized: "Close"))
    }
}

#Preview {
    ZStack {
        Theme.Colors.backgroundPrimary.ignoresSafeArea()
        CustomCloseButton()
    }
}
