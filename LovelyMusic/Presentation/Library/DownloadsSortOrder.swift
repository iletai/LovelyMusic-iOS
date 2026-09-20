import Foundation

/// polish-E3 — User-facing sort options for the Downloads list.
///
/// The selection persists across launches via `UserDefaults`.
enum DownloadsSortOrder: String, CaseIterable, Identifiable {
    case recentlyAdded
    case titleAZ
    case artistAZ
    case duration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyAdded: return String(localized: "Recently added")
        case .titleAZ: return String(localized: "Title (A-Z)")
        case .artistAZ: return String(localized: "Artist (A-Z)")
        case .duration: return String(localized: "Duration")
        }
    }

    /// `UserDefaults` key used to persist the user's chosen sort order.
    static let userDefaultsKey = "downloads.sortOrder"

    /// Load the persisted sort order, falling back to `.recentlyAdded`.
    static func load(from defaults: UserDefaults = .standard) -> DownloadsSortOrder {
        guard let raw = defaults.string(forKey: userDefaultsKey),
            let order = DownloadsSortOrder(rawValue: raw)
        else {
            return .recentlyAdded
        }
        return order
    }

    /// Persist the chosen sort order.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }

    /// Apply this sort order to a slice of downloaded entries.
    /// `entries` is treated as already in "recently added" insertion order
    /// (newest first), so `.recentlyAdded` returns the input untouched.
    func apply(to entries: [DownloadManager.DownloadedSong])
        -> [DownloadManager.DownloadedSong]
    {
        switch self {
        case .recentlyAdded:
            return entries
        case .titleAZ:
            return entries.sorted {
                $0.song.title.localizedCaseInsensitiveCompare($1.song.title) == .orderedAscending
            }
        case .artistAZ:
            return entries.sorted {
                $0.song.artistName.localizedCaseInsensitiveCompare($1.song.artistName)
                    == .orderedAscending
            }
        case .duration:
            return entries.sorted {
                ($0.song.duration ?? 0) < ($1.song.duration ?? 0)
            }
        }
    }
}
