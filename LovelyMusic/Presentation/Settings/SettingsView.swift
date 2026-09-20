import StoreKit
import SwiftUI

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @Bindable var themeManager: ThemeManager
    @Environment(SleepTimerManager.self) private var sleepTimerManager
    @Environment(PremiumManager.self) private var premiumManager
    @Environment(EqualizerManager.self) private var equalizerManager
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @State private var showPaywall = false
    @State private var showQualityPaywall = false
    @State private var showEqualizerPaywall = false
    @State private var showOfferCodeRedemption = false
    // Haptic feedback triggers (SwiftUI native, replacing UIKit imperative calls)
    @State private var mediumHapticTrigger = false
    @Namespace private var qualityNamespace

    init(
        authManager: YouTubeAuthManager, themeManager: ThemeManager,
        audioCacheManager: AudioCacheManager
    ) {
        let vm = SettingsViewModel(authManager: authManager)
        vm.audioCacheManager = audioCacheManager
        _viewModel = State(initialValue: vm)
        self.themeManager = themeManager
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Base background
            Theme.Colors.backgroundPrimary.ignoresSafeArea()

            // Gradient header bleed — brand gradient that fades into content
            settingsGradientHeader

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.xl) {
                    // MARK: - Account Card (Hero Identity)
                    if featureFlags.isYouTubeAuthEnabled {
                        accountCard
                            .padding(.horizontal, Theme.Spacing.lg)
                            .staggeredAppear(index: 0)
                    }

                    // MARK: - Premium Section
                    if featureFlags.isPremiumEnabled {
                        premiumSection
                            .padding(.horizontal, Theme.Spacing.lg)
                            .staggeredAppear(index: 1)
                    }

                    // MARK: - Developer Toggle
                    if featureFlags.isDevModeEnabled {
                        SettingsGroup(header: "🧪 Developer") {
                            SettingsRow(icon: "hammer.fill", title: "Premium Override") {
                            CustomToggle(
                                isOn: Binding(
                                    get: { premiumManager.devPremiumOverride ?? false },
                                    set: { premiumManager.devPremiumOverride = $0 }
                                ))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                            .stroke(Color.orange, lineWidth: 1)
                            .padding(.horizontal, Theme.Spacing.lg)
                    )
                }

                // MARK: - Appearance (elevated visual showcase)
                if featureFlags.isAppearanceSettingsEnabled {
                    appearanceSection
                        .staggeredAppear(index: 2)
                }

                // MARK: - Navigation Cards (Individual floating cards)
                VStack(spacing: Theme.Spacing.md) {
                    // Playback & Audio
                    NavigationLink {
                        PlaybackAudioSettingsView(
                            viewModel: viewModel,
                            isPremium: premiumManager.isPremium,
                            canAccessEqualizer: premiumManager.canAccess(.equalizer),
                            equalizerPresetName: equalizerManager.selectedPreset.name,
                            sleepTimerIsActive: sleepTimerManager.isActive,
                            sleepTimerFormatted: sleepTimerManager.formattedRemaining,
                            audioQualityPicker: AnyView(audioQualityPicker),
                            canAccessLyrics: premiumManager.canAccess(.syncedLyrics),
                            onCancelSleepTimer: {
                                sleepTimerManager.cancel()
                                viewModel.sleepTimer = .off
                            },
                            onShowEqualizerPaywall: {
                                showEqualizerPaywall = true
                                mediumHapticTrigger.toggle()
                            }
                        )
                    } label: {
                        settingsNavCard(
                            icon: "waveform",
                            accentColor: Theme.Colors.brandGradientStart,
                            title: "Playback & Audio",
                            subtitle: playbackSubtitle,
                            badge: viewModel.audioQuality.displayName
                        )
                    }
                    .buttonStyle(.bouncy)

                    // Language & Region
                    NavigationLink {
                        LanguageRegionSettingsView(viewModel: viewModel)
                    } label: {
                        settingsNavCard(
                            icon: "globe.asia.fill",
                            accentColor: .blue,
                            title: "Language & Region",
                            subtitle: languageSubtitle,
                            badge: viewModel.region
                        )
                    }
                    .buttonStyle(.bouncy)

                    // Privacy & Storage
                    NavigationLink {
                        PrivacyStorageSettingsView(viewModel: viewModel)
                    } label: {
                        settingsNavCard(
                            icon: "lock.shield.fill",
                            accentColor: Theme.Colors.error,
                            title: "Privacy & Storage",
                            subtitle: privacySubtitle,
                            badge: viewModel.cacheSize.isEmpty ? nil : viewModel.cacheSize
                        )
                    }
                    .buttonStyle(.bouncy)

                    // About
                    NavigationLink {
                        AboutView()
                    } label: {
                        settingsNavCard(
                            icon: "music.note.house.fill",
                            accentColor: Theme.Colors.brandGradientEnd,
                            title: "About",
                            subtitle: "Credits, Licenses & Legal",
                            badge: "v\(appVersion)"
                        )
                    }
                    .buttonStyle(.bouncy)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .staggeredAppear(index: 3)

                // MARK: - Reset
                resetAllButton
                    .staggeredAppear(index: 4)

                // MARK: - Branded Footer
                settingsBrandedFooter
                    .staggeredAppear(index: 5)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("Settings")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
        }
        .sheet(isPresented: $viewModel.showingLogin) {
            YouTubeLoginView(authManager: viewModel.authManager) {
                NotificationCenter.default.post(name: .settingsChanged, object: nil)
            }
        }
        .sheet(isPresented: $showQualityPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showEqualizerPaywall) {
            PaywallView()
        }
        .task {
            viewModel.capQualityIfNeeded(isPremium: premiumManager.isPremium)
        }
        .onChange(of: premiumManager.isPremium) { _, isPremium in
            viewModel.capQualityIfNeeded(isPremium: isPremium)
        }
        .onChange(of: viewModel.sleepTimer) { _, newValue in
            sleepTimerManager.start(option: newValue)
        }
        .alert("Sign Out?", isPresented: $viewModel.showSignOutAlert) {
            Button("Sign Out", role: .destructive) {
                withAnimation(Theme.AnimationPresets.smooth) {
                    viewModel.signOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You'll need to sign in again to access your music library, playlists, and personalized recommendations."
            )
        }
        .alert("Reset All Settings?", isPresented: $viewModel.showResetAllAlert) {
            Button("Reset", role: .destructive) {
                viewModel.resetAllSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "All preferences (playback, audio, language, privacy) will return to defaults. Your playlists, history, downloads, and account are not affected."
            )
        }
        .overlay(alignment: .top) {
            resetCompletedToast
        }
        .animation(Theme.AnimationPresets.smooth, value: viewModel.showResetAllCompleted)
        // SwiftUI native haptics (replacing UIKit UIImpactFeedbackGenerator calls)
        .sensoryFeedback(.impact(weight: .medium), trigger: mediumHapticTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.sleepTimer)
    }

    // MARK: - Gradient Header Background

    private var settingsGradientHeader: some View {
        LinearGradient(
            colors: [
                Theme.Colors.brandGradientStart.opacity(0.12),
                Theme.Colors.brandGradientEnd.opacity(0.06),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 220)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Individual Navigation Card

    private func settingsNavCard(
        icon: String,
        accentColor: Color,
        title: String,
        subtitle: String,
        badge: String? = nil
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            // Left accent glowing border indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4, height: 38)
                .shadow(color: accentColor.opacity(0.3), radius: 3, x: 0, y: 0)

            // Icon with rounded squircle and subtle gradient
            ZStack {
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor, accentColor.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: accentColor.opacity(0.35), radius: 6, x: 0, y: 3)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            // Text stack
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if let badge {
                Text(badge)
                    .font(Theme.Typography.captionSecondary)
                    .fontWeight(.semibold)
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, Theme.Spacing.xs + 2)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.12), in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
        .shadow(
            color: Theme.Shadows.small.color,
            radius: Theme.Shadows.small.radius,
            x: Theme.Shadows.small.x,
            y: Theme.Shadows.small.y
        )
    }

    // MARK: - Branded Footer

    private var settingsBrandedFooter: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Gradient app name
            Text("LovelyMusic")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.Colors.brandGradientStart, Theme.Colors.brandGradientEnd],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // Version pill
            Text("v\(appVersion)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    Capsule().fill(Theme.Colors.backgroundTertiary)
                )

            // Horizontal legal links
            HStack(spacing: Theme.Spacing.md) {
                if let url = URL(string: "https://www.iletai.qzz.io/policy#privacy-policy") {
                    Link("Privacy Policy", destination: url)
                }

                Circle()
                    .fill(Theme.Colors.textTertiary)
                    .frame(width: 3, height: 3)

                if let url = URL(string: "https://www.iletai.qzz.io/policy#terms-of-use") {
                    Link("Terms of Use", destination: url)
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textTertiary)

            Text("Made with ♪ in Vietnam")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxxl)
        .padding(.top, Theme.Spacing.xl)
    }

    // MARK: - Subtitles for Navigation Rows

    private var resetAllButton: some View {
        Button(role: .destructive) {
            viewModel.showResetAllAlert = true
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                Text("Reset All Settings")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var resetCompletedToast: some View {
        if viewModel.showResetAllCompleted {
            Text("Settings reset")
                .font(Theme.Typography.body)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(.green.opacity(0.9), in: Capsule())
                .padding(.top, Theme.Spacing.md)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var playbackSubtitle: String {
        let quality = viewModel.audioQuality.displayName
        let eq = equalizerManager.selectedPreset.name
        return "\(quality) quality · \(eq)"
    }

    private var languageSubtitle: String {
        let lang = localizationManager.currentLanguage.displayName
        let region = regionName(viewModel.region)
        return "\(lang) · \(region)"
    }

    private var privacySubtitle: String {
        var parts: [String] = []
        if viewModel.pauseListenHistory || viewModel.pauseSearchHistory {
            parts.append("History paused")
        }
        if !viewModel.cacheSize.isEmpty {
            parts.append("Cache \(viewModel.cacheSize)")
        }
        return parts.isEmpty ? "Manage data & privacy" : parts.joined(separator: " · ")
    }

    private func regionName(_ code: String) -> String {
        switch code {
        case "VN": return "Vietnam"
        case "US": return "United States"
        case "JP": return "Japan"
        case "KR": return "Korea"
        default: return code
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: - Account Card (Hero Identity)

    @State private var avatarRingRotation: Double = 0

    private var accountCard: some View {
        VStack(spacing: 0) {
            if viewModel.isLoggedIn {
                HStack(spacing: Theme.Spacing.lg) {
                    // Avatar with animated gradient ring
                    ZStack {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        Theme.Colors.brandGradientStart,
                                        Theme.Colors.brandGradientEnd,
                                        Theme.Colors.brandGradientStart.opacity(0.6),
                                        Theme.Colors.brandGradientStart
                                    ],
                                    center: .center
                                ),
                                lineWidth: 3
                            )
                            .frame(width: 58, height: 58)
                            .rotationEffect(.degrees(avatarRingRotation))

                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(Theme.Colors.brandGradientStart)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(viewModel.accountName ?? String(localized: "Music Account"))
                            .font(Theme.Typography.title3)
                            .foregroundStyle(Theme.Colors.textPrimary)

                        if premiumManager.isPremium {
                            HStack(spacing: Theme.Spacing.xxs) {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 10))
                                Text("Premium")
                                    .font(Theme.Typography.caption)
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xxxs)
                            .background(Theme.Colors.brandGradient, in: Capsule())
                        } else {
                            Text("Signed in")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
                .transition(.scale.combined(with: .opacity))

                Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                    .padding(.leading, 76)

                Button(role: .destructive) {
                    viewModel.showSignOutAlert = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(Theme.Colors.error)
                        Text("Sign Out")
                            .foregroundStyle(Theme.Colors.error)
                        Spacer()
                    }
                    .font(Theme.Typography.body)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.lg)
                }
            } else {
                Button {
                    viewModel.showingLogin = true
                } label: {
                    HStack(spacing: Theme.Spacing.lg) {
                        // Avatar placeholder with subtle gradient ring
                        ZStack {
                            Circle()
                                .stroke(
                                    Theme.Colors.textTertiary.opacity(0.3),
                                    lineWidth: 2
                                )
                                .frame(width: 58, height: 58)

                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 46))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }

                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Sign in")
                                .font(Theme.Typography.title3)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text("Access playlists & recommendations")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.xl)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.AnimationPresets.smooth, value: viewModel.isLoggedIn)
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
        .shadow(
            color: Theme.Shadows.small.color,
            radius: Theme.Shadows.small.radius,
            x: Theme.Shadows.small.x,
            y: Theme.Shadows.small.y
        )
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                avatarRingRotation = 360
            }
        }
    }

    // MARK: - Premium Section (Compact Redesign)
    //
    // Split into sub-views (`premiumUpgradeCard` / `premiumActiveCard`) to keep
    // each SwiftUI body small enough for the type-checker. A single combined
    // `Group { if-else }` body was hitting the @ViewBuilder inference timeout
    // (cascading into a misleading `TableColumnBuilder` overload note) once
    // the surrounding Theme tokens grew in r2-light-mode work.

    @ViewBuilder
    private var premiumSection: some View {
        if premiumManager.isPremium {
            premiumActiveCard
        } else {
            premiumUpgradeCard
        }
    }

    private var premiumUpgradeCard: some View {
        VStack(spacing: Theme.Spacing.sm) {
            premiumUpgradeCTAButton
            premiumRedeemCodeRow
            premiumRedeemFeedback
        }
        .animation(.easeInOut(duration: 0.25), value: premiumManager.redemptionFeedback)
    }

    private var premiumUpgradeCTAButton: some View {
        Button {
            showPaywall = true
            mediumHapticTrigger.toggle()
        } label: {
            premiumUpgradeCTALabel
        }
        .buttonStyle(.bouncy)
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    private var premiumUpgradeCTALabel: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 44, height: 44)
                Image(systemName: "crown.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .symbolEffect(.breathe, isActive: true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Upgrade to Premium")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(.white)
                    Text("Popular")
                        .font(Theme.Typography.badge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                Text("HQ audio, lyrics, equalizer & more")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(Theme.Spacing.xl)
        .background(
            Theme.Colors.brandGradient
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .shadow(color: Theme.Colors.brandGradientStart.opacity(0.3), radius: 12, y: 6)
    }

    private var premiumRedeemCodeRow: some View {
        Button {
            showOfferCodeRedemption = true
            mediumHapticTrigger.toggle()
        } label: {
            premiumRedeemCodeRowLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text("Redeem code, button, double-tap to enter an Apple promo or gift code")
        )
        .offerCodeRedemption(isPresented: $showOfferCodeRedemption) { result in
            switch result {
            case .success:
                premiumManager.setRedemptionSuccess()
                Task { await premiumManager.checkSubscriptionStatus() }
            case .failure(let error):
                premiumManager.setRedemptionFailure(
                    String(localized: "Code redemption failed: \(error.localizedDescription)")
                )
            }
        }
    }

    private var premiumRedeemCodeRowLabel: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.brandGradient.opacity(0.10))
                    .frame(width: 40, height: 40)
                Image(systemName: "giftcard.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.Colors.brandGradientStart)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                Text("Redeem code")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Apple promo or gift card")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(Theme.Spacing.lg)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
    }

    @ViewBuilder
    private var premiumRedeemFeedback: some View {
        if let feedback = premiumManager.redemptionFeedback {
            premiumRedeemFeedbackRow(feedback)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func premiumRedeemFeedbackRow(_ feedback: PremiumManager.RedemptionFeedback)
        -> some View
    {
        let isSuccess: Bool
        let iconName: String
        let tint: Color
        let message: String
        switch feedback {
        case .success(let text):
            isSuccess = true
            iconName = "checkmark.circle.fill"
            tint = Theme.Colors.success
            message = text
        case .failure(let text):
            isSuccess = false
            iconName = "exclamationmark.triangle.fill"
            tint = Theme.Colors.warning
            message = text
        }
        return HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(isSuccess ? "Redemption succeeded. \(message)" : "Redemption failed. \(message)")
        )
        .accessibilityAddTraits(.isStaticText)
    }

    private var premiumActiveCard: some View {
        VStack(spacing: Theme.Spacing.md) {
            premiumActiveHeader
            premiumActiveExpiryBanner
            premiumActiveManageButton
        }
        .padding(Theme.Spacing.lg)
        .background(
            ZStack {
                Theme.Colors.surfaceCard
                Theme.Colors.brandGradient.opacity(0.04)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Theme.Colors.brandGradientStart.opacity(0.15), lineWidth: 1)
        )
        .shadow(
            color: Theme.Shadows.small.color,
            radius: Theme.Shadows.small.radius,
            x: Theme.Shadows.small.x,
            y: Theme.Shadows.small.y
        )
    }

    private var premiumActiveHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.brandGradient.opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.Colors.brandGradientStart)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Premium Active")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.success)
                }
                if let expDate = premiumManager.subscriptionExpirationDate {
                    Text("Renews \(expDate, style: .date)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    Text("All features unlocked")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }

            Spacer()

            PremiumBadgeView(size: .standard)
        }
    }

    @ViewBuilder
    private var premiumActiveExpiryBanner: some View {
        if let expDate = premiumManager.subscriptionExpirationDate,
            expDate.timeIntervalSinceNow < 3 * 86400 && expDate.timeIntervalSinceNow > 0
        {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Subscription renews in \(Int(expDate.timeIntervalSinceNow / 86400)) day(s)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
        }
    }

    private var premiumActiveManageButton: some View {
        Button {
            Task {
                if let windowScene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first
                {
                    try? await AppStore.showManageSubscriptions(in: windowScene)
                }
            }
        } label: {
            HStack {
                Image(systemName: "gear.badge.checkmark")
                    .font(.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: 28)
                Text("Manage Subscription")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Appearance Section (Visual Showcase)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Section header
            Text("Appearance")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, Theme.Spacing.lg)

            // Visual theme cards - larger, more expressive
            HStack(spacing: Theme.Spacing.md) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    let isSelected = themeManager.appearanceMode == mode
                    Button {
                        withAnimation(Theme.AnimationPresets.bouncy) {
                            themeManager.appearanceMode = mode
                        }
                    } label: {
                        VStack(spacing: Theme.Spacing.sm) {
                            // Mini device preview
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(mode == .dark ? Color.black.opacity(0.85) : mode == .light ? Color.white : Color.gray.opacity(0.2))
                                    .frame(height: 72)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .stroke(
                                                isSelected
                                                    ? Theme.Colors.brandGradientStart
                                                    : Theme.Colors.textTertiary.opacity(0.2),
                                                lineWidth: isSelected ? 2 : 1
                                            )
                                    )

                                // Mini content lines inside preview
                                VStack(alignment: .leading, spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(mode == .dark ? Color.white.opacity(0.4) : Color.black.opacity(0.15))
                                        .frame(width: 36, height: 4)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(mode == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.08))
                                        .frame(width: 28, height: 3)
                                    HStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Theme.Colors.brandGradientStart.opacity(0.5))
                                            .frame(width: 12, height: 12)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(mode == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.06))
                                            .frame(width: 20, height: 3)
                                    }
                                }
                                .padding(Theme.Spacing.sm)
                            }

                            // Label + selection dot
                            VStack(spacing: Theme.Spacing.xs) {
                                Text(mode.displayName)
                                    .font(Theme.Typography.caption)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundStyle(
                                        isSelected
                                            ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)

                                Circle()
                                    .fill(isSelected ? Theme.Colors.brandGradientStart : Color.clear)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .scaleEffect(isSelected ? 1.03 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .animation(Theme.AnimationPresets.smooth, value: themeManager.appearanceMode)
        .sensoryFeedback(.impact(weight: .light), trigger: themeManager.appearanceMode)
    }

    // MARK: - Audio Quality Picker (Premium-gated)

    private var audioQualityPicker: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ForEach(AudioQuality.allCases, id: \.self) { quality in
                let isSelected = viewModel.audioQuality == quality
                let isLocked = quality == .high && !premiumManager.isPremium

                Button {
                    if isLocked {
                        showQualityPaywall = true
                        mediumHapticTrigger.toggle()
                    } else {
                        withAnimation(Theme.AnimationPresets.bouncy) {
                            viewModel.audioQuality = quality
                        }
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Text(quality.displayName)
                            .font(Theme.Typography.caption)
                            .fontWeight(isSelected ? .semibold : .medium)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                            Text("PRO")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundStyle(
                        isSelected
                            ? .white
                            : Theme.Colors.textSecondary
                    )
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.Colors.brandGradient)
                                .matchedGeometryEffect(id: "qualitySelector", in: qualityNamespace)
                                .shadow(color: Theme.Colors.brandGradientStart.opacity(0.35), radius: 4, x: 0, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.xxxs)
        .fixedSize()
        .background(Theme.Colors.surfaceCard, in: Capsule())
    }

    // MARK: - Helpers

    private func regionDisplayName(_ code: String) -> String {
        switch code {
        case "VN": return String(localized: "🇻🇳 Vietnam")
        case "US": return String(localized: "🇺🇸 United States")
        case "JP": return String(localized: "🇯🇵 Japan")
        case "KR": return String(localized: "🇰🇷 Korea")
        default: return code
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        switch code {
        case "vi": return String(localized: "🇻🇳 Vietnamese")
        case "en": return String(localized: "🇺🇸 English")
        case "ja": return String(localized: "🇯🇵 Japanese")
        case "ko": return String(localized: "🇰🇷 Korean")
        default: return code
        }
    }
}
