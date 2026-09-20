import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system, light, dark, pureBlack

    var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .pureBlack: String(localized: "Pure Black")
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .pureBlack: "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .pureBlack: .dark
        }
    }
}

enum SeasonalThemePreset: String, CaseIterable, Sendable {
    case christmas
    case newYear = "new_year"
    case tet
    case halloween
    case valentine
    case summer
    case autumn
    case spring
    case morning
    case afternoon
    case evening
    case night

    var displayName: String {
        switch self {
        case .christmas: "Christmas 🎄"
        case .newYear: "New Year 🎆"
        case .tet: "Lunar New Year / Tết 🧧"
        case .halloween: "Halloween 🎃"
        case .valentine: "Valentine 💖"
        case .summer: "Summer 🏖️"
        case .autumn: "Autumn 🍂"
        case .spring: "Spring 🌸"
        case .morning: "Morning ☀️"
        case .afternoon: "Afternoon ☕️"
        case .evening: "Evening 🌙"
        case .night: "Night 🌌"
        }
    }

    var icon: String {
        switch self {
        case .christmas: "snowflake"
        case .newYear, .tet: "sparkles"
        case .halloween: "moon.stars.fill"
        case .valentine: "heart.fill"
        case .summer: "sun.max.fill"
        case .autumn: "leaf.fill"
        case .spring: "camera.macro"
        case .morning: "sun.max.fill"
        case .afternoon: "cup.and.saucer.fill"
        case .evening: "moon.stars.fill"
        case .night: "sparkles"
        }
    }

    func primaryColorHex(for isDark: Bool) -> String {
        if isDark {
            switch self {
            case .christmas: return "#FF4D4D"
            case .newYear, .tet: return "#EF4444"
            case .halloween: return "#F97316"
            case .valentine: return "#FB7185"
            case .summer: return "#06B6D4"
            case .autumn: return "#FB923C"
            case .spring: return "#4ADE80"
            case .morning: return "#38BDF8"
            case .afternoon: return "#FB923C"
            case .evening: return "#A78BFA"
            case .night: return "#818CF8"
            }
        } else {
            switch self {
            case .christmas: return "#DC2626"
            case .newYear, .tet: return "#DC2626"
            case .halloween: return "#EA580C"
            case .valentine: return "#E11D48"
            case .summer: return "#0284C7"
            case .autumn: return "#C2410C"
            case .spring: return "#16A34A"
            case .morning: return "#0284C7"
            case .afternoon: return "#C2410C"
            case .evening: return "#7C3AED"
            case .night: return "#6366F1"
            }
        }
    }

    func secondaryColorHex(for isDark: Bool) -> String {
        if isDark {
            switch self {
            case .christmas: return "#22C55E"
            case .newYear, .tet: return "#F59E0B"
            case .halloween: return "#A855F7"
            case .valentine: return "#E11D48"
            case .summer: return "#EAB308"
            case .autumn: return "#D97706"
            case .spring: return "#F472B6"
            case .morning: return "#F59E0B"
            case .afternoon: return "#D97706"
            case .evening: return "#3B82F6"
            case .night: return "#4F46E5"
            }
        } else {
            switch self {
            case .christmas: return "#16A34A"
            case .newYear, .tet: return "#D97706"
            case .halloween: return "#9333EA"
            case .valentine: return "#F43F5E"
            case .summer: return "#D97706"
            case .autumn: return "#B45309"
            case .spring: return "#DB2777"
            case .morning: return "#F59E0B"
            case .afternoon: return "#B45309"
            case .evening: return "#2563EB"
            case .night: return "#4338CA"
            }
        }
    }

    func backgroundGradientHexes(for isDark: Bool) -> [String] {
        if isDark {
            switch self {
            case .christmas: return ["#1A0B0B", "#0B150B"]
            case .newYear, .tet: return ["#1E0A0A", "#140B00"]
            case .halloween: return ["#1A0C02", "#13081E"]
            case .valentine: return ["#1F0A11", "#12050A"]
            case .summer: return ["#04151C", "#0B1A12"]
            case .autumn: return ["#1C0E07", "#120B04"]
            case .spring: return ["#0A1A0F", "#1A0F16"]
            case .morning: return ["#04151C", "#0B1A12"]
            case .afternoon: return ["#1C0E07", "#120B04"]
            case .evening: return ["#110E24", "#0C1020"]
            case .night: return ["#090A1A", "#0D0B1F"]
            }
        } else {
            switch self {
            case .christmas: return ["#FEF2F2", "#F0FDF4"]
            case .newYear, .tet: return ["#FFF1F2", "#FEF3C7"]
            case .halloween: return ["#FFF7ED", "#FAF5FF"]
            case .valentine: return ["#FFF1F2", "#FFE4E6"]
            case .summer: return ["#F0F9FF", "#FEFCE8"]
            case .autumn: return ["#FFF7ED", "#FEF3C7"]
            case .spring: return ["#F0FDF4", "#FDF2F8"]
            case .morning: return ["#F0F9FF", "#FEFCE8"]
            case .afternoon: return ["#FFF7ED", "#FEF3C7"]
            case .evening: return ["#FAF5FF", "#F0F9FF"]
            case .night: return ["#EEF2FF", "#F5F3FF"]
            }
        }
    }

