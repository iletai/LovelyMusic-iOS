import Foundation
import UIKit

enum AudioQuality: String, CaseIterable, Codable, Sendable {
    case low, medium, high

    var displayName: String {
        switch self {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    /// Returns max bitrate for this quality level.
    /// If a FeatureFlagManager is provided, uses CMS-configured values; otherwise uses defaults.
    func maxBitrate(from flags: FeatureFlagManager? = nil) -> Int {
        switch self {
        case .low: return flags?.audioBitrateLow ?? 64_000
        case .medium: return flags?.audioBitrateMedium ?? 128_000
        case .high: return flags?.audioBitrateHigh ?? 256_000
        }
    }
}

enum SleepTimerOption: String, CaseIterable {
    case off, min15, min30, min45, min60, endOfTrack

    var displayName: String {
        switch self {
        case .off: return String(localized: "Off")
        case .min15: return String(localized: "15 minutes")
        case .min30: return String(localized: "30 minutes")
        case .min45: return String(localized: "45 minutes")
        case .min60: return String(localized: "1 hour")
        case .endOfTrack: return String(localized: "End of Track")
        }
    }
}

enum LyricsFontSize: String, CaseIterable {
    case small, medium, large

    var displayName: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }
}

@MainActor @Observable
final class SettingsViewModel {
    let authManager: YouTubeAuthManager
    let playbackQualitySettings: PlaybackQualitySettings
    var audioCacheManager: AudioCacheManager?
    var showingLogin: Bool = false

    var isLoggedIn: Bool { authManager.isLoggedIn }
    var accountName: String? { authManager.accountName }

    var audioQuality: AudioQuality {
        get { playbackQualitySettings.wifi }
        set { playbackQualitySettings.wifi = newValue }
    }

