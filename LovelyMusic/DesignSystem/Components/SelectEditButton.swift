import SwiftUI

struct SelectEditButton: View {
    let isEditing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: isEditing ? "checkmark" : "checkmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text(isEditing ? String(localized: "Done") : String(localized: "Select"))
                    .font(Theme.Typography.subheadline.weight(.semibold))
            }
            .foregroundStyle(isEditing ? .white : Theme.Colors.textPrimary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .background {
                if isEditing {
                    Capsule().fill(Theme.Colors.brandGradient)
                } else {
                    Capsule()
                        .fill(Theme.Colors.surfaceCard)
                        .overlay(Capsule().stroke(Theme.Colors.divider, lineWidth: 1))
                }
            }
        }
        .buttonStyle(.bouncy)
    }
}
