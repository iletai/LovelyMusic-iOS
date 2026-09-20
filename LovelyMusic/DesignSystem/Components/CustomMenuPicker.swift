import SwiftUI

struct CustomMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    let icon: ((T) -> String)?

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
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(Theme.AnimationPresets.gentle) {
                        selection = option
                    }
                } label: {
                    if selection == option {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(label(selection))
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .contentTransition(.numericText())

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Colors.surfaceCard, in: Capsule())
        }
    }
}
