import Foundation

/// Thread-safe in-memory cache with TTL and LRU eviction for InnerTube API responses.
/// Supports in-flight request deduplication to prevent duplicate network calls.
actor ContentCache {
    private struct Entry<T> {
        let value: T
        let timestamp: Date
    }

    private var artists: [String: Entry<ArtistResult>] = [:]
    private var albums: [String: Entry<AlbumResult>] = [:]
    private var playlists: [String: Entry<PlaylistResult>] = [:]
    private var home: Entry<HomeResult>?

    // In-flight request deduplication
    private var inflightArtists: [String: Task<ArtistResult, Error>] = [:]
    private var inflightAlbums: [String: Task<AlbumResult, Error>] = [:]
    private var inflightPlaylists: [String: Task<PlaylistResult, Error>] = [:]

    private let ttl: TimeInterval
    private let maxEntriesPerType: Int

    /// Time the app most recently transitioned to `.active` scene phase.
    /// `nil` until the first foregrounding (e.g. cold launch). Used by
    /// `LovelyMusicApp` to decide whether to invalidate the home cache when
    /// the user returns from a long background pause (polish-B4).
    private(set) var lastForegroundedAt: Date?

    /// Threshold beyond which a foreground transition is considered stale and
    /// the home cache should be refetched. 15 min per polish-B4 acceptance.
    private let foregroundStaleThreshold: TimeInterval = 15 * 60

    /// Clock seam for deterministic tests. Production callers use `Date.init`.
    private let now: @Sendable () -> Date

    init(
        ttl: TimeInterval = 300,
        maxEntriesPerType: Int = 50,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.ttl = ttl
        self.maxEntriesPerType = maxEntriesPerType
        self.now = now
    }

    // MARK: - Foreground staleness (polish-B4)

    /// Records that the app has just transitioned to the active scene phase.
    /// Always called on `.active` regardless of staleness; resets the clock.
    func touchForeground() {
        lastForegroundedAt = now()
    }

    /// True when the gap between the previous foregrounding and `now` exceeds
    /// `foregroundStaleThreshold`. Returns false on first launch
    /// (`lastForegroundedAt == nil`) so the app does not invalidate before any
    /// content has been loaded.
    var isStale: Bool {
        guard let last = lastForegroundedAt else { return false }
        return now().timeIntervalSince(last) > foregroundStaleThreshold
    }

    private func isValid(_ timestamp: Date) -> Bool {
        now().timeIntervalSince(timestamp) < ttl
    }

    /// Evicts expired entries and oldest entries beyond limit from a dictionary.
    private func evicted<T>(_ dict: inout [String: Entry<T>]) {
        dict = dict.filter { isValid($0.value.timestamp) }
        if dict.count > maxEntriesPerType {
            let sorted = dict.sorted { $0.value.timestamp < $1.value.timestamp }
            let toRemove = sorted.prefix(dict.count - maxEntriesPerType)
            for (key, _) in toRemove { dict.removeValue(forKey: key) }
        }
    }

    // MARK: - Artist

    func getArtist(_ browseId: String) -> ArtistResult? {
        guard let entry = artists[browseId], isValid(entry.timestamp) else { return nil }
        return entry.value
    }

    func setArtist(_ browseId: String, _ value: ArtistResult) {
        artists[browseId] = Entry(value: value, timestamp: Date())
        inflightArtists.removeValue(forKey: browseId)
        evicted(&artists)
    }

    func inflightArtist(_ browseId: String) -> Task<ArtistResult, Error>? {
        inflightArtists[browseId]
    }

    func setInflightArtist(_ browseId: String, _ task: Task<ArtistResult, Error>) {
        inflightArtists[browseId] = task
    }

    func removeInflightArtist(_ browseId: String) {
        inflightArtists.removeValue(forKey: browseId)
    }

    // MARK: - Album

    func getAlbum(_ browseId: String) -> AlbumResult? {
        guard let entry = albums[browseId], isValid(entry.timestamp) else { return nil }
        return entry.value
    }

    func setAlbum(_ browseId: String, _ value: AlbumResult) {
        albums[browseId] = Entry(value: value, timestamp: Date())
        inflightAlbums.removeValue(forKey: browseId)
        evicted(&albums)
    }

    func inflightAlbum(_ browseId: String) -> Task<AlbumResult, Error>? {
        inflightAlbums[browseId]
    }

    func setInflightAlbum(_ browseId: String, _ task: Task<AlbumResult, Error>) {
        inflightAlbums[browseId] = task
    }

    func removeInflightAlbum(_ browseId: String) {
        inflightAlbums.removeValue(forKey: browseId)
    }

    // MARK: - Playlist

    func getPlaylist(_ playlistId: String) -> PlaylistResult? {
        guard let entry = playlists[playlistId], isValid(entry.timestamp) else { return nil }
        return entry.value
    }

    func setPlaylist(_ playlistId: String, _ value: PlaylistResult) {
        playlists[playlistId] = Entry(value: value, timestamp: Date())
        inflightPlaylists.removeValue(forKey: playlistId)
        evicted(&playlists)
    }

    func inflightPlaylist(_ playlistId: String) -> Task<PlaylistResult, Error>? {
        inflightPlaylists[playlistId]
    }

    func setInflightPlaylist(_ playlistId: String, _ task: Task<PlaylistResult, Error>) {
        inflightPlaylists[playlistId] = task
    }

    func removeInflightPlaylist(_ playlistId: String) {
        inflightPlaylists.removeValue(forKey: playlistId)
    }

    // MARK: - Home

    func getHome() -> HomeResult? {
        guard let entry = home, isValid(entry.timestamp) else { return nil }
        return entry.value
    }

    func setHome(_ value: HomeResult) {
        home = Entry(value: value, timestamp: Date())
    }

    func invalidateHome() {
        home = nil
    }

    // MARK: - Invalidation

    func invalidate(_ browseId: String) {
        artists.removeValue(forKey: browseId)
        albums.removeValue(forKey: browseId)
        playlists.removeValue(forKey: browseId)
    }

    func invalidateAll() {
        artists.removeAll()
        albums.removeAll()
        playlists.removeAll()
        home = nil
        inflightArtists.values.forEach { $0.cancel() }
        inflightAlbums.values.forEach { $0.cancel() }
        inflightPlaylists.values.forEach { $0.cancel() }
        inflightArtists.removeAll()
        inflightAlbums.removeAll()
        inflightPlaylists.removeAll()
    }
}
