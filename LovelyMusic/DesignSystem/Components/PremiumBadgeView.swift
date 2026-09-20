import SwiftUI

struct PremiumBadgeView: View {
    enum Size {
        case compact
        case standard
    }

    /// Color treatment.
    /// - `.brand`: brand-purple gradient (default). Used for in-app premium hints
    ///   on non-paywall surfaces (settings, feature gates).
    /// - `.paywall`: gold `premiumGradient`. Reserved for the Paywall hero/CTA;
    ///   per Round 2 Q2, gold MUST NOT leak into other surfaces.
    enum Style {
        case brand
        case paywall
    }

    var size: Size = .compact
    var style: Style = .brand

    private var fill: AnyShapeStyle {
        switch style {
        case .brand:   return AnyShapeStyle(Theme.Colors.brandGradient)
        case .paywall: return AnyShapeStyle(Theme.Colors.premiumGradient)
        }
    }

    var body: some View {
        switch size {
        case .compact:
            Text("PRO")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 4))

        case .standard:
            HStack(spacing: 3) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Premium")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(fill)
            .clipShape(Capsule())
        }
    }
}
