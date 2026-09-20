import SwiftUI

struct SeasonalBannerView: View {
    let config: SeasonalThemeConfig
    let preset: SeasonalThemePreset?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if config.isEnabled {
            ZStack(alignment: .bottomLeading) {
                // Background Gradient or Image
                if !config.bannerImageURL.isEmpty {
                    AsyncThumbnail(
                        url: config.bannerImageURL,
                        size: 320,
                        cornerRadius: Theme.CornerRadius.large
                    )
                    .frame(height: 140)
                    .clipped()
                } else {
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .fill(
                            LinearGradient(
                                colors: cardGradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 130)
                }

                // Decorative festive icon in background
                HStack {
                    Spacer()
                    Image(systemName: iconName)
                        .font(.system(size: 72))
                        .foregroundStyle(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                        .rotationEffect(.degrees(12))
                        .offset(x: 10, y: 10)
                }
                .padding(.trailing, Theme.Spacing.lg)

                // Text Content
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: iconName)
                            .font(Theme.Typography.caption2.weight(.bold))
                            .foregroundStyle(badgeForeground)

                        Text(badgeTitle.uppercased())
                            .font(Theme.Typography.caption2.weight(.heavy))
                            .foregroundStyle(badgeForeground)
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xxxs)
                    .background(badgeBackground)
                    .clipShape(Capsule())

                    Text(displayTitle)
                        .font(Theme.Typography.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(textPrimaryColor)
                        .lineLimit(1)

                    if !displaySubtitle.isEmpty {
                        Text(displaySubtitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(textSecondaryColor)
                            .lineLimit(1)
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .stroke(isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: isDark ? (cardGradientColors.first?.opacity(0.3) ?? .clear) : Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var textPrimaryColor: Color {
        isDark ? .white : Color(hex: "#1A1625")
    }

    private var textSecondaryColor: Color {
        isDark ? .white.opacity(0.85) : Color(hex: "#1A1625").opacity(0.72)
    }

    private var badgeForeground: Color {
        isDark ? .white : .white
    }

    private var badgeBackground: Color {
        if isDark {
            return Color.black.opacity(0.40)
        } else {
            return Color(hex: preset?.primaryColorHex(for: false) ?? "#8B5CF6").opacity(0.90)
        }
    }

    private var iconName: String {
        if !config.iconName.isEmpty { return config.iconName }
        return preset?.icon ?? "sparkles"
    }

    private var badgeTitle: String {
        if !config.badgeText.isEmpty { return config.badgeText }
        return preset?.displayName ?? "Special Season"
    }

    private var displayTitle: String {
        if !config.bannerTitle.isEmpty { return config.bannerTitle }
        switch preset {
        case .christmas: return "Merry Christmas & Happy Holidays 🎄"
        case .newYear: return "Happy New Year 🎆"
        case .tet: return "Chúc Mừng Năm Mới 🧧"
        case .halloween: return "Spooky Season 🎃"
        case .valentine: return "Season of Love 💖"
        case .summer: return "Summer Vibes 🏖️"
        case .autumn: return "Autumn Melodies 🍂"
        case .spring: return "Spring Blossom 🌸"
        case .morning: return "Good Morning ☀️"
        case .afternoon: return "Good Afternoon ☕️"
        case .evening: return "Good Evening 🌙"
        case .night: return "Peaceful Night 🌌"
        case .none: return "Seasonal Highlights ✨"
        }
    }

    private var displaySubtitle: String {
        if !config.bannerSubtitle.isEmpty { return config.bannerSubtitle }
        switch preset {
        case .christmas: return "Cozy tunes for the winter season"
        case .newYear, .tet: return "Celebratory hits and festive beats"
        case .halloween: return "Thrilling playlists for dark nights"
        case .valentine: return "Romantic melodies to share together"
        case .summer: return "Upbeat summer soundtracks for sunny days"
        case .autumn: return "Warm coffee and soothing acoustic vibes"
        case .spring: return "Fresh acoustic sounds and uplifting songs"
        case .morning: return "Energizing melodies to start your day"
        case .afternoon: return "Gentle focus tunes for working and relaxing"
        case .evening: return "Unwind with cozy evening melodies"
        case .night: return "Deep chill sounds for peaceful dreams"
        case .none: return "Curated tracks for this special time"
        }
    }

    private var cardGradientColors: [Color] {
        let customHexes = isDark ? config.cardGradientDark : config.cardGradientLight
        if !customHexes.isEmpty {
            let colors = customHexes.map { Color(hex: $0) }
            if colors.count >= 2 { return colors }
        }
        if let preset {
            return preset.cardGradientHexes(for: isDark).map { Color(hex: $0) }
        }
        return isDark
            ? [Theme.Colors.brandGradientStart, Theme.Colors.brandGradientEnd]
            : [Color(hex: "#F5F3FF"), Color(hex: "#FDF2F8")]
    }
}
