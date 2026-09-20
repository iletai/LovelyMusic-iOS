import Foundation

enum AppConstants {
    static let youtubeUserAgent =
        "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    static var youtubeStreamHeaders: [String: String] {
        [
            "User-Agent": youtubeUserAgent,
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/",
        ]
    }

    enum Cache {
        /// ContentCache actor TTL for browse/search results.
        static let contentTTL: TimeInterval = 300
        /// Maximum entries per content type in ContentCache.
        static let maxEntriesPerType = 50
        /// Maximum on-disk audio cache size in bytes (200 MB).
        static let audioMaxBytes: Int64 = 200 * 1024 * 1024
    }

    enum Playback {
        /// Stall detection interval in seconds.
        static let stallCheckInterval: TimeInterval = 5
        /// Progress threshold (0–1) to trigger next-track prefetch.
        static let prefetchThreshold: Double = 0.75
    }

    enum Stream {
        /// YouTube stream URL expiry window in seconds (6 hours).
        static let urlExpiry: TimeInterval = 21600
        /// Overall timeout for stream resolution in seconds.
        static let resolveTimeout: TimeInterval = 20
    }

    enum Retry {
        /// Maximum number of player resolution attempts.
        static let maxAttempts = 3
        /// Backoff delays in milliseconds per attempt index.
        static let backoffDelaysMs: [UInt64] = [0, 500, 1500]
    }

    enum History {
        /// Maximum number of recently played songs to persist.
        static let maxItems = 50
    }

    enum Home {
        /// Maximum number of home feed sections to keep in memory.
        static let maxSections = 50
    }
}
