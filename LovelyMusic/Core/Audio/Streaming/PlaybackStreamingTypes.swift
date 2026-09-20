import CryptoKit
import Foundation

struct PlaybackSessionID: Hashable, Sendable {
    let rawValue: UUID

    static func fresh() -> Self {
        Self(rawValue: UUID())
    }
}

struct SourceAttemptID: Hashable, Sendable {
    let rawValue: UUID

    static func fresh() -> Self {
        Self(rawValue: UUID())
    }
}

struct SeekRequestID: Hashable, Sendable {
    let rawValue: UUID

    static func fresh() -> Self {
        Self(rawValue: UUID())
    }
}

struct FullTransferActionID: Hashable, Sendable {
    let rawValue: UUID

    static func fresh() -> Self {
        Self(rawValue: UUID())
    }
}

enum PlaybackSource: Equatable, Sendable {
    case explicitDownload
    case remuxCache
    case rangeStream
    case legacyDownloadRemux
}

enum DesiredPlaybackIntent: Equatable, Sendable {
    case playing
    case paused
}

struct SourceAttempt: Equatable, Sendable {
    let sessionID: PlaybackSessionID
    let id: SourceAttemptID
    let source: PlaybackSource
}

struct SeekAttempt: Equatable, Sendable {
    let sourceAttempt: SourceAttempt
    let id: SeekRequestID
    let targetSeconds: TimeInterval
}

enum PlaybackNetworkClass: String, Codable, Sendable {
    case wifiUnconstrained
    case cellular
    case constrained
    case offline
}

struct LocalGenerationFingerprint: Hashable, Sendable {
    let digest: String
}

struct ProvisionalResourceKey: Hashable, Sendable {
    let digest: String

    init(videoID: String, itag: Int, codec: String, declaredTotalLength: Int64?) {
        digest = PrivacySafeDigest.hash(
            domain: "LovelyMusic.ProvisionalResourceKey.v1",
            components: [
                .some(Data(videoID.utf8)),
                .some(PrivacySafeDigest.integer(Int64(itag))),
                .some(Data(codec.utf8)),
                declaredTotalLength.map(PrivacySafeDigest.integer),
            ]
        )
    }
}

struct ValidatedContentGeneration: Hashable, Sendable {
    let provisionalKey: ProvisionalResourceKey
    let totalLength: Int64
    let strongValidator: String
}

enum ContentGenerationScope: Hashable, Sendable {
    case persistent(ValidatedContentGeneration)
    case attemptOnly(
        sessionID: PlaybackSessionID,
        sourceAttemptID: SourceAttemptID,
        totalLength: Int64
    )

    var localFingerprint: LocalGenerationFingerprint {
        switch self {
        case .persistent(let generation):
            return LocalGenerationFingerprint(
                digest: PrivacySafeDigest.hash(
                    domain: "LovelyMusic.PersistentContentGeneration.v1",
                    components: [
                        .some(Data(generation.provisionalKey.digest.utf8)),
                        .some(PrivacySafeDigest.integer(generation.totalLength)),
                        .some(Data(generation.strongValidator.utf8)),
                    ]
                )
            )
        case .attemptOnly(let sessionID, let sourceAttemptID, let totalLength):
            return LocalGenerationFingerprint(
                digest: PrivacySafeDigest.hash(
                    domain: "LovelyMusic.AttemptContentGeneration.v1",
                    components: [
                        .some(Data(sessionID.rawValue.uuidString.utf8)),
                        .some(Data(sourceAttemptID.rawValue.uuidString.utf8)),
                        .some(PrivacySafeDigest.integer(totalLength)),
                    ]
                )
            )
        }
    }
}

struct StreamDescriptor: Equatable, Sendable {
    let videoID: String
    let remoteURL: URL
    let itag: Int
    let mimeType: String
    let codec: String
    let bitrate: Int
    let contentLength: Int64?
    let duration: Duration?
    let initializationRange: Range<Int64>?
    let indexRange: Range<Int64>?
    let expiresAt: Date?
    let requestHeaders: [String: String]
    let provisionalResourceKey: ProvisionalResourceKey

    func withRequestHeaders(_ headers: [String: String]) -> Self {
        Self(
            videoID: videoID,
            remoteURL: remoteURL,
            itag: itag,
            mimeType: mimeType,
            codec: codec,
            bitrate: bitrate,
            contentLength: contentLength,
            duration: duration,
            initializationRange: initializationRange,
            indexRange: indexRange,
            expiresAt: expiresAt,
            requestHeaders: headers,
            provisionalResourceKey: provisionalResourceKey
        )
    }
}

