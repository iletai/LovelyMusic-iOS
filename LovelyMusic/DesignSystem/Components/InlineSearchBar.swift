import SwiftUI

struct InlineSearchBar: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Search"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            PulseIcon(
                .search,
                size: Theme.SizeTokens.iconSmall,
                color: Theme.Colors.textTertiary
            )

            TextField(placeholder, text: $text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                .focused($isFocused)
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    withAnimation(Theme.AnimationPresets.gentle) {
                        text = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm + 2)
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .stroke(isFocused ? Theme.Colors.brandGradientStart.opacity(0.4) : Theme.Colors.divider, lineWidth: 1)
        )
        .animation(Theme.AnimationPresets.gentle, value: isFocused)
        .animation(Theme.AnimationPresets.gentle, value: text.isEmpty)
    }
}
