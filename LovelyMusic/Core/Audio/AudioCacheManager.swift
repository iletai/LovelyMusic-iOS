import Foundation
import UIKit
import os

final class AudioCacheManager: @unchecked Sendable {

    // MARK: - Types

    private struct CacheEntry {
        let videoId: String
        let fileURL: URL
        let fileSize: Int64
        var lastAccessDate: Date
    }

    private struct State {
        var entries: [String: CacheEntry] = [:]
    }

    // MARK: - Properties

    let maxCacheSize: Int64
    private let state: OSAllocatedUnfairLock<State>
    private let cacheDirectory: URL
    private var memoryWarningObserver: Any?

    // MARK: - Init

    init(maxCacheSize: Int64 = 200 * 1024 * 1024) {
        self.maxCacheSize = maxCacheSize
        self.cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LovelyMusic", isDirectory: true)
        self.state = OSAllocatedUnfairLock(initialState: State())

        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        // S3: Exclude cache directory from iCloud / device backup.
        // tmp/ is excluded by default but the flag is idempotent and cheap.
        Self.setExcludedFromBackup(cacheDirectory)

        rebuildEntriesFromDisk()

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleMemoryPressure()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func getFile(for videoId: String) -> URL? {
        state.withLock { state in
            guard var entry = state.entries[videoId] else { return nil }

            guard FileManager.default.fileExists(atPath: entry.fileURL.path) else {
                state.entries.removeValue(forKey: videoId)
                return nil
            }

            entry.lastAccessDate = Date()
            state.entries[videoId] = entry
            return entry.fileURL
        }
    }

    func registerFile(videoId: String, fileURL: URL) {
        state.withLock { state in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                let fileSize = attrs[.size] as? Int64
            else {
                return
            }

            state.entries[videoId] = CacheEntry(
                videoId: videoId,
                fileURL: fileURL,
                fileSize: fileSize,
                lastAccessDate: Date()
            )

            evictIfNeeded(&state)
        }
    }

    /// Reserve a slot for a file that is about to be written to `fileURL`.
    /// Use this immediately before a `moveItem` (or remux write) into
    /// `cacheDirectory` to close the race where `removeOrphans` could delete
    /// the file in the brief window between the move/write and `registerFile`.
    /// The subsequent `registerFile` call unconditionally overwrites this
    /// placeholder entry with the real file size.
    func reserveSlot(videoId: String, fileURL: URL) {
        state.withLock { state in
            state.entries[videoId] = CacheEntry(
                videoId: videoId,
                fileURL: fileURL,
                fileSize: 0,
                lastAccessDate: Date()
            )
        }
    }

    var totalSize: Int64 {
        state.withLock { state in
            state.entries.values.reduce(0) { $0 + $1.fileSize }
        }
    }

    var fileCount: Int {
        state.withLock { $0.entries.count }
    }

    func clearAll() {
        state.withLock { state in
            for entry in state.entries.values {
                try? FileManager.default.removeItem(at: entry.fileURL)
            }
            state.entries.removeAll()
            Log.audioCache.info("Cleared all cached files")
        }
    }

    /// Public LRU trim entrypoint. Evicts least-recently-used files until the
    /// total cached size is within `maxCacheSize`. Safe to call from any actor
    /// context (state is guarded by `OSAllocatedUnfairLock`).
    func trimToFit() {
        state.withLock { state in
            evictIfNeeded(&state)
        }
    }

    /// Sweep stale and orphaned cache entries.
    /// - Removes any cache entry whose `videoId` is also present in
    ///   `knownDownloadIds` (a downloaded copy supersedes the cached remux).
    /// - Removes any on-disk file under `cacheDirectory` that is not tracked
    ///   in `state.entries` (orphans from crashes / aborted remuxes).
    func removeOrphans(knownDownloadIds: Set<String>) {
        state.withLock { state in
            // Pass 1: drop entries superseded by a downloaded copy.
            var supersededFreed: Int64 = 0
            for (videoId, entry) in state.entries where knownDownloadIds.contains(videoId) {
                try? FileManager.default.removeItem(at: entry.fileURL)
                supersededFreed += entry.fileSize
                state.entries.removeValue(forKey: videoId)
            }
            if supersededFreed > 0 {
                Log.audioCache.info(
                    "Removed superseded cache entries, freed \(supersededFreed) bytes")
            }

            // Pass 2: remove only orphan *_remuxed.m4a files not tracked in
            // state.entries. *_raw.m4a files are owned by `AudioEngine` (the
            // streaming-while-downloading path writes them and AVPlayer may be
            // actively reading) — leave them alone. Mirrors the suffix filter
            // in `rebuildEntriesFromDisk`.
            let suffix = "_remuxed.m4a"
            let trackedPaths = Set(state.entries.values.map { $0.fileURL.standardizedFileURL.path })
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: cacheDirectory,
                    includingPropertiesForKeys: nil
                )
            else { return }

            var orphansRemoved = 0
            for fileURL in files where fileURL.lastPathComponent.hasSuffix(suffix) {
                let path = fileURL.standardizedFileURL.path
                if !trackedPaths.contains(path) {
                    try? FileManager.default.removeItem(at: fileURL)
                    orphansRemoved += 1
                }
            }
            if orphansRemoved > 0 {
                Log.audioCache.info("Removed \(orphansRemoved) orphan cache files")
            }
        }
    }