    var videoQuality: VideoQuality = .auto {
        didSet { UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality") }
    }

    /// Returns effective quality capped at medium for free users
    func effectiveQuality(isPremium: Bool) -> AudioQuality {
        playbackQualitySettings.effectiveStreamingQuality(
            for: .wifi(expensive: false, constrained: false),
            isPremium: isPremium
        )
    }

    /// Source-compatible hook retained while entitlement capping moves to resolution.
    func capQualityIfNeeded(isPremium: Bool) {
        _ = isPremium
        // Compatibility no-op. Entitlement is applied when a stream resolves,
        // preserving the user's stored quality intent across plan changes.
    }

    var sleepTimer: SleepTimerOption = .off {
        didSet { UserDefaults.standard.set(sleepTimer.rawValue, forKey: "sleepTimer") }
    }

    var skipSilence: Bool = false {
        didSet {
            UserDefaults.standard.set(skipSilence, forKey: "skipSilence")
            NotificationCenter.default.post(name: .skipSilenceChanged, object: nil)
        }
    }

    var audioNormalization: Bool = false {
        didSet {
            UserDefaults.standard.set(audioNormalization, forKey: "audioNormalization")
            NotificationCenter.default.post(name: .audioNormalizationChanged, object: nil)
        }
    }

    var persistentQueue: Bool = false {
        didSet { UserDefaults.standard.set(persistentQueue, forKey: "persistentQueue") }
    }

    var autoSkipOnError: Bool = true {
        didSet { UserDefaults.standard.set(autoSkipOnError, forKey: "autoSkipOnError") }
    }

    var autoplayRelatedSongs: Bool = true {
        didSet {
            UserDefaults.standard.set(autoplayRelatedSongs, forKey: "isAutoplayEnabled")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var crossfadeDuration: Double = 0 {
        didSet {
            UserDefaults.standard.set(crossfadeDuration, forKey: "crossfade_duration")
            NotificationCenter.default.post(name: .crossfadeDurationChanged, object: nil)
        }
    }

    var showLyricsAutomatically: Bool = false {
        didSet {
            UserDefaults.standard.set(showLyricsAutomatically, forKey: "showLyricsAutomatically")
        }
    }

    var lyricsFontSize: LyricsFontSize = .medium {
        didSet { UserDefaults.standard.set(lyricsFontSize.rawValue, forKey: "lyricsFontSize") }
    }

    var showLyricsTranslation: Bool = true {
        didSet { UserDefaults.standard.set(showLyricsTranslation, forKey: "showLyricsTranslation") }
    }

    var region: String = "VN" {
        didSet {
            guard oldValue != region else { return }
            UserDefaults.standard.set(region, forKey: "region")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var language: String = "vi" {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language, forKey: "language")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Reload content language & region from UserDefaults (called when app language changes)
    func reloadContentLocale() {
        region = UserDefaults.standard.string(forKey: "region") ?? "VN"
        language = UserDefaults.standard.string(forKey: "language") ?? "vi"
    }

    init(
        authManager: YouTubeAuthManager,
        playbackQualitySettings: PlaybackQualitySettings? = nil
    ) {
        self.authManager = authManager
        self.playbackQualitySettings = playbackQualitySettings ?? PlaybackQualitySettings()
        self.videoQuality =
            VideoQuality(rawValue: UserDefaults.standard.string(forKey: "videoQuality") ?? "auto")
            ?? .auto
        self.sleepTimer =
            SleepTimerOption(rawValue: UserDefaults.standard.string(forKey: "sleepTimer") ?? "off")
            ?? .off
        self.skipSilence = UserDefaults.standard.bool(forKey: "skipSilence")
        self.audioNormalization = UserDefaults.standard.bool(forKey: "audioNormalization")
        self.persistentQueue = UserDefaults.standard.bool(forKey: "persistentQueue")
        self.autoSkipOnError =
            UserDefaults.standard.object(forKey: "autoSkipOnError") as? Bool ?? true
        self.autoplayRelatedSongs =
            UserDefaults.standard.object(forKey: "isAutoplayEnabled") as? Bool ?? true
        self.crossfadeDuration = UserDefaults.standard.double(forKey: "crossfade_duration")
        self.region = UserDefaults.standard.string(forKey: "region") ?? "VN"
        self.language = UserDefaults.standard.string(forKey: "language") ?? "vi"
        self.pauseListenHistory = UserDefaults.standard.bool(forKey: "pauseListenHistory")
        self.pauseSearchHistory = UserDefaults.standard.bool(forKey: "pauseSearchHistory")
        self.hideExplicitContent = UserDefaults.standard.bool(forKey: "hideExplicitContent")
        self.disableScreenshots = UserDefaults.standard.bool(forKey: "disableScreenshots")
        self.showLyricsAutomatically = UserDefaults.standard.bool(forKey: "showLyricsAutomatically")
        self.lyricsFontSize =
            LyricsFontSize(
                rawValue: UserDefaults.standard.string(forKey: "lyricsFontSize") ?? "medium")
            ?? .medium
        self.showLyricsTranslation =
            UserDefaults.standard.object(forKey: "showLyricsTranslation") as? Bool ?? true
    }

    private(set) var cacheSize: String = ""
    var isClearingCache = false
    var showCacheCleared = false

    private(set) var audioCacheSize: String = ""
    var isClearingAudioCache = false
    var showAudioCacheCleared = false

    var isClearingListenHistory = false
    var isClearingSearchHistory = false
    var showListenHistoryCleared = false
    var showSearchHistoryCleared = false

    func updateCacheSize() {
        let httpSize = Int64(URLCache.shared.currentDiskUsage)
        let audioSize = audioCacheManager?.totalSize ?? 0
        let totalSize = httpSize + audioSize
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        cacheSize = formatter.string(fromByteCount: totalSize)
    }

    func updateAudioCacheSize() {
        audioCacheSize = audioCacheManager?.formattedTotalSize() ?? "0 MB"
    }

    var pauseListenHistory: Bool = false {
        didSet {
            UserDefaults.standard.set(pauseListenHistory, forKey: "pauseListenHistory")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var pauseSearchHistory: Bool = false {
        didSet {
            UserDefaults.standard.set(pauseSearchHistory, forKey: "pauseSearchHistory")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var hideExplicitContent: Bool = false {
        didSet {
            UserDefaults.standard.set(hideExplicitContent, forKey: "hideExplicitContent")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var disableScreenshots: Bool = false {
        didSet {
            UserDefaults.standard.set(disableScreenshots, forKey: "disableScreenshots")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var showClearListenHistoryAlert = false
    var showClearSearchHistoryAlert = false
    var showClearCacheAlert = false
    var showSignOutAlert = false
    var showResetAllAlert = false
    var showResetAllCompleted = false

    func clearListenHistory() {
        isClearingListenHistory = true
        UserDefaults.standard.removeObject(forKey: "recentlyPlayed")
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        isClearingListenHistory = false
        showListenHistoryCleared = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showListenHistoryCleared = false
        }
    }

    func clearSearchHistory() {
        isClearingSearchHistory = true
        UserDefaults.standard.removeObject(forKey: "searchHistory")
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        isClearingSearchHistory = false
        showSearchHistoryCleared = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showSearchHistoryCleared = false
        }
    }

    func clearCache() {
        isClearingCache = true
        URLCache.shared.removeAllCachedResponses()
        audioCacheManager?.clearAll()
        updateCacheSize()
        isClearingCache = false
        showCacheCleared = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showCacheCleared = false
        }
    }

    func signOut() {
        authManager.logout()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    /// Resets all user-facing app settings to their defaults.
    /// Does NOT clear caches, history, playlists, or sign the user out —
    /// those have dedicated destructive actions.
    func resetAllSettings() {
        let defaults = UserDefaults.standard
        let keys = [
            "audioQuality", "videoQuality", "sleepTimer", "skipSilence", "audioNormalization",
            "persistentQueue", "autoSkipOnError", "isAutoplayEnabled",
            "crossfade_duration", "region", "language",
            "pauseListenHistory", "pauseSearchHistory", "hideExplicitContent",
            "disableScreenshots", "showLyricsAutomatically", "lyricsFontSize",
            "showLyricsTranslation",
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }

        // Re-seed local state from cleared UserDefaults so UI reflects defaults.
        playbackQualitySettings.resetToDefaults()
        videoQuality = .auto
        sleepTimer = .off
        skipSilence = false
        audioNormalization = false
        persistentQueue = false
        autoSkipOnError = true
        autoplayRelatedSongs = true
        crossfadeDuration = 0
        region = "VN"
        language = "vi"
        pauseListenHistory = false
        pauseSearchHistory = false
        hideExplicitContent = false
        disableScreenshots = false
        showLyricsAutomatically = false
        lyricsFontSize = .medium
        showLyricsTranslation = true

        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showResetAllCompleted = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showResetAllCompleted = false
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("settingsChanged")
    static let skipSilenceChanged = Notification.Name("skipSilenceChanged")
    static let audioNormalizationChanged = Notification.Name("audioNormalizationChanged")
    static let crossfadeDurationChanged = Notification.Name("crossfadeDurationChanged")
    /// Posted by `InnerTubeAPI` when its `degradedVisitorState` flips. UserInfo
    /// `["degraded": Bool]`. Consumers (e.g. `HomeViewModel`) may surface a soft
    /// banner after a grace period to inform users that recommendations may be
    /// reduced quality.
    static let innerTubeDegradedStateChanged = Notification.Name("innerTubeDegradedStateChanged")
}
