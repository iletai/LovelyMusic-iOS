import Foundation
import os

final class PlayerRepository: PlayerRepositoryProtocol, @unchecked Sendable {
    private let api: PlayerAPIClient
    private let decoder = JSONDecoder()
    private let videoQualityProvider: @Sendable () -> VideoQuality

    /// Single-flight caches: concurrent callers asking for the same `videoId`
    /// share one underlying `InnerTubeAPI` round-trip. Audio is keyed by id and
    /// effective quality; video remains keyed by id. The separate caches keep a
    /// stuck video resolve from blocking audio for the same id.
    private struct AudioInflightKey: Hashable, Sendable {
        let videoID: String
        let quality: AudioQuality
    }

    private let audioInflight: InflightCache<AudioInflightKey, StreamDescriptor>
    private let videoInflight: InflightCache<
        String,
        (url: String, contentLength: Int64?)?
    >

    private static let maxAttempts = 3
    private static let backoffDelaysMs: [UInt64] = [0, 500, 1500]

    /// Internal sentinel: server explicitly declared the video unplayable
    /// (e.g., region-blocked, removed, private). Retrying the same client is
    /// pointless — caller should skip to next client immediately.
    private struct PlayabilityFailure: Error {
        let reason: String
    }

    init(
        api: PlayerAPIClient,
        videoQualityProvider: @escaping @Sendable () -> VideoQuality = { .auto },
        audioInflightDidJoin: InflightJoinObserver? = nil,
        videoInflightDidJoin: InflightJoinObserver? = nil
    ) {
        self.api = api
        self.videoQualityProvider = videoQualityProvider
        audioInflight = InflightCache(didJoin: audioInflightDidJoin)
        videoInflight = InflightCache(didJoin: videoInflightDidJoin)
    }

