import SwiftUI

/// Custom branded back button component matching LovelyMusic glassmorphic theme.
struct CustomBackButton: View {
    enum Style {
        /// 36x36pt circular glass orb with hairline border. Perfect for Parallax/Artwork headers.
        case glassOrb
        /// Clean circular button with subtle surface hover. Ideal for Settings & Sub-pages.
        case plain
    }

    var style: Style = .glassOrb
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
                switch style {
                case .glassOrb:
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Theme.Colors.surfaceCard.opacity(0.4)))
                        .overlay(Circle().stroke(Theme.Colors.divider, lineWidth: 0.5))
                case .plain:
                    Circle()
                        .fill(Theme.Colors.surfaceCard)
                        .overlay(Circle().stroke(Theme.Colors.divider, lineWidth: 0.5))
                }

                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .offset(x: -0.5)
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .frame(minWidth: Theme.SizeTokens.touchTarget, minHeight: Theme.SizeTokens.touchTarget)
        }
        .buttonStyle(.bouncy)
        .accessibilityLabel(String(localized: "Back"))
    }
}

#Preview {
    ZStack {
        Theme.Colors.backgroundPrimary.ignoresSafeArea()
        HStack(spacing: 24) {
            CustomBackButton(style: .glassOrb)
            CustomBackButton(style: .plain)
        }
    }
}