    func cardGradientHexes(for isDark: Bool) -> [String] {
        if isDark {
            switch self {
            case .christmas: return ["#2D0F0F", "#0F2D14"]
            case .newYear, .tet: return ["#300E0E", "#281700"]
            case .halloween: return ["#2D1404", "#200E33"]
            case .valentine: return ["#330F1C", "#200911"]
            case .summer: return ["#082430", "#142D20"]
            case .autumn: return ["#2E170C", "#211407"]
            case .spring: return ["#122D1B", "#2D1A26"]
            case .morning: return ["#082430", "#142D20"]
            case .afternoon: return ["#2E170C", "#211407"]
            case .evening: return ["#1E163B", "#101D38"]
            case .night: return ["#13142D", "#1A1535"]
            }
        } else {
            switch self {
            case .christmas: return ["#FEE2E2", "#DCFCE7"]
            case .newYear, .tet: return ["#FFE4E6", "#FDE68A"]
            case .halloween: return ["#FFEDD5", "#F3E8FF"]
            case .valentine: return ["#FFE4E6", "#FECDD3"]
            case .summer: return ["#E0F2FE", "#FEF08A"]
            case .autumn: return ["#FFEDD5", "#FDE68A"]
            case .spring: return ["#DCFCE7", "#FCE7F3"]
            case .morning: return ["#E0F2FE", "#FEF08A"]
            case .afternoon: return ["#FFEDD5", "#FDE68A"]
            case .evening: return ["#F3E8FF", "#E0F2FE"]
            case .night: return ["#E0E7FF", "#EDE9FE"]
            }
        }
    }
}

@MainActor @Observable
final class ThemeManager {
    private static let userDefaultsKey = "appearanceMode"
    private let featureFlagManager: FeatureFlagManager?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    var appearanceMode: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.userDefaultsKey) }
    }

    /// The active theme resolved from the current local time & schedules.
    private(set) var activeScheduledTheme: SeasonalThemeConfig = .default

    init(featureFlagManager: FeatureFlagManager? = nil) {
        self.featureFlagManager = featureFlagManager
        self.appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? "system") ?? .system
        refreshCurrentSchedule()
    }

    var preferredColorScheme: ColorScheme? {
        appearanceMode.colorScheme
    }

    var isPureBlack: Bool {
        appearanceMode == .pureBlack
    }

    // MARK: - Dynamic Seasonal Theme Resolution

    /// Re-evaluates the active theme according to `Date()` and schedules the next transition timer.
    func refreshCurrentSchedule(at date: Date = Date(), calendar: Calendar = .current) {
        guard let baseTheme = featureFlagManager?.seasonalTheme else {
            activeScheduledTheme = .default
            return
        }
        let resolved = baseTheme.resolveActiveTheme(at: date, calendar: calendar)
        if activeScheduledTheme != resolved {
            activeScheduledTheme = resolved
        }
        scheduleNextTransition(from: date, calendar: calendar)
    }

    private func scheduleNextTransition(from date: Date, calendar: Calendar) {
        transitionTask?.cancel()
        guard let nextDate = featureFlagManager?.seasonalTheme.nextTransitionDate(from: date, calendar: calendar) else {
            return
        }
        let delay = max(1.0, nextDate.timeIntervalSince(date) + 0.5)
        transitionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refreshCurrentSchedule()
            } catch {}
        }
    }

    var effectiveSeasonalTheme: SeasonalThemeConfig {
        if activeScheduledTheme.isEnabled {
            return activeScheduledTheme
        }
        return featureFlagManager?.seasonalTheme.resolveActiveTheme(at: Date()) ?? .default
    }

    var isSeasonalThemeActive: Bool {
        effectiveSeasonalTheme.isEnabled
    }

    var activeSeasonalPreset: SeasonalThemePreset? {
        let theme = effectiveSeasonalTheme
        guard theme.isEnabled, !theme.themeName.isEmpty else {
            return nil
        }
        return SeasonalThemePreset(rawValue: theme.themeName.lowercased())
    }

    func seasonalAccentColor(for colorScheme: ColorScheme) -> Color? {
        guard isSeasonalThemeActive else { return nil }
        let theme = effectiveSeasonalTheme
        let isDark = colorScheme == .dark
        let customHex = isDark
            ? theme.accentColorDark
            : theme.accentColorLight

        if !customHex.isEmpty {
            return Color(hex: customHex)
        }
        if let preset = activeSeasonalPreset {
            return Color(hex: preset.primaryColorHex(for: isDark))
        }
        return nil
    }

    func seasonalBackgroundGradient(for colorScheme: ColorScheme) -> LinearGradient? {
        guard isSeasonalThemeActive else { return nil }
        let theme = effectiveSeasonalTheme
        let isDark = colorScheme == .dark
        let customHexes = isDark
            ? theme.backgroundGradientDark
            : theme.backgroundGradientLight

        let hexes: [String]
        if !customHexes.isEmpty {
            hexes = customHexes
        } else if let preset = activeSeasonalPreset {
            hexes = preset.backgroundGradientHexes(for: isDark)
        } else {
            return nil
        }

        let colors = hexes.map { Color(hex: $0) }
        guard colors.count >= 2 else { return nil }
        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    func seasonalCardGradient(for colorScheme: ColorScheme) -> LinearGradient? {
        guard isSeasonalThemeActive else { return nil }
        let theme = effectiveSeasonalTheme
        let isDark = colorScheme == .dark
        let customHexes = isDark
            ? theme.cardGradientDark
            : theme.cardGradientLight

        let hexes: [String]
        if !customHexes.isEmpty {
            hexes = customHexes
        } else if let preset = activeSeasonalPreset {
            hexes = preset.cardGradientHexes(for: isDark)
        } else {
            return nil
        }

        let colors = hexes.map { Color(hex: $0) }
        guard colors.count >= 2 else { return nil }
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var seasonalIcon: String? {
        guard isSeasonalThemeActive else { return nil }
        return activeSeasonalPreset?.icon
    }
}