    func formattedTotalSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: totalSize)
    }

    // MARK: - Private

    private func rebuildEntriesFromDisk() {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )
        else { return }

        let suffix = "_remuxed.m4a"

        state.withLock { state in
            for fileURL in files {
                let name = fileURL.lastPathComponent
                guard name.hasSuffix(suffix) else { continue }

                let videoId = String(name.dropLast(suffix.count))
                guard !videoId.isEmpty else { continue }

                guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                    let fileSize = attrs[.size] as? Int64,
                    let modDate = attrs[.modificationDate] as? Date
                else {
                    continue
                }

                state.entries[videoId] = CacheEntry(
                    videoId: videoId,
                    fileURL: fileURL,
                    fileSize: fileSize,
                    lastAccessDate: modDate
                )

                // S3: Mark the rebuilt file as excluded from backup
                // (idempotent — re-applying is a no-op).
                Self.setExcludedFromBackup(fileURL)
            }
        }
    }

    /// Evict least-recently-used files until total size is within limit.
    /// Must be called from within a `state.withLock` closure.
    private func evictIfNeeded(_ state: inout State) {
        var currentTotal = state.entries.values.reduce(0) { $0 + $1.fileSize }

        while currentTotal > maxCacheSize, !state.entries.isEmpty {
            guard
                let victim = state.entries.values.min(by: { $0.lastAccessDate < $1.lastAccessDate })
            else {
                break
            }

            try? FileManager.default.removeItem(at: victim.fileURL)
            state.entries.removeValue(forKey: victim.videoId)
            currentTotal -= victim.fileSize
            Log.audioCache.info(
                "Evicted \(victim.videoId, privacy: .public), freed \(victim.fileSize) bytes")
        }
    }

    /// Respond to system memory pressure by evicting to 50% capacity.
    private func handleMemoryPressure() {
        state.withLock { state in
            let targetSize = maxCacheSize / 2
            var currentTotal = state.entries.values.reduce(0) { $0 + $1.fileSize }
            let sorted = state.entries.values.sorted { $0.lastAccessDate < $1.lastAccessDate }
            for entry in sorted {
                guard currentTotal > targetSize else { break }
                try? FileManager.default.removeItem(at: entry.fileURL)
                currentTotal -= entry.fileSize
                state.entries.removeValue(forKey: entry.videoId)
            }
            Log.audioCache.warning("Memory pressure: evicted to \(currentTotal / (1024 * 1024))MB")
        }
    }

    /// Mark a file or directory as excluded from iCloud / device backup.
    /// Idempotent — re-applying on an already-flagged URL is a no-op.
    fileprivate static func setExcludedFromBackup(_ url: URL) {
        var url = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
    }
}
