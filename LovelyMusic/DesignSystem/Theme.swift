import SwiftUI

enum Theme {
    // MARK: - Colors
    enum Colors {
        // Brand Gradient (same in both modes)
        static let brandGradientStart = Color(hex: "#8B5CF6")
        static let brandGradientEnd = Color(hex: "#EC4899")
        static let brandGradient = LinearGradient(
            colors: [brandGradientStart, brandGradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Legacy aliases for compatibility
        static let primary = brandGradientStart
        static let label = textPrimary
        static let secondaryLabel = textSecondary

        // Backgrounds — Round 2 warm-white ramp (Q1 LOCKED). Dark values frozen.
        static let backgroundPrimary = Color(
            light: Color(hex: "#F9F8FC"), dark: Color(hex: "#0A0A0A"))
        static let background = backgroundPrimary
        static let backgroundSecondary = Color(
            light: Color(hex: "#F0EEF5"), dark: Color(hex: "#1A1A1A"))
        static let secondaryBackground = backgroundSecondary
        static let backgroundTertiary = Color(
            light: Color(hex: "#E6E3EF"), dark: Color(hex: "#2A2A2A"))
        static let tertiaryBackground = backgroundTertiary
        static let backgroundElevated = Color(
            light: Color(hex: "#FFFFFF"), dark: Color(hex: "#1E1E1E"))

        // Surfaces — Round 2: cards are pure white in light; selected uses solid brand fill.
        static let surfaceCard = Color(
            light: Color(hex: "#FFFFFF"), dark: Color.white.opacity(0.05))
        static let surfaceHover = Color(
            light: Color(hex: "#8B5CF6").opacity(0.10), dark: Color.white.opacity(0.08))
        /// Selected fill — solid brand purple in light. Components must pair with `onBrand` foreground.
        static let surfaceSelected = Color(
            light: Color(hex: "#8B5CF6"), dark: Color.white.opacity(0.12))
        static let surfaceOverlay = Color.black.opacity(0.60)

        // Text — Round 2: textTertiary opacity bumps 0.55 → 0.60 for AA-body on captions.
        static let textPrimary = Color(light: Color(hex: "#1A1625"), dark: Color.white)
        static let textSecondary = Color(
            light: Color(hex: "#1A1625").opacity(0.62), dark: Color.white.opacity(0.75))
        static let textTertiary = Color(
            light: Color(hex: "#1A1625").opacity(0.60), dark: Color.white.opacity(0.55))
        static let textDisabled = Color(
            light: Color(hex: "#1A1625").opacity(0.25), dark: Color.white.opacity(0.25))
        /// Foreground on solid brand purple surfaces (e.g., `surfaceSelected`).
        static let onBrand = Color.white

        // Semantic (same in both modes)
        static let success = Color(hex: "#22C55E")
        static let error = Color(hex: "#EF4444")
        static let warning = Color(hex: "#F59E0B")
        static let info = Color(hex: "#3B82F6")

        // Player (always dark aesthetic — frozen)
        static let playerGradientTop = Color(hex: "#1A1025")
        static let playerGradientBottom = Color(hex: "#0A0A0F")
        // Mini-player surface — Q3: solid white in light (depth via shadow + hairline, NOT material).
        static let miniPlayerBackground = Color(
            light: Color(hex: "#FFFFFF"), dark: Color(hex: "#1A1A1A").opacity(0.95))
        static let miniPlayerBg = miniPlayerBackground
        static let progressGlow = Color(hex: "#8B5CF6").opacity(0.60)

        // Premium Colors — Q2: paywall surfaces ONLY. Do not use elsewhere.
        static let premiumGold = Color(hex: "#FFD700")
        static let premiumOrange = Color(hex: "#FFA500")
        static let premiumGradient = LinearGradient(
            colors: [premiumGold, premiumOrange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Dividers — Round 2: neutral hairline (was brand-tinted, invisible against lavender bg).
        static let divider = Color(
            light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08))
        static let separator = divider
        /// Stronger divider for grouping inside cards.
        static let dividerStrong = Color(
            light: Color.black.opacity(0.12), dark: Color.white.opacity(0.12))

        // Overlays
        static let overlayUltraLight = Color(
            light: Color.black.opacity(0.04), dark: Color.white.opacity(0.06))
        static let overlayLight = Color(
            light: Color.black.opacity(0.08), dark: Color.white.opacity(0.12))
        static let overlayMedium = Color(
            light: Color.black.opacity(0.16), dark: Color.white.opacity(0.20))
        static let overlayDark = Color.black.opacity(0.3)
        static let overlayHeavy = Color.black.opacity(0.7)
    }

    // MARK: - Typography (Dynamic Type via TextStyle, Rounded design)
    enum Typography {
        static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let title = Font.system(.title, design: .rounded, weight: .bold)
        static let title2 = Font.system(.title2, design: .rounded, weight: .semibold)
        static let title3 = Font.system(.title3, design: .rounded, weight: .semibold)
        static let headline = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body, design: .rounded)
        static let subheadline = Font.system(.subheadline, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded)
        static let captionSecondary = Font.system(.caption2, design: .rounded)
        static let caption2 = captionSecondary
        // Dynamic Type-enabled tokens (previously fixed-size, now scales with user settings)
        static let badge = Font.system(.caption2, design: .rounded).weight(.heavy)
        static let display = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let caption3 = Font.system(.caption2, design: .rounded).weight(.medium)
        static let tabIcon = Font.system(.footnote, design: .rounded).weight(.semibold)
    }

    // MARK: - Size Tokens
    enum SizeTokens {
        // Touch targets
        static let touchTarget: CGFloat = 44
        static let compactTouchTarget: CGFloat = 36

        // Avatars & Thumbnails
        static let avatarSmall: CGFloat = 36
        static let avatar: CGFloat = 48
        static let avatarLarge: CGFloat = 80

        // Artwork
        static let artworkSmall: CGFloat = 48
        static let artworkMedium: CGFloat = 120
        static let artworkLarge: CGFloat = 220
        static let artworkExtraLarge: CGFloat = 280

        // List items
        static let listItemCompact: CGFloat = 48
        static let listItemStandard: CGFloat = 60
        static let listItemLarge: CGFloat = 80

        // Icons
        static let iconSmall: CGFloat = 20
        static let iconMedium: CGFloat = 24
        static let iconLarge: CGFloat = 32

        // Dividers
        static let divider: CGFloat = 0.5
        static let dividerThick: CGFloat = 1
    }

    // MARK: - Spacing
    enum Spacing {
        static let xxxs: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: - Corner Radius
    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xl: CGFloat = 20
        static let extraLarge: CGFloat = 24
        static let full: CGFloat = 9999
    }

    // MARK: - Shadows
    enum Shadows {
        static let small = ShadowStyle(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        static let medium = ShadowStyle(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        static let large = ShadowStyle(color: .black.opacity(0.16), radius: 16, x: 0, y: 8)
        static let glow = ShadowStyle(
            color: Colors.brandGradientStart.opacity(0.40), radius: 20, x: 0, y: 0)
        static let colored = ShadowStyle(color: .black.opacity(0.30), radius: 24, x: 0, y: 12)
    }

    // MARK: - Animation Presets
    // SAFETY: These backing vars use nonisolated(unsafe) because:
    // 1. Writes occur ONLY from MainActor context (DIContainer.init → FeatureFlagManager.init,
    //    and FeatureFlagManager.fetchFlags via await MainActor.run)
    // 2. Reads occur ONLY from SwiftUI views (main thread)
    // 3. After app launch, values are effectively read-only
    // Using @MainActor would cascade isolation requirements into the Domain layer.
    // All 60+ call sites using Theme.AnimationPresets automatically pick up CMS values.
    enum AnimationPresets {
        nonisolated(unsafe) static var bouncyResponse: Double = 0.3  // anim_bouncy_response
        nonisolated(unsafe) static var bouncyDamping: Double = 0.6  // anim_bouncy_damping
        nonisolated(unsafe) static var smoothResponse: Double = 0.4  // anim_smooth_response
        nonisolated(unsafe) static var smoothDamping: Double = 0.8  // anim_smooth_damping
        nonisolated(unsafe) static var playerResponse: Double = 0.5  // anim_player_response
        nonisolated(unsafe) static var playerDamping: Double = 0.85  // anim_player_damping
        nonisolated(unsafe) static var gentleDuration: Double = 0.25  // anim_gentle_duration
        nonisolated(unsafe) static var crossfadeDuration: Double = 0.3  // anim_fade_duration

        static var bouncy: Animation {
            .spring(response: bouncyResponse, dampingFraction: bouncyDamping)
        }
        static var smooth: Animation {
            .spring(response: smoothResponse, dampingFraction: smoothDamping)
        }
        static var playerTransition: Animation {
            .spring(response: playerResponse, dampingFraction: playerDamping)
        }
        static var gentle: Animation {
            .easeInOut(duration: gentleDuration)
        }
        static var crossfade: Animation {
            .easeInOut(duration: crossfadeDuration)
        }
        static let colorShift = Animation.easeInOut(duration: 0.8)
    }
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}
