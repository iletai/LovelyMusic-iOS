import Foundation

/// Persists playback state (queue, position, settings) across app launches.
/// Only saves when the "Persistent Queue" setting is enabled.
@MainActor
final class PlaybackStatePersistence {

    struct PersistedPlaybackState: Codable {
        let queue: [Song]
        let autoplayQueue: [Song]
        let currentIndex: Int
        let currentTime: TimeInterval
        let wasPlaying: Bool
        let shuffleEnabled: Bool
        let repeatMode: String  // RepeatMode raw value
        let savedAt: Date

        // Backward-compatible decoding: autoplayQueue may be missing in old data
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            queue = try container.decode([Song].self, forKey: .queue)
            autoplayQueue = try container.decodeIfPresent([Song].self, forKey: .autoplayQueue) ?? []
            currentIndex = try container.decode(Int.self, forKey: .currentIndex)
            currentTime = try container.decode(TimeInterval.self, forKey: .currentTime)
            wasPlaying = try container.decode(Bool.self, forKey: .wasPlaying)
            shuffleEnabled = try container.decode(Bool.self, forKey: .shuffleEnabled)
            repeatMode = try container.decode(String.self, forKey: .repeatMode)
            savedAt = try container.decode(Date.self, forKey: .savedAt)
        }

        init(
            queue: [Song], autoplayQueue: [Song], currentIndex: Int,
            currentTime: TimeInterval, wasPlaying: Bool,
            shuffleEnabled: Bool, repeatMode: String, savedAt: Date
        ) {
            self.queue = queue
            self.autoplayQueue = autoplayQueue
            self.currentIndex = currentIndex
            self.currentTime = currentTime
            self.wasPlaying = wasPlaying
            self.shuffleEnabled = shuffleEnabled
            self.repeatMode = repeatMode
            self.savedAt = savedAt
        }
    }

    private static let storageKey = "persisted_playback_state"
    private static let settingKey = "persistentQueue"

    /// Whether the user has enabled persistent queue in settings
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.settingKey)
    }

    /// Save current playback state. Debounce-friendly.
    func save(
        queue: [Song],
        autoplayQueue: [Song],
        currentIndex: Int,
        currentTime: TimeInterval,
        isPlaying: Bool,
        shuffleEnabled: Bool,
        repeatMode: String
    ) {
        guard isEnabled, !queue.isEmpty else { return }

        let state = PersistedPlaybackState(
            queue: queue,
            autoplayQueue: autoplayQueue,
            currentIndex: currentIndex,
            currentTime: currentTime,
            wasPlaying: isPlaying,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            savedAt: Date()
        )

        // Encode and write on background thread to avoid blocking the main actor
        let key = Self.storageKey
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(state) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Restore persisted state. Returns nil if nothing saved or expired (>7 days).
    func restore() -> PersistedPlaybackState? {
        guard isEnabled,
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let state = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data)
        else { return nil }

        // Expire after 7 days
        guard Date().timeIntervalSince(state.savedAt) < 7 * 24 * 3600 else {
            clear()
            return nil
        }
        return state
    }

    /// Clear saved state
    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}
