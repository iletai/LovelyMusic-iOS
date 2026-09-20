import Foundation

enum StreamMIMEBaseSyntax {
    static func trimmedBase(_ rawValue: String) -> String {
        let base = rawValue.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? ""
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedBase(_ rawValue: String) -> String {
        trimmedBase(rawValue).lowercased()
    }

    static func isValid(_ base: String) -> Bool {
        let components = base.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.count == 2
            && isValidToken(components[0])
            && isValidToken(components[1])
    }

    static func isPotentialAACCandidate(_ rawValue: String) -> Bool {
        let rawBase = trimmedBase(rawValue)
        let base = rawBase.lowercased()
        if rawBase.isEmpty {
            return true
        }
        if isValid(rawBase) {
            return base == "audio/mp4"
        }
        if base.hasPrefix("video/") {
            return false
        }
        return base == "audio"
            || base.hasPrefix("audio/")
            || base == "/mp4"
            || base.hasSuffix("/mp4")
            || (base.contains("audio") && base.contains("mp4"))
    }

    private static func isValidToken(_ value: Substring) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (33...126).contains(scalar.value)
                && !"()<>@,;:\\\"/[]?=".unicodeScalars.contains(scalar)
        }
    }
}

struct StreamingData {
    let formats: [StreamFormat]
    let adaptiveFormats: [StreamFormat]
    let expiresAt: Date?

    var allFormats: [StreamFormat] {
        formats + adaptiveFormats
    }

    func bestAudioFormat(
        quality: AudioQuality = .high,
        flags: FeatureFlagManager? = nil,
        candidateIsPlayable: ((StreamFormat) -> Bool)? = nil
    ) -> StreamFormat? {
        let maxBitrate = quality.maxBitrate(from: flags)

        // Empty or malformed audio-like bases stay observable to the resolver,
        // while syntactically valid WebM/Opus and video MIME remain ineligible.
        let audioCandidates = allFormats.filter {
            StreamMIMEBaseSyntax.isPotentialAACCandidate($0.mimeType)
        }

        guard !audioCandidates.isEmpty else { return nil }

        let isPlayable = candidateIsPlayable ?? Self.hasSupportedRemoteAudio
        let playable = audioCandidates.filter(isPlayable)

        // A malformed format is only selected when no playable candidate exists.
        // Original response order makes the resulting typed error deterministic.
        guard !playable.isEmpty else { return audioCandidates.first }

        // Prefer formats within quality limit, pick highest bitrate among those
        let withinLimit = playable
            .filter { ($0.bitrate ?? 0) <= maxBitrate }
            .sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }

        // If none within limit, take lowest available bitrate (closest to desired quality)
        return withinLimit.first ?? playable
            .sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            .first
    }

    private static func normalizedBaseMIME(_ mimeType: String) -> String {
        StreamMIMEBaseSyntax.normalizedBase(mimeType)
    }

    private static func hasSupportedRemoteAudio(_ format: StreamFormat) -> Bool {
        guard
            StreamMIMEBaseSyntax.isValid(
                StreamMIMEBaseSyntax.trimmedBase(format.mimeType)
            ),
            normalizedBaseMIME(format.mimeType) == "audio/mp4",
            let rawURL = format.url,
            let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty,
            url.absoluteString == rawURL
        else {
            return false
        }
        return true
    }
    /// Best video format for overlay playback (video-only adaptive stream).
    /// AVPlayer supports video/mp4 (H.264) natively.
    /// Uses adaptiveFormats (video-only) since muxed formats are rarely available.
    func bestVideoFormat(quality: VideoQuality = .auto) -> StreamFormat? {
        // First try muxed formats (rare in 2024+)
        let muxed = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") && $0.url != nil
        }
        if let best = muxed.sorted(by: { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }).first {
            return best
        }

        // Fallback: adaptive video-only formats (always available)
        let adaptive = adaptiveFormats.filter {
            $0.mimeType.hasPrefix("video/mp4") && $0.url != nil
        }
        let maxHeight = quality.maxHeight
        let preferred = adaptive.filter { ($0.height ?? 0) <= maxHeight }
        let pool = preferred.isEmpty ? adaptive : preferred
        return pool.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first
    }
}

struct StreamFormat: Codable {
    let itag: Int
    let url: String?
    let mimeType: String
    let bitrate: Int?
    let contentLength: String?
    let quality: String?
    let audioQuality: String?
    let audioSampleRate: String?
    let audioChannels: Int?
    let approxDurationMs: String?
    let initializationRange: StreamByteRange?
    let indexRange: StreamByteRange?
    let width: Int?
    let height: Int?

    init(
        itag: Int,
        url: String?,
        mimeType: String,
        bitrate: Int?,
        contentLength: String?,
        quality: String?,
        audioQuality: String?,
        audioSampleRate: String?,
        audioChannels: Int?,
        approxDurationMs: String?,
        initializationRange: StreamByteRange? = nil,
        indexRange: StreamByteRange? = nil,
        width: Int?,
        height: Int?
    ) {
        self.itag = itag
        self.url = url
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.contentLength = contentLength
        self.quality = quality
        self.audioQuality = audioQuality
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.approxDurationMs = approxDurationMs
        self.initializationRange = initializationRange
        self.indexRange = indexRange
        self.width = width
        self.height = height
    }

    var isAudioOnly: Bool {
        mimeType.hasPrefix("audio/")
    }

    var isVideo: Bool {
        mimeType.hasPrefix("video/")
    }
}

/// `nil` means the upstream range was absent. `.invalid` preserves a present
/// but malformed range so descriptor resolution can reject it explicitly.
enum StreamByteRange: Codable, Equatable, Sendable {
    case valid(Range<Int64>)
    case invalid
}
