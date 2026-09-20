import SwiftUI

struct CustomToggle: View {
    @Binding var isOn: Bool
    var label: LocalizedStringKey?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let label {
                Text(label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            toggleControl
        }
    }

    private var toggleControl: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(
                    isOn
                        ? AnyShapeStyle(Theme.Colors.brandGradient)
                        : AnyShapeStyle(Theme.Colors.backgroundTertiary)
                )
                .frame(width: 44, height: 26)

            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                .padding(.horizontal, 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isOn)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isOn.toggle()
        }
    }
}
