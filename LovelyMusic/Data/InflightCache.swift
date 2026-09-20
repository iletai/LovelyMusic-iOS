import Foundation

// MARK: - InflightCache

/// Generic single-flight cache: coalesces concurrent callers for the same `Key`
/// onto a single underlying `Task`, then evicts the entry on completion (success
/// OR failure) so the next caller triggers a fresh underlying call.
///
/// ## Cancellation contract
///
/// The underlying work runs in a `Task.detached` so an individual caller's
/// cancellation does NOT propagate into the shared task. Peers awaiting the
/// same key continue to receive the value. The detached task only completes
/// when `make` itself returns or throws.
///
/// ## Eviction
///
/// Eviction happens via `defer` inside the actor-isolated `run` method, so it
/// is synchronous from the actor's perspective: no other caller can observe a
/// stale entry between `task.value` returning and the entry being removed.
/// Namespace for the reentrancy `@TaskLocal`. Cannot live on
/// `InflightCache` itself because Swift 5.9 disallows static stored
/// properties on generic types. Keys are type-erased to `AnyHashable`
/// and scoped per-cache via `ObjectIdentifier` so recursion detection
/// is isolated to a single cache instance.
private enum InflightReentry {
    struct Key: Hashable {
        let instance: ObjectIdentifier
        let key: AnyHashable
    }
    @TaskLocal static var activeKeys: Set<Key> = []
}

/// Internal observability seam used by deterministic concurrency tests. The
/// callback is synchronous, nonthrowing, and defaults to `nil`, so production
/// cache behavior has no extra suspension point or logging.
typealias InflightJoinObserver = @Sendable () -> Void

actor InflightCache<Key: Hashable & Sendable, Value: Sendable> {
    private var tasks: [Key: Task<Value, Error>] = [:]
    private let didJoin: InflightJoinObserver?

    init(didJoin: InflightJoinObserver? = nil) {
        self.didJoin = didJoin
    }

    /// Number of currently-running underlying tasks. Test-only observability.
    var inflightCount: Int { tasks.count }

    /// Returns the value for `key`. Concurrent callers for the same `key` share
    /// one underlying `Task`; the entry is removed on completion or failure.
    ///
    /// ## Reentrancy invariant
    ///
    /// `make` MUST NOT re-enter `run(...)` on the same `key` of the same
    /// cache instance. Doing so would cause the recursive caller to await
    /// the task that is itself waiting for `make` to finish — a self-await
    /// deadlock. Same-key recursion is detected via a `@TaskLocal` and
    /// rejected with `InflightCacheError.recursiveReentry`.
    func run(
        _ key: Key,
        _ make: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        let reentryKey = InflightReentry.Key(
            instance: ObjectIdentifier(self),
            key: AnyHashable(key)
        )
        if InflightReentry.activeKeys.contains(reentryKey) {
            throw InflightCacheError.recursiveReentry
        }
        if let existing = tasks[key] {
            didJoin?()
            return try await existing.value
        }
        let parentKeys = InflightReentry.activeKeys
        let task = Task<Value, Error>.detached {
            try await InflightReentry.$activeKeys.withValue(
                parentKeys.union([reentryKey])
            ) {
                try await make()
            }
        }
        tasks[key] = task
        didJoin?()
        defer { tasks.removeValue(forKey: key) }
        return try await task.value
    }
}

/// Errors thrown by `InflightCache`.
enum InflightCacheError: Error {
    /// `make` re-entered `run(...)` on the same key, which would deadlock.
    case recursiveReentry
}

// MARK: - PlayerAPIClient

/// Minimal API surface that `PlayerRepository` requires from the InnerTube
/// client. Carved out as a protocol so tests can substitute a mock without
/// dragging in the full `InnerTubeAPI` actor (URLSession, cookie store,
/// visitor data, etc.).
///
/// Conformance is provided for the production `InnerTubeAPI` actor via an
/// extension below.
protocol PlayerAPIClient: Sendable {
    func playerWithSession(videoId: String, playlistId: String?) async throws -> Data
    func player(client: YouTubeClient, videoId: String, playlistId: String?) async throws -> Data
    func playerWithVisionOS(videoId: String) async throws -> Data
    func resetSession() async
}

extension PlayerAPIClient {
    /// Convenience overload matching the historic call sites that omitted
    /// `playlistId`. Default arguments are not part of the protocol
    /// requirement, so we restore them via a protocol extension.
    func playerWithSession(videoId: String) async throws -> Data {
        try await playerWithSession(videoId: videoId, playlistId: nil)
    }

    func player(client: YouTubeClient, videoId: String) async throws -> Data {
        try await player(client: client, videoId: videoId, playlistId: nil)
    }
}

extension InnerTubeAPI: PlayerAPIClient {}