enum StreamDescriptorError: Error, Equatable, Sendable {
    case missingURL
    case invalidURL
    case missingMIMEType
    case missingCodec
    case invalidBitrate
    case invalidContentLength
    case invalidDuration
    case invalidInitializationRange
    case invalidIndexRange
    case descriptorResolutionUnsupported
    case localResourceIsNotRemoteRangeEligible
}

private enum PrivacySafeDigest {
    static func integer(_ value: Int64) -> Data {
        var bigEndian = value.bigEndian
        return Swift.withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func hash(domain: String, components: [Data?]) -> String {
        var input = Data()
        appendLengthPrefixed(Data(domain.utf8), to: &input)
        for component in components {
            guard let component else {
                input.append(0)
                continue
            }
            input.append(1)
            appendLengthPrefixed(component, to: &input)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLengthPrefixed(_ value: Data, to output: inout Data) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(value)
    }
}

enum PlaybackFailureCategory: String, Codable, Sendable {
    case resolution
    case transport
    case structuralCompatibility
    case seekVerification
    case storage
    case remux
}

enum FullTransferIntent: String, Codable, Sendable {
    case initialPlayback
    case sourceFallback
    case transportRetry
}

struct FailedActionToken: Hashable, Sendable {
    let sessionID: PlaybackSessionID
    let actionID: FullTransferActionID
    let generationFingerprint: LocalGenerationFingerprint
    let failureCategory: PlaybackFailureCategory
    let intent: FullTransferIntent
}

struct StorageReservationID: Hashable, Sendable {
    let rawValue: UUID
}

struct FallbackRequest: Equatable, Sendable {
    let sourceAttempt: SourceAttempt
    let targetSeconds: TimeInterval
    let intent: DesiredPlaybackIntent
    let token: FailedActionToken
}

struct FallbackAttempt: Equatable, Sendable {
    let sourceAttempt: SourceAttempt
    let targetSeconds: TimeInterval
    let intent: DesiredPlaybackIntent
    let reservationID: StorageReservationID
}

struct PlaybackFailure: Equatable, Sendable {
    let category: PlaybackFailureCategory
    let isRecoverable: Bool
    let lastConfirmedPosition: TimeInterval
}

enum PlaybackPhase: Equatable, Sendable {
    case idle
    case resolving(PlaybackSessionID)
    case preparing(SourceAttempt)
    case playing(SourceAttempt)
    case paused(SourceAttempt)
    case seeking(SeekAttempt)
    case seekPreparedWhilePaused(SeekAttempt)
    case verifyingSeek(SeekAttempt)
    case awaitingTransferConsent(FallbackRequest)
    case legacyDownloading(FallbackAttempt)
    case legacyRemuxing(FallbackAttempt)
    case failed(PlaybackFailure)
}

struct ActivePlaybackTokens: Equatable, Sendable {
    let sessionID: PlaybackSessionID
    private(set) var currentSourceAttempt: SourceAttempt
    private(set) var latestSeekAttempt: SeekAttempt?

    private init(
        sessionID: PlaybackSessionID,
        currentSourceAttempt: SourceAttempt,
        latestSeekAttempt: SeekAttempt?
    ) {
        precondition(currentSourceAttempt.sessionID == sessionID)
        precondition(
            latestSeekAttempt.map { $0.sourceAttempt == currentSourceAttempt }
                ?? true
        )
        self.sessionID = sessionID
        self.currentSourceAttempt = currentSourceAttempt
        self.latestSeekAttempt = latestSeekAttempt
    }

    static func freshSession(source: PlaybackSource) -> Self {
        let sessionID = PlaybackSessionID.fresh()
        return Self(
            sessionID: sessionID,
            currentSourceAttempt: SourceAttempt(
                sessionID: sessionID,
                id: .fresh(),
                source: source
            ),
            latestSeekAttempt: nil
        )
    }

    /// Binds driver cancellation/progress identity to the exact coordinator-owned
    /// fallback attempt after the transfer gate has issued a reservation.
    static func validatedLegacyFallback(_ fallback: FallbackAttempt) -> Self? {
        guard fallback.sourceAttempt.source == .legacyDownloadRemux else {
            return nil
        }
        return Self(
            sessionID: fallback.sourceAttempt.sessionID,
            currentSourceAttempt: fallback.sourceAttempt,
            latestSeekAttempt: nil
        )
    }

    /// Binds descriptor qualification to the exact coordinator-owned gate
    /// candidate, including its failed-action session identity. Accepting the
    /// complete gate attempt prevents arbitrary source attempts from minting
    /// driver-valid capabilities.
    static func validatedLegacyGateAttempt(
        _ gateAttempt: PlaybackTransferGateAttempt
    ) -> Self? {
        let request = gateAttempt.request
        guard request.sourceAttempt.source == .legacyDownloadRemux,
            request.sourceAttempt.sessionID == request.token.sessionID
        else {
            return nil
        }
        return Self(
            sessionID: request.sourceAttempt.sessionID,
            currentSourceAttempt: request.sourceAttempt,
            latestSeekAttempt: nil
        )
    }

    mutating func refreshCurrentSourceAttempt() -> SourceAttempt {
        let sourceAttempt = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: currentSourceAttempt.source
        )
        currentSourceAttempt = sourceAttempt
        latestSeekAttempt = nil
        return sourceAttempt
    }

    mutating func downgradeToLegacy(
        using sourceLock: inout PlaybackSourceLock
    ) -> SourceAttempt? {
        guard currentSourceAttempt.sessionID == sessionID,
            currentSourceAttempt.source == .rangeStream
        else {
            return nil
        }

        let legacyAttempt = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .legacyDownloadRemux
        )
        guard sourceLock.authorizeRangeToLegacy(legacyAttempt) else {
            return nil
        }

        currentSourceAttempt = legacyAttempt
        latestSeekAttempt = nil
        return legacyAttempt
    }