    @available(
        *,
        deprecated,
        message: "Use resolveStreamDescriptor(videoId:quality:requestHeaders:)"
    )
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        do {
            let descriptor = try await resolveStreamDescriptor(
                videoId: videoId,
                quality: .medium,
                requestHeaders: [:]
            )
            return (descriptor.remoteURL.absoluteString, descriptor.contentLength)
        } catch is StreamDescriptorError {
            // Preserve the legacy tuple contract for DownloadManager callers.
            // Typed validation errors remain available through the descriptor API.
            throw InnerTubeError.noStreamAvailable
        }
    }

    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        let key = AudioInflightKey(videoID: videoId, quality: quality)
        let base = try await audioInflight.run(key) { [self] in
            try await resolveStreamDescriptorUncached(videoId: videoId, quality: quality)
        }
        return base.withRequestHeaders(requestHeaders)
    }

    private func resolveStreamDescriptorUncached(
        videoId: String,
        quality: AudioQuality
    ) async throws -> StreamDescriptor {
        let cpn = generateCPN()
        return try await withTimeout(seconds: 45) { [self] in
            // Client fallback chain: VISIONOS → ANDROID_VR(session/IOS) → IOS → WEB_REMIX
            // VISIONOS (ID 101) is preferred: returns hlsManifestUrl with no byte-range limit.
            // ANDROID_VR label kept for logging; actual client is IOS per playerWithSession().
            var lastPlayabilityReason: String?
            var lastDescriptorError: StreamDescriptorError?

            // Priority 0: VISIONOS — returns HLS manifest for full-song streaming
            if let hlsDesc = try? await extractHLSDescriptor(videoId: videoId) {
                Log.player.info("[VISIONOS] HLS stream resolved for \(videoId, privacy: .public)")
                return hlsDesc
            }

            // Primary: ANDROID_VR with session cookies
            if let result = try await attemptClientWithRetries(
                label: "ANDROID_VR(session)", videoId: videoId, cpn: cpn, useSession: true,
                quality: quality,
                playabilityReason: &lastPlayabilityReason,
                descriptorError: &lastDescriptorError
            ) {
                return result
            }

            // Reset session before trying fallback clients
            Log.player.info("Primary client failed, resetting session for fallback chain")
            await api.resetSession()

            // Fallback 1: IOS client
            if let result = try await attemptClientWithRetries(
                label: "IOS", videoId: videoId, cpn: cpn, client: .ios,
                quality: quality,
                playabilityReason: &lastPlayabilityReason,
                descriptorError: &lastDescriptorError
            ) {
                return result
            }

            // Fallback 2: WEB_REMIX client
            if let result = try await attemptClientWithRetries(
                label: "WEB_REMIX", videoId: videoId, cpn: cpn, client: .webRemix,
                quality: quality,
                playabilityReason: &lastPlayabilityReason,
                descriptorError: &lastDescriptorError
            ) {
                return result
            }

            Log.player.error("All player clients exhausted")
            #if DEBUG
            print("🔴 [PlayerRepo] All clients exhausted — playabilityReason=\(lastPlayabilityReason ?? "nil") descriptorError=\(String(describing: lastDescriptorError))")
            #endif
            // If at least one client gave us a definitive playability failure,
            // treat the video as permanently unavailable. Otherwise it was a
            // transient network failure and a future retry might succeed.
            if let reason = lastPlayabilityReason {
                throw InnerTubeError.videoUnavailable(reason: reason)
            }
            if let lastDescriptorError {
                throw lastDescriptorError
            }
            throw InnerTubeError.noStreamAvailable
        }
    }

    /// Attempts to resolve a stream URL using a specific client with retry logic.
    /// Returns the result on success, or `nil` if this client should be skipped
    /// (allowing the caller to try the next client in the fallback chain).
    /// `playabilityReason` is set when the server explicitly declared the
    /// video unplayable — this short-circuits same-client retries (the result
    /// will not change) and lets the top-level resolver throw a permanent error.
    private func attemptClientWithRetries(
        label: String,
        videoId: String,
        cpn: String,
        useSession: Bool = false,
        client: YouTubeClient? = nil,
        quality: AudioQuality,
        playabilityReason: inout String?,
        descriptorError: inout StreamDescriptorError?
    ) async throws -> StreamDescriptor? {
        for attempt in 0..<Self.maxAttempts {
            if attempt > 0 {
                let delayMs = Self.backoffDelaysMs[attempt]
                Log.player.debug(
                    "[\(label, privacy: .public)] Backoff: waiting \(delayMs)ms before attempt \(attempt + 1)"
                )
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }

            do {
                let result: StreamDescriptor?
                if useSession {
                    result = try await attemptPlayerWithSession(
                        videoId: videoId,
                        cpn: cpn,
                        quality: quality
                    )
                } else if let client {
                    result = try await attemptPlayer(
                        client: client,
                        videoId: videoId,
                        cpn: cpn,
                        quality: quality
                    )
                } else {
                    return nil
                }
                if let result {
                    Log.player.info(
                        "[\(label, privacy: .public)] Stream resolved on attempt \(attempt + 1)")
                    return result
                }
            } catch let failure as PlayabilityFailure {
                // Server explicitly said "unplayable" — skip remaining attempts
                // for this client; same response would repeat. Propagate the
                // reason so the top-level resolver can throw videoUnavailable
                // when every client agrees.
                playabilityReason = failure.reason
                Log.player.warning(
                    "[\(label, privacy: .public)] Playability not OK: \(failure.reason, privacy: .public) — skipping to next client"
                )
                return nil
            } catch let error as StreamDescriptorError {
                descriptorError = error
                Log.player.warning(
                    "[\(label, privacy: .public)] Descriptor validation failed on attempt \(attempt + 1)"
                )
            } catch let error as InnerTubeError {
                if case .httpError(let code) = error {
                    if code == 429 {
                        Log.player.warning(
                            "[\(label, privacy: .public)] Rate limited (429), retrying with backoff"
                        )
                        continue
                    }
                    if code == 403 {
                        Log.player.warning(
                            "[\(label, privacy: .public)] Forbidden (403), skipping to next client")
                        return nil
                    }
                }
                Log.player.warning(
                    "[\(label, privacy: .public)] Attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)"
                )
                #if DEBUG
                print("⚠️ [PlayerRepo] [\(label)] attempt \(attempt+1) InnerTubeError: \(error)")
                #endif
            } catch {
                Log.player.warning(
                    "[\(label, privacy: .public)] Attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)"
                )
                #if DEBUG
                print("⚠️ [PlayerRepo] [\(label)] attempt \(attempt+1) error \(type(of: error)): \(error)")
                #endif
            }
        }

        Log.player.warning(
            "[\(label, privacy: .public)] All \(Self.maxAttempts) attempts exhausted")
        return nil
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T)
        async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw InnerTubeError.timeout
            }
            let result = try await group.next() ?? { throw InnerTubeError.timeout }()
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private

    private func attemptPlayerWithSession(
        videoId: String,
        cpn: String,
        quality: AudioQuality
    ) async throws -> StreamDescriptor? {
        let data = try await api.playerWithSession(videoId: videoId)
        return try extractStreamDescriptor(
            from: data,
            label: "ANDROID_VR(session)",
            videoId: videoId,
            quality: quality
        )
    }

    private func attemptPlayer(
        client: YouTubeClient,
        videoId: String,
        cpn: String,
        quality: AudioQuality
    ) async throws -> StreamDescriptor? {
        Log.player.info("Trying fallback client: \(client.clientName, privacy: .public)")
        let data = try await api.player(client: client, videoId: videoId)
        return try extractStreamDescriptor(
            from: data,
            label: client.clientName,
            videoId: videoId,
            quality: quality
        )
    }

    func resolveVideoStreamURL(videoId: String) async throws -> (
        url: String, contentLength: Int64?
    )? {
        try await videoInflight.run(videoId) { [self] in
            // ANDROID_VR blocked since Aug 2026. Use VISIONOS hlsManifestUrl —
            // the HLS variant manifest contains both audio and video tracks;
            // VideoPlaybackManager mutes via isMuted=true so no double-audio.
            let data = try await api.playerWithVisionOS(videoId: videoId)
            guard let response = try? decoder.decode(PlayerResponse.self, from: data),
                  response.playabilityStatus?.status == "OK",
                  let hlsURL = response.streamingData?.hlsManifestUrl
            else {
                return nil
            }
            Log.player.info("[VISIONOS] Video HLS resolved for \(videoId, privacy: .public)")
            return (url: hlsURL, contentLength: nil)
        }
    }

    /// Decodes player response and extracts the best audio URL.
    /// Returns `nil` if no compatible audio format was found (transient — try next client).
    /// Throws `PlayabilityFailure` if the server marked the video unplayable
    /// (permanent — caller skips remaining attempts on the same client).
    /// Throws on decode/HTTP errors.
    private func extractStreamDescriptor(
        from data: Data,
        label: String,
        videoId: String,
        quality: AudioQuality
    ) throws -> StreamDescriptor? {
        let response = try decoder.decode(PlayerResponse.self, from: data)

        guard response.playabilityStatus?.status == "OK" else {
            throw PlayabilityFailure(reason: response.playabilityStatus?.reason ?? "Unknown")
        }

        let streamingData = StreamingDataMapper.map(response.streamingData)
        guard let bestFormat = streamingData.bestAudioFormat(
            quality: quality,
            candidateIsPlayable: { format in
                (try? StreamDescriptorResolver.resolve(
                    videoID: videoId,
                    format: format,
                    expiresAt: streamingData.expiresAt,
                    requestHeaders: [:]
                )) != nil
            }
        ) else {
            let availableMimes =
                (response.streamingData?.adaptiveFormats?.compactMap { $0.mimeType } ?? [])
                .description
            Log.player.warning(
                "[\(label, privacy: .public)] No compatible audio format. Available: \(availableMimes, privacy: .public)"
            )
            return nil
        }

        Log.player.info(
            "[\(label, privacy: .public)] Selected: itag=\(bestFormat.itag) mime=\(bestFormat.mimeType, privacy: .public) bitrate=\(bestFormat.bitrate ?? 0)"
        )
        return try StreamDescriptorResolver.resolve(
            videoID: videoId,
            format: bestFormat,
            expiresAt: streamingData.expiresAt,
            requestHeaders: [:]
        )
    }

    private func extractVideoStreamURL(from data: Data, label: String, videoId: String) throws -> (
        url: String, contentLength: Int64?
    )? {
        let response = try decoder.decode(PlayerResponse.self, from: data)
        guard response.playabilityStatus?.status == "OK" else { return nil }
        let streamingData = StreamingDataMapper.map(response.streamingData)
        let quality = videoQualityProvider()
        guard let videoFormat = streamingData.bestVideoFormat(quality: quality), let url = videoFormat.url else {
            let formatsCount = response.streamingData?.formats?.count ?? 0
            let adaptiveVideoCount =
                response.streamingData?.adaptiveFormats?.compactMap { $0.mimeType }.filter {
                    $0.hasPrefix("video/")
                }.count ?? 0
            Log.player.warning(
                "[\(label, privacy: .public)] No video format available. Formats: \(formatsCount), Adaptive: \(adaptiveVideoCount)"
            )
            return nil
        }
        let contentLength = videoFormat.contentLength.flatMap { Int64($0) }
        Log.player.info(
            "[\(label, privacy: .public)] Video selected: itag=\(videoFormat.itag) mime=\(videoFormat.mimeType, privacy: .public) \(videoFormat.width ?? 0)x\(videoFormat.height ?? 0)"
        )
        return (url, contentLength)
    }

    private func generateCPN() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        return String((0..<16).compactMap { _ in chars.randomElement() }.prefix(16))
    }

    /// Call VISIONOS player and return a StreamDescriptor wrapping the hlsManifestUrl.
    /// Returns nil if VISIONOS fails or doesn't return an HLS manifest.
    private func extractHLSDescriptor(videoId: String) async throws -> StreamDescriptor? {
        let data = try await api.playerWithVisionOS(videoId: videoId)
        let response = try decoder.decode(PlayerResponse.self, from: data)
        guard response.playabilityStatus?.status == "OK",
              let hlsString = response.streamingData?.hlsManifestUrl,
              let hlsURL = URL(string: hlsString) else {
            return nil
        }
        return StreamDescriptor(
            videoID: videoId,
            remoteURL: hlsURL,
            itag: 0,
            mimeType: "application/x-mpegURL",
            codec: "hls",
            bitrate: 0,
            contentLength: nil,
            duration: nil,
            initializationRange: nil,
            indexRange: nil,
            expiresAt: nil,
            requestHeaders: [:],
            provisionalResourceKey: ProvisionalResourceKey(
                videoID: videoId, itag: 0, codec: "hls", declaredTotalLength: nil)
        )
    }
}
