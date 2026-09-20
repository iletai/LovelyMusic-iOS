import SwiftUI

struct CustomSegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    let icon: ((T) -> String)?

    @Namespace private var namespace

    init(
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String,
        icon: ((T) -> String)? = nil
    ) {
        _selection = selection
        self.options = options
        self.label = label
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option

                Button {
                    withAnimation(Theme.AnimationPresets.bouncy) {
                        selection = option
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        if let icon, !icon(option).isEmpty {
                            Image(systemName: icon(option))
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(label(option))
                            .font(
                                icon != nil
                                    ? .system(size: 10, weight: .medium) : Theme.Typography.caption
                            )
                            .fontWeight(.medium)
                    }
                    // Round 2: selected uses `onBrand` (white) on solid brand fill.
                    .foregroundStyle(isSelected ? Theme.Colors.onBrand : Theme.Colors.textSecondary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.Colors.brandGradientStart)
                                .shadow(
                                    color: Theme.Shadows.small.color,
                                    radius: Theme.Shadows.small.radius,
                                    x: Theme.Shadows.small.x,
                                    y: Theme.Shadows.small.y
                                )
                                .matchedGeometryEffect(id: "selector", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(Theme.Spacing.xxxs)
        .fixedSize()
        // Round 2: track is solid `surfaceCard` (white in light) with 1px hairline.
        .background(Theme.Colors.surfaceCard, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
    }
}