    mutating func beginSeek(targetSeconds: TimeInterval) -> SeekAttempt? {
        guard targetSeconds.isFinite, targetSeconds >= 0 else { return nil }

        let seekAttempt = SeekAttempt(
            sourceAttempt: currentSourceAttempt,
            id: .fresh(),
            targetSeconds: targetSeconds
        )
        latestSeekAttempt = seekAttempt
        return seekAttempt
    }

    func accepts(_ sourceAttempt: SourceAttempt) -> Bool {
        sourceAttempt.sessionID == sessionID
            && sourceAttempt == currentSourceAttempt
    }

    func accepts(_ seekAttempt: SeekAttempt) -> Bool {
        accepts(seekAttempt.sourceAttempt)
            && seekAttempt == latestSeekAttempt
    }
}

struct PlaybackSourceLock: Equatable, Sendable {
    let sessionID: PlaybackSessionID
    private(set) var selectedRemoteSource: PlaybackSource

    init?(initialRangeAttempt: SourceAttempt) {
        guard initialRangeAttempt.source == .rangeStream else { return nil }

        sessionID = initialRangeAttempt.sessionID
        selectedRemoteSource = .rangeStream
    }

    fileprivate mutating func authorizeRangeToLegacy(
        _ candidate: SourceAttempt
    ) -> Bool {
        guard candidate.sessionID == sessionID,
            selectedRemoteSource == .rangeStream,
            candidate.source == .legacyDownloadRemux
        else {
            return false
        }

        selectedRemoteSource = .legacyDownloadRemux
        return true
    }
}

enum FailureCounter: Equatable, Sendable {
    case resolverRetry
    case signedURLRefresh
    case rangeTransportRetry
    case rangeToLegacyDowngrade
    case legacyWiFiTransportRetry
    case legacyMeteredTransportRetry
    case legacyRemuxRetry
    case consentPrompt(FailedActionToken)
}

struct PlaybackSessionFailureBudget: Equatable, Sendable {
    private(set) var resolverRetries = 1
    private(set) var signedURLRefreshes = 1
    private(set) var rangeTransportRetries = 2
    private(set) var rangeToLegacyDowngrades = 1
    private(set) var legacyWiFiTransportRetries = 1
    private(set) var legacyMeteredTransportRetries = 0
    private(set) var legacyRemuxRetries = 1
    private(set) var consentPromptsByToken: Set<FailedActionToken> = []

    private init() {}

    static let initial = Self()

    mutating func consume(_ counter: FailureCounter) -> Bool {
        switch counter {
        case .resolverRetry:
            guard resolverRetries > 0 else { return false }
            resolverRetries -= 1
            return true
        case .signedURLRefresh:
            guard signedURLRefreshes > 0 else { return false }
            signedURLRefreshes -= 1
            return true
        case .rangeTransportRetry:
            guard rangeTransportRetries > 0 else { return false }
            rangeTransportRetries -= 1
            return true
        case .rangeToLegacyDowngrade:
            guard rangeToLegacyDowngrades > 0 else { return false }
            rangeToLegacyDowngrades -= 1
            return true
        case .legacyWiFiTransportRetry:
            guard legacyWiFiTransportRetries > 0 else { return false }
            legacyWiFiTransportRetries -= 1
            return true
        case .legacyMeteredTransportRetry:
            guard legacyMeteredTransportRetries > 0 else { return false }
            legacyMeteredTransportRetries -= 1
            return true
        case .legacyRemuxRetry:
            guard legacyRemuxRetries > 0 else { return false }
            legacyRemuxRetries -= 1
            return true
        case .consentPrompt(let token):
            return consentPromptsByToken.insert(token).inserted
        }
    }
}

struct PlaybackAudioItemID: Hashable, Sendable {
    let rawValue: UUID

    static func fresh() -> Self {
        Self(rawValue: UUID())
    }
}
