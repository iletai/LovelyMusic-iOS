import AVFoundation
import Foundation
import os

extension Notification.Name {
    static let downloadsChanged = Notification.Name("downloadsChanged")
}

@MainActor
@Observable
final class DownloadManager {

    // MARK: - Types

    typealias StreamURLResolver =
        (String) async throws -> (url: String, contentLength: Int64?)

    enum DownloadState: Codable, Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed
        /// D2: download is waiting for a slot to open.
        case queued
    }

    struct DownloadedSong: Codable, Identifiable {
        var id: String { song.id }
        let song: Song
        let relativePath: String
        let downloadedAt: Date
        let fileSize: Int64
    }

    // MARK: - Published State

    private(set) var downloads: [String: DownloadState] = [:]
    private(set) var downloadedSongs: [DownloadedSong] = []

    // MARK: - Private

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let legacyMetadataKey = "downloaded_songs_metadata"
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// D2: Maximum concurrent downloads.
    private let maxConcurrentDownloads = 2
    /// D2: Pending download request (used in FIFO queue).
    private struct PendingDownload {
        let song: Song
        let resolver: StreamURLResolver
        let headers: [String: String]
    }

    /// D2: FIFO queue of pending download requests.
    /// Excluded from observation — UI doesn't need to track the queue internals.
    @ObservationIgnored
    private var pendingQueue: [PendingDownload] = []

    /// D1: Buffer size for streaming writes (64 KB).
    private let downloadBufferSize = 65_536

    /// Injected by DIContainer — used for the convenience `downloadSong(_:)` overload.
    var streamURLResolver: StreamURLResolver?
    /// Produces a resolver synchronously when the user queues a download. This
    /// freezes entitlement-capped explicit-download quality in `PendingDownload`.
    var streamURLResolverFactory: (() -> StreamURLResolver)?
    var streamHeaders: [String: String] = [:]

    private var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// D3: Application Support directory for metadata JSON file.
    private var metadataFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("com.lovelymusic.app", isDirectory: true)
        return dir.appendingPathComponent("downloads.json")
    }

    // MARK: - Init

    init() {
        createDirectoryIfNeeded()
        migrateMetadataIfNeeded()
        loadDownloadedSongs()
    }

    // MARK: - Public API

    /// Convenience method using the injected resolver/headers.
    func downloadSong(_ song: Song) {
        guard let resolver = streamURLResolverFactory?() ?? streamURLResolver else {
            Log.download.error("No streamURLResolver configured")
            return
        }
        downloadSong(song, streamURLResolver: resolver, streamHeaders: streamHeaders)
    }

    func downloadSong(
        _ song: Song,
        streamURLResolver: @escaping StreamURLResolver,
        streamHeaders: [String: String] = [:]
    ) {
        guard downloads[song.id] != .downloaded else { return }
        guard activeTasks[song.id] == nil else { return }
        // D2: Don't double-queue
        guard !pendingQueue.contains(where: { $0.song.id == song.id }) else { return }

        // D2: If at capacity, queue the request
        if activeTasks.count >= maxConcurrentDownloads {
            downloads[song.id] = .queued
            pendingQueue.append(PendingDownload(song: song, resolver: streamURLResolver, headers: streamHeaders))
            Log.download.info("Queued download: \(song.title, privacy: .public) (\(self.pendingQueue.count) pending)")
            return
        }

        startDownload(song: song, streamURLResolver: streamURLResolver, streamHeaders: streamHeaders)
    }

    func cancelDownload(songId: String) {
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        downloads[songId] = .notDownloaded

        // D2: Remove from pending queue if queued
        pendingQueue.removeAll { $0.song.id == songId }

        // D4: Clean up partial files
        cleanupPartialFiles(songId: songId)

        // D2: Start next queued download
        dequeueNext()
    }

    func removeDownload(songId: String) {
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)

        // D2: Remove from pending queue if queued
        pendingQueue.removeAll { $0.song.id == songId }

        if let index = downloadedSongs.firstIndex(where: { $0.song.id == songId }) {
            let fileURL = downloadsDirectory.appendingPathComponent(
                downloadedSongs[index].relativePath)
            try? FileManager.default.removeItem(at: fileURL)
            downloadedSongs.remove(at: index)
        }
        downloads.removeValue(forKey: songId)
        saveMetadata()
        NotificationCenter.default.post(name: .downloadsChanged, object: nil)

        // D2: Start next queued download
        dequeueNext()
    }

    func isDownloaded(songId: String) -> Bool {
        downloads[songId] == .downloaded
    }

    func localFileURL(songId: String) -> URL? {
        guard let entry = downloadedSongs.first(where: { $0.song.id == songId }) else {
            return nil
        }
        let url = downloadsDirectory.appendingPathComponent(entry.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // File was deleted externally — clean up metadata
            downloadedSongs.removeAll { $0.song.id == songId }
            downloads.removeValue(forKey: songId)
            saveMetadata()
            return nil
        }
        return url
    }

    func downloadState(for songId: String) -> DownloadState {
        downloads[songId] ?? .notDownloaded
    }

    func totalDownloadSize() -> Int64 {
        downloadedSongs.reduce(0) { $0 + $1.fileSize }
    }

    func formattedTotalSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalDownloadSize())
    }

    func reloadDownloads() {
        loadDownloadedSongs()
    }

    func clearAllDownloads() {
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        pendingQueue.removeAll()

        for entry in downloadedSongs {
            let url = downloadsDirectory.appendingPathComponent(entry.relativePath)
            try? FileManager.default.removeItem(at: url)
        }
        downloadedSongs.removeAll()
        downloads.removeAll()
        saveMetadata()
        NotificationCenter.default.post(name: .downloadsChanged, object: nil)
    }

    var downloadCount: Int {
        downloadedSongs.count
    }

    // MARK: - D2: Concurrency Control

    /// Start an actual download task (assumes a slot is available).
    private func startDownload(
        song: Song,
        streamURLResolver: @escaping StreamURLResolver,
        streamHeaders: [String: String]
    ) {
        downloads[song.id] = .downloading(progress: 0)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await streamURLResolver(song.id)
                guard let streamURL = URL(string: resolved.url) else {
                    self.handleDownloadEnd(songId: song.id, failed: true)
                    return
                }

                let headers =
                    streamHeaders.isEmpty ? AppConstants.youtubeStreamHeaders : streamHeaders

                // Add range parameter to bypass throttling
                var downloadURL = streamURL
                if var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) {
                    var items = components.queryItems ?? []
                    items.removeAll { $0.name == "range" }
                    items.append(URLQueryItem(name: "range", value: "0-"))
                    components.queryItems = items
                    if let newURL = components.url {
                        downloadURL = newURL
                    }
                }

                var request = URLRequest(url: downloadURL)
                request.timeoutInterval = 120
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                // D1: Download with streaming file write (no full-file heap buffer)
                let rawURL = try await self.downloadToFile(
                    request: request,
                    songId: song.id,
                    expectedLength: resolved.contentLength
                )

                guard !Task.isCancelled else {
                    self.cleanupPartialFiles(songId: song.id)
                    self.handleDownloadEnd(songId: song.id, failed: false, cancelled: true)
                    return
                }

                // Remux fMP4 → standard MP4 for seekable playback
                let filename = "\(song.id).m4a"
                let destinationURL = self.downloadsDirectory.appendingPathComponent(filename)
                let remuxSuccess = await self.remux(source: rawURL, destination: destinationURL)

                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: rawURL)
                    try? FileManager.default.removeItem(at: destinationURL)
                    self.handleDownloadEnd(songId: song.id, failed: false, cancelled: true)
                    return
                }

                let finalURL: URL
                if remuxSuccess {
                    // Remux succeeded — clean up raw file, use remuxed output
                    try? FileManager.default.removeItem(at: rawURL)
                    finalURL = destinationURL
                    Log.download.info("Successfully downloaded: \(song.title, privacy: .public)")
                } else {
                    // Remux failed — use raw file as fallback
                    if FileManager.default.fileExists(atPath: rawURL.path) {
                        // Remove any partial remux output, rename raw → destination
                        try? FileManager.default.removeItem(at: destinationURL)
                        do {
                            try FileManager.default.moveItem(at: rawURL, to: destinationURL)
                            finalURL = destinationURL
                            Log.download.warning(
                                "Saved (unremuxed) download: \(song.title, privacy: .public)")
                        } catch {
                            Log.download.error("Failed to move raw file as fallback: \(error.localizedDescription, privacy: .public)")
                            try? FileManager.default.removeItem(at: rawURL)
                            self.handleDownloadEnd(songId: song.id, failed: true)
                            return
                        }
                    } else {
                        Log.download.error("Remux failed and raw file missing for: \(song.title, privacy: .public)")
                        self.handleDownloadEnd(songId: song.id, failed: true)
                        return
                    }
                }

                let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
                let fileSize = (attrs?[.size] as? Int64) ?? 0

                // S3: flag for backup exclusion
                Self.setExcludedFromBackup(finalURL)

                let downloaded = DownloadedSong(
                    song: song,
                    relativePath: filename,
                    downloadedAt: Date(),
                    fileSize: fileSize
                )
                self.downloadedSongs.append(downloaded)
                self.downloads[song.id] = .downloaded
                self.saveMetadata()
                self.activeTasks.removeValue(forKey: song.id)
                NotificationCenter.default.post(name: .downloadsChanged, object: nil)

                // D2: Start next queued download
                self.dequeueNext()

            } catch {
                if !Task.isCancelled {
                    Log.download.error(
                        "Download failed for \(song.title, privacy: .public): \(error, privacy: .public)"
                    )
                    // D4: Clean up partial files on failure
                    self.cleanupPartialFiles(songId: song.id)
                    self.handleDownloadEnd(songId: song.id, failed: true)
                } else {
                    // D4: Clean up partial files on cancellation
                    self.cleanupPartialFiles(songId: song.id)
                    self.handleDownloadEnd(songId: song.id, failed: false, cancelled: true)
                }
            }
        }
        activeTasks[song.id] = task
    }

    /// D2: Pull the next pending request and start it if a slot is available.
    private func dequeueNext() {
        guard activeTasks.count < maxConcurrentDownloads, !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        startDownload(song: next.song, streamURLResolver: next.resolver, streamHeaders: next.headers)
    }

    /// Centralized cleanup when a download ends (success, failure, or cancel).
    private func handleDownloadEnd(songId: String, failed: Bool, cancelled: Bool = false) {
        activeTasks.removeValue(forKey: songId)
        if failed {
            downloads[songId] = .failed
        } else if cancelled {
            downloads[songId] = .notDownloaded
        }
        // D2: Always try to dequeue after a slot frees up
        dequeueNext()
    }

    // MARK: - D3: Persistence (JSON file in Application Support)

    private func saveMetadata() {
        do {
            let data = try Self.encoder.encode(downloadedSongs)
            try data.write(to: metadataFileURL, options: .atomic)
        } catch {
            Log.download.error("Failed to save metadata: \(error, privacy: .public)")
        }
    }

    private func loadDownloadedSongs() {
        guard FileManager.default.fileExists(atPath: metadataFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: metadataFileURL)
            let songs = try Self.decoder.decode([DownloadedSong].self, from: data)
            // Validate files still exist
            downloadedSongs = songs.filter { entry in
                let url = downloadsDirectory.appendingPathComponent(entry.relativePath)
                return FileManager.default.fileExists(atPath: url.path)
            }
            for song in downloadedSongs {
                downloads[song.song.id] = .downloaded
            }
            // Re-save if we pruned any missing files
            if downloadedSongs.count != songs.count {
                saveMetadata()
            }
        } catch {
            Log.download.error("Failed to load metadata: \(error, privacy: .public)")
            // D3: Tolerate malformed file — start with empty list
            downloadedSongs = []
        }
    }

    /// D3: One-shot migration from UserDefaults to JSON file.
    private func migrateMetadataIfNeeded() {
        guard let legacyData = UserDefaults.standard.data(forKey: legacyMetadataKey) else { return }

        // Only migrate if the new file doesn't already exist
        guard !FileManager.default.fileExists(atPath: metadataFileURL.path) else {
            // New file exists — just clean up the legacy key
            UserDefaults.standard.removeObject(forKey: legacyMetadataKey)
            Log.download.info("Legacy metadata key removed (new file already exists)")
            return
        }

        do {
            // Ensure the Application Support subdirectory exists
            let dir = metadataFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Validate we can decode the legacy data before writing
            // Legacy encoder didn't use iso8601, so decode with default strategy
            let legacyDecoder = JSONDecoder()
            let songs = try legacyDecoder.decode([DownloadedSong].self, from: legacyData)

            // Re-encode with the new encoder (iso8601 dates)
            let newData = try Self.encoder.encode(songs)
            try newData.write(to: metadataFileURL, options: .atomic)

            // Remove legacy key
            UserDefaults.standard.removeObject(forKey: legacyMetadataKey)
            Log.download.info("Migrated \(songs.count) entries from UserDefaults to JSON file")
        } catch {
            Log.download.error("Metadata migration failed: \(error, privacy: .public)")
            // Leave legacy data in place so we can retry next launch
        }
    }

    private func createDirectoryIfNeeded() {
        // Downloads directory
        try? FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )

        // D3: Application Support subdirectory for metadata
        let metadataDir = metadataFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: metadataDir,
            withIntermediateDirectories: true
        )

        // S3: Exclude the Downloads directory from iCloud / device backup.
        Self.setExcludedFromBackup(downloadsDirectory)

        // Walk existing files and apply the flag idempotently.
        if let files = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: nil)
        {
            for fileURL in files {
                Self.setExcludedFromBackup(fileURL)
            }
        }
    }

    /// Mark a file or directory as excluded from iCloud / device backup.
    /// Idempotent — re-applying on an already-flagged URL is a no-op.
    private static func setExcludedFromBackup(_ url: URL) {
        var url = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
    }

    // MARK: - D1: Streaming Download (FileHandle buffer, ~64KB heap cap)

    /// Downloads the response body to a temporary file using a 64 KB rotating buffer,
    /// avoiding full-file heap allocation. Returns the URL of the written raw file.
    private func downloadToFile(
        request: URLRequest,
        songId: String,
        expectedLength: Int64?
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        let totalBytes: Int64
        if let expected = expectedLength, expected > 0 {
            totalBytes = expected
        } else if let httpResponse = response as? HTTPURLResponse,
            let lengthStr = httpResponse.value(forHTTPHeaderField: "Content-Length"),
            let length = Int64(lengthStr), length > 0
        {
            totalBytes = length
        } else {
            totalBytes = 0
        }

        // Write to a .tmp file, then caller moves to final location
        let tempURL = downloadsDirectory.appendingPathComponent("\(songId)_raw.m4a")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? fileHandle.close() }

        var bytesWritten: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(downloadBufferSize)
        var lastProgressUpdate: Date = .distantPast

        for try await byte in bytes {
            buffer.append(byte)

            if buffer.count >= downloadBufferSize {
                fileHandle.write(buffer)
                bytesWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                // Throttle progress updates to ≥ 0.1 s
                if totalBytes > 0 {
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
                        let progress = min(Double(bytesWritten) / Double(totalBytes), 1.0)
                        downloads[songId] = .downloading(progress: progress)
                        lastProgressUpdate = now
                    }
                }
            }
        }

        // Flush remaining bytes
        if !buffer.isEmpty {
            fileHandle.write(buffer)
            bytesWritten += Int64(buffer.count)
        }

        if totalBytes > 0 {
            downloads[songId] = .downloading(progress: 1.0)
        }

        Log.download.debug("Streamed \(bytesWritten) bytes to disk for \(songId, privacy: .public)")
        return tempURL
    }

    // MARK: - D4: Partial File Cleanup

    /// Remove any temporary or partial files left by a failed/cancelled download.
    private func cleanupPartialFiles(songId: String) {
        let tmpFile = downloadsDirectory.appendingPathComponent("\(songId)_raw.m4a")
        let m4aFile = downloadsDirectory.appendingPathComponent("\(songId).m4a")

        if FileManager.default.fileExists(atPath: tmpFile.path) {
            try? FileManager.default.removeItem(at: tmpFile)
            Log.download.debug("Cleaned up partial raw file for \(songId, privacy: .public)")
        }
        // Only remove .m4a if this song isn't in the completed list
        if !downloadedSongs.contains(where: { $0.song.id == songId }),
           FileManager.default.fileExists(atPath: m4aFile.path) {
            try? FileManager.default.removeItem(at: m4aFile)
            Log.download.debug("Cleaned up partial m4a file for \(songId, privacy: .public)")
        }
    }

    // MARK: - Remux

    /// Remuxes fMP4 → standard MP4 with populated stbl for seekable playback.
    /// Uses modern async AVFoundation APIs (load(.formatDescriptions), finishWriting async).
    private func remux(source: URL, destination: URL) async -> Bool {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let reader = try? AVAssetReader(asset: asset),
            let writer = try? AVAssetWriter(url: destination, fileType: .m4a)
        else { return false }

        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            Log.download.error("Remux: no audio track found")
            return false
        }

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        guard let formatDesc = try? await audioTrack.load(.formatDescriptions).first else {
            return false
        }

        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: formatDesc
        )
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.lovelymusic.download-remux")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        guard reader.status == .completed else { return false }
        await writer.finishWriting()
        return writer.status == .completed
    }
}
