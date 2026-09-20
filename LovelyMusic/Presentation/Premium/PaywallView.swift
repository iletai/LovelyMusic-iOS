import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(PremiumManager.self) private var premiumManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var selectedDemoProduct: DemoProduct? = .lifetime
    @State private var isPurchasing = false
    @State private var showOfferCodeRedemption = false
    @State private var showPurchaseAlert = false
    @State private var purchaseAlertMessage = ""

    private enum DemoProduct { case monthly, yearly, lifetime }

    var body: some View {
        // MARK: SafeArea — presented as fullScreenCover; dock not visible. Footer links rely on system home-indicator inset.
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 0) {
                    heroHeader
                    featuresSection
                    productsSection
                    purchaseButton
                    footerLinks
                }
            }
            .scrollIndicators(.hidden)

            CustomCloseButton()
                .padding(.top, Theme.Spacing.lg)
                .padding(.trailing, Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .environment(\.colorScheme, .dark)
        .task {
            await premiumManager.loadProducts()
            if selectedProduct == nil {
                selectedProduct = premiumManager.lifetimeProduct ?? premiumManager.yearlyProduct ?? premiumManager.monthlyProduct
            }
        }
        .onChange(of: premiumManager.isPremium) { _, newValue in
            if newValue { dismiss() }
        }
        .offerCodeRedemption(isPresented: $showOfferCodeRedemption) { result in
            switch result {
            case .success:
                Task { await premiumManager.checkSubscriptionStatus() }
            case .failure(let error):
                premiumManager.setRedemptionError(
                    String(localized: "Code redemption failed: \(error.localizedDescription)")
                )
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.Colors.brandGradientStart.opacity(0.3),
                    Theme.Colors.brandGradientEnd.opacity(0.2),
                    Theme.Colors.backgroundPrimary,
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: Theme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Theme.Colors.brandGradientStart,
                                    Theme.Colors.brandGradientEnd,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(
                            color: Theme.Colors.brandGradientStart.opacity(0.4),
                            radius: 20,
                            x: 0,
                            y: 8
                        )

                    Image(systemName: "crown.fill")
                        .font(Theme.Typography.largeTitle)
                        .foregroundStyle(.white)
                }

                VStack(spacing: Theme.Spacing.sm) {
                    if featureFlags.paywallPromo.isEnabled && !featureFlags.paywallPromo.badgeText.isEmpty {
                        Text(featureFlags.paywallPromo.badgeText)
                            .font(Theme.Typography.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(Theme.Colors.warning)
                            .clipShape(Capsule())
                    }

                    Text(featureFlags.paywallPromo.isEnabled && !featureFlags.paywallPromo.headline.isEmpty
                         ? LocalizedStringKey(featureFlags.paywallPromo.headline)
                         : "LovelyMusic Premium")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Text(featureFlags.paywallPromo.isEnabled && !featureFlags.paywallPromo.subheadline.isEmpty
                         ? LocalizedStringKey(featureFlags.paywallPromo.subheadline)
                         : "Unlock the full music experience")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .padding(.top, Theme.Spacing.xxxl)
            .padding(.bottom, Theme.Spacing.lg)
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(spacing: Theme.Spacing.md) {
            ForEach(PremiumFeature.allCases.filter { feature in
                feature != .offlinePlayback || featureFlags.isDownloadEnabled
            }, id: \.rawValue) { feature in
                featureRow(feature: feature)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.xl)
    }

    private func featureRow(feature: PremiumFeature) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.Colors.brandGradientStart.opacity(0.15),
                                Theme.Colors.brandGradientEnd.opacity(0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: feature.iconName)
                    .font(Theme.Typography.title3)
                    .foregroundStyle(Theme.Colors.brandGradientStart)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                Text(feature.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text(feature.description)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Colors.success)
                .font(.body)
        }
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(spacing: Theme.Spacing.md) {
            if premiumManager.isLoading && premiumManager.products.isEmpty {
                ProgressView()
                    .tint(Theme.Colors.brandGradientStart)
                    .padding(Theme.Spacing.xxl)
            } else if premiumManager.products.isEmpty {
                demoProductCard(
                    name: "Monthly",
                    price: "$4.99",
                    period: "/month",
                    description: "Billed monthly, cancel anytime",
                    isYearly: false,
                    isSelected: selectedDemoProduct == .monthly
                )
                demoProductCard(
                    name: "Yearly",
                    price: "$29.99",
                    period: "/year",
                    description: "Save 50% compared to monthly",
                    isYearly: true,
                    isSelected: selectedDemoProduct == .yearly
                )
                if featureFlags.isLifetimeEnabled {
                    demoProductCard(
                        name: "Lifetime",
                        price: "$79.99",
                        period: "one-time",
                        description: "Pay once, enjoy forever",
                        isYearly: false,
                        isSelected: selectedDemoProduct == .lifetime
                    )
                }
            } else {
                ForEach(premiumManager.products.filter { product in
                    if product.id == PremiumManager.lifetimeProductID {
                        return featureFlags.isLifetimeEnabled
                    }
                    return true
                }) { product in
                    productCard(product: product)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
    }

    private func productCard(product: Product) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let isYearly = product.id == PremiumManager.yearlyProductID
        let isLifetime = product.id == PremiumManager.lifetimeProductID

        return Button {
            withAnimation(Theme.AnimationPresets.smooth) {
                selectedProduct = product
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                RadioDot(isSelected: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(product.displayName)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(isSelected ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)

                        if isLifetime {
                            Text("BEST VALUE")
                                .font(Theme.Typography.badge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.Colors.premiumGradient)
                                .clipShape(Capsule())
                        } else if isYearly {
                            Text("SAVE 50%")
                                .font(Theme.Typography.badge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.Colors.brandGradient)
                                .clipShape(Capsule())
                        }
                    }

                    Text(product.description)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(Theme.Typography.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(isSelected ? Theme.Colors.brandGradientStart : Theme.Colors.textPrimary)

                    if isLifetime {
                        Text(String(localized: "one-time"))
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(Theme.Colors.premiumGold)
                    } else {
                        Text(isYearly ? String(localized: "/year") : String(localized: "/month"))
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .background(
                isSelected
                    ? Theme.Colors.brandGradientStart.opacity(0.08)
                    : Theme.Colors.backgroundTertiary
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .stroke(
                        isSelected
                            ? AnyShapeStyle(isLifetime ? Theme.Colors.premiumGradient : Theme.Colors.brandGradient)
                            : AnyShapeStyle(Theme.Colors.textTertiary.opacity(0.15)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func demoProductCard(
        name: LocalizedStringKey,
        price: String,
        period: LocalizedStringKey,
        description: LocalizedStringKey,
        isYearly: Bool,
        isSelected: Bool
    ) -> some View {
        Button {
            withAnimation(Theme.AnimationPresets.smooth) {
                selectedDemoProduct = isYearly ? .yearly : .monthly
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                RadioDot(isSelected: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(name)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(isSelected ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)

                        if isYearly {
                            Text("SAVE 50%")
                                .font(Theme.Typography.badge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.Colors.brandGradient)
                                .clipShape(Capsule())
                        }
                    }

                    Text(description)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(price)
                        .font(Theme.Typography.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(isSelected ? Theme.Colors.brandGradientStart : Theme.Colors.textPrimary)

                    Text(period)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .padding(Theme.Spacing.lg)
            .background(
                isSelected
                    ? Theme.Colors.brandGradientStart.opacity(0.08)
                    : Theme.Colors.backgroundTertiary
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .stroke(
                        isSelected
                            ? AnyShapeStyle(Theme.Colors.brandGradient)
                            : AnyShapeStyle(Theme.Colors.textTertiary.opacity(0.15)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isYearly ? "Yearly" : "Monthly") plan, \(price)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var hasPurchasableSelection: Bool {
        selectedProduct != nil || (premiumManager.products.isEmpty && selectedDemoProduct != nil)
    }

    private var purchaseButton: some View {
        VStack(spacing: Theme.Spacing.md) {
            Button {
                if let product = selectedProduct {
                    isPurchasing = true
                    Task {
                        do {
                            try await premiumManager.purchase(product)
                        } catch {
                            // Error is handled by premiumManager.purchaseError
                        }
                        isPurchasing = false
                    }
                } else if selectedDemoProduct != nil {
                    purchaseAlertMessage = "Demo mode — purchases are disabled in preview"
                    showPurchaseAlert = true
                } else {
                    return
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .fill(Theme.Colors.brandGradient)
                        .frame(height: 56)
                        .shadow(
                            color: Theme.Colors.brandGradientStart.opacity(0.3),
                            radius: 12,
                            x: 0,
                            y: 6
                        )

                    if isPurchasing || premiumManager.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Group {
                            if selectedProduct?.id == PremiumManager.lifetimeProductID {
                                Text("Buy Lifetime")
                            } else {
                                Text("Subscribe Now")
                            }
                        }
                        .font(Theme.Typography.title3)
                        .bold()
                        .foregroundStyle(.white)
                    }
                }
            }
            .disabled(!hasPurchasableSelection || isPurchasing || premiumManager.isLoading)
            .opacity(!hasPurchasableSelection || isPurchasing || premiumManager.isLoading ? 0.5 : 1.0)
            .animation(Theme.AnimationPresets.gentle, value: hasPurchasableSelection)
            .animation(Theme.AnimationPresets.gentle, value: isPurchasing)
            .padding(.horizontal, Theme.Spacing.lg)
            .accessibilityLabel("Subscribe Now")
            .accessibilityHint("Double tap to start subscription")

            Button {
                Task {
                    do {
                        try await premiumManager.restorePurchases()
                    } catch {
                        Log.app.error("Failed to restore purchases: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } label: {
                Text("Restore Purchases")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.brandGradientStart)
            }
            .accessibilityLabel("Restore Purchases")

            Button {
                showOfferCodeRedemption = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "giftcard")
                    Text("Redeem Code")
                }
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.brandGradientStart)
            }
            .accessibilityLabel("Redeem Code")

            if let error = premiumManager.purchaseError {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, Theme.Spacing.xl)
        .animation(Theme.AnimationPresets.gentle, value: premiumManager.purchaseError)
        .alert("Notice", isPresented: $showPurchaseAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchaseAlertMessage)
        }
    }

    // MARK: - Footer

    private var footerLinks: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(
                "Subscriptions automatically renew unless cancelled at least 24 hours before the end of the current period. Your account will be charged for renewal within 24 hours prior to the end of the current period."
            )
            .font(Theme.Typography.captionSecondary)
            .foregroundStyle(Theme.Colors.textTertiary)
            .multilineTextAlignment(.center)

            HStack(spacing: Theme.Spacing.lg) {
                Link(
                    "Terms of Service",
                    destination: URL(
                        string: featureFlags.termsOfServiceURL.isEmpty
                            ? "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
                            : featureFlags.termsOfServiceURL
                    ) ?? URL(string: "https://www.apple.com")!
                )
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(Theme.Colors.textTertiary)

                Text("•")
                    .foregroundStyle(Theme.Colors.textTertiary)

                Link(
                    "Privacy Policy",
                    destination: URL(
                        string: featureFlags.privacyPolicyURL.isEmpty
                            ? "https://www.apple.com/legal/privacy/"
                            : featureFlags.privacyPolicyURL
                    ) ?? URL(string: "https://www.apple.com")!
                )
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(Theme.Colors.textTertiary)
            }

            Link(
                "Manage Subscriptions",
                destination: URL(string: "https://apps.apple.com/account/subscriptions")!
            )
            .font(Theme.Typography.captionSecondary)
            .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.xl)
    }
}

// MARK: - RadioDot (Round 2 §6.8)

/// Compact selection indicator for the paywall plan picker.
/// Replaces the legacy "Selected" pill / inline ring-and-fill ZStack.
///
/// - Selected: 28pt brand-purple solid disc with a 12pt white inner dot.
/// - Unselected: 28pt circle with a 1.5pt brand outline and transparent fill.
///
/// Decorative-only — the parent button supplies `.accessibilityAddTraits(.isSelected)`.
private struct RadioDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(Theme.Colors.brandGradientStart)
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .strokeBorder(Theme.Colors.brandGradientStart, lineWidth: 1.5)
                    .frame(width: 28, height: 28)
            }
        }
        .frame(width: 28, height: 28)
        .animation(Theme.AnimationPresets.smooth, value: isSelected)
        .accessibilityHidden(true)
    }
}
