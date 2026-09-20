import Foundation

/// Decorator that wraps `InnerTubeRepository` with in-memory caching and
/// in-flight request deduplication.
/// - `@unchecked Sendable` is safe because all mutable state lives in the
///   `ContentCache` actor; this class holds only `let` properties.
final class CachedInnerTubeRepository: InnerTubeRepositoryProtocol, @unchecked Sendable {
    private let wrapped: InnerTubeRepositoryProtocol
    private let cache: ContentCache

    init(wrapped: InnerTubeRepositoryProtocol, cache: ContentCache = ContentCache()) {
        self.wrapped = wrapped
        self.cache = cache
    }

    func invalidateAll() async {
        await cache.invalidateAll()
    }

    func invalidateHome() async {
        await cache.invalidateHome()
    }

    // MARK: - Foreground staleness (polish-B4)

    /// Records the latest active scene-phase transition on the underlying cache.
    func touchForeground() async {
        await cache.touchForeground()
    }

    /// True when the cache's last-foreground timestamp is older than the
    /// staleness threshold. False on first launch.
    var isStale: Bool {
        get async { await cache.isStale }
    }

    func search(query: String, filter: SearchFilter?) async throws -> SearchResult {
        try await wrapped.search(query: query, filter: filter)
    }

    func searchContinuation(token: String) async throws -> SearchResult {
        try await wrapped.searchContinuation(token: token)
    }

    func searchSuggestions(query: String) async throws -> [String] {
        try await wrapped.searchSuggestions(query: query)
    }

    func getStreamingData(videoId: String) async throws -> StreamingData {
        try await wrapped.getStreamingData(videoId: videoId)
    }

    func browseHome(params: String?) async throws -> HomeResult {
        if params == nil, let cached = await cache.getHome() {
            return cached
        }
        let result = try await wrapped.browseHome(params: params)
        if params == nil {
            await cache.setHome(result)
        }
        return result
    }

    func getArtist(browseId: String) async throws -> ArtistResult {
        if let cached = await cache.getArtist(browseId) {
            return cached
        }
        if let inflight = await cache.inflightArtist(browseId) {
            return try await inflight.value
        }
        let task = Task {
            try await wrapped.getArtist(browseId: browseId)
        }
        await cache.setInflightArtist(browseId, task)
        do {
            let result = try await task.value
            await cache.setArtist(browseId, result)
            return result
        } catch {
            await cache.removeInflightArtist(browseId)
            throw error
        }
    }

    func getAlbum(browseId: String) async throws -> AlbumResult {
        if let cached = await cache.getAlbum(browseId) {
            return cached
        }
        if let inflight = await cache.inflightAlbum(browseId) {
            return try await inflight.value
        }
        let task = Task {
            try await wrapped.getAlbum(browseId: browseId)
        }
        await cache.setInflightAlbum(browseId, task)
        do {
            let result = try await task.value
            await cache.setAlbum(browseId, result)
            return result
        } catch {
            await cache.removeInflightAlbum(browseId)
            throw error
        }
    }

    func browseContinuation(token: String) async throws -> Data {
        try await wrapped.browseContinuation(token: token)
    }

    func browseHomeContinuation(token: String) async throws -> HomeResult {
        try await wrapped.browseHomeContinuation(token: token)
    }

    func browseShelfContinuation(token: String) async throws -> (
        songs: [Song], continuation: String?
    ) {
        try await wrapped.browseShelfContinuation(token: token)
    }

    func getPlaylist(playlistId: String) async throws -> PlaylistResult {
        if let cached = await cache.getPlaylist(playlistId) {
            return cached
        }
        if let inflight = await cache.inflightPlaylist(playlistId) {
            return try await inflight.value
        }
        let task = Task {
            try await wrapped.getPlaylist(playlistId: playlistId)
        }
        await cache.setInflightPlaylist(playlistId, task)
        do {
            let result = try await task.value
            await cache.setPlaylist(playlistId, result)
            return result
        } catch {
            await cache.removeInflightPlaylist(playlistId)
            throw error
        }
    }

    func getNext(videoId: String?, playlistId: String?) async throws -> [Song] {
        try await wrapped.getNext(videoId: videoId, playlistId: playlistId)
    }
}
