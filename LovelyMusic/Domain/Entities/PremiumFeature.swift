import SwiftUI

enum PremiumFeature: String, CaseIterable {
    case highQualityAudio
    case offlinePlayback
    case unlimitedSkips
    case syncedLyrics
    case equalizer

    var displayName: LocalizedStringKey {
        switch self {
        case .highQualityAudio: return "High Quality Audio"
        case .offlinePlayback: return "Offline Playback"
        case .unlimitedSkips: return "Unlimited Skips"
        case .syncedLyrics: return "Synced Lyrics"
        case .equalizer: return "Equalizer"
        }
    }

    var description: LocalizedStringKey {
        switch self {
        case .highQualityAudio: return "Listen in the highest audio quality available"
        case .offlinePlayback: return "Download songs and listen offline anywhere"
        case .unlimitedSkips: return "Skip as many songs as you want, anytime"
        case .syncedLyrics: return "Follow along with real-time synced lyrics and translations"
        case .equalizer: return "Fine-tune your sound with custom equalizer presets"
        }
    }

    var iconName: String {
        switch self {
        case .highQualityAudio: return "waveform.badge.plus"
        case .offlinePlayback: return "arrow.down.circle.fill"
        case .unlimitedSkips: return "forward.fill"
        case .syncedLyrics: return "quote.bubble.fill"
        case .equalizer: return "slider.vertical.3"
        }
    }
}
