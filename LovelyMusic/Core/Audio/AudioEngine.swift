import AVFoundation
import Foundation
import MediaPlayer
import os

@MainActor
private final class GuardedCoordinatorBox: @unchecked Sendable {
    weak var coordinator: PlaybackCoordinator?
}

@MainActor
private final class AudioEngineGuardedArtifactHost: GuardedLegacyArtifactHosting,
    @unchecked Sendable
{
    weak var engine: AudioEngine?

    init(engine: AudioEngine) {
        self.engine = engine
    }

    var currentPosition: TimeInterval {
        engine?.guardedObservedPosition ?? 0
    }

    func installArtifact(_ url: URL, song: Song, isRaw: Bool) {
        engine?.installGuardedHostArtifact(url, song: song, isRaw: isRaw)
    }

    func seek(to targetSeconds: TimeInterval) async -> TimeInterval? {
        await engine?.physicallySeekGuardedHostArtifact(to: targetSeconds)
    }

    func play() {
        engine?.playGuardedHostArtifact()
    }

    func pause() {
        engine?.pauseGuardedHostArtifact()
    }
}

@MainActor
@Observable
final class AudioEngine {
    // MARK: - State
    private(set) var currentTrack: Song? {
        didSet {
            guard oldValue?.id != currentTrack?.id else { return }
            invalidateCrossfadePreparation(clearReservation: true)
        }
    }
    private(set) var queue: [Song] = [] {
        didSet {
            guard oldValue.map(\.id) != queue.map(\.id) else { return }
            queueRevision &+= 1
            invalidateCrossfadePreparation(clearReservation: true)
        }
    }
    private(set) var autoplayQueue: [Song] = [] {
        didSet {
            guard oldValue.map(\.id) != autoplayQueue.map(\.id) else { return }
            autoplayRevision &+= 1
            invalidateCrossfadePreparation(clearReservation: true)
        }
    }
    private(set) var currentIndex: Int = 0 {
        didSet {
            guard oldValue != currentIndex else { return }
            invalidateCrossfadePreparation(clearReservation: true)
        }
    }
    private(set) var isPlaying: Bool = false {
        didSet {
            // Keep the muted video layer mirrored automatically — covers
            // every code path (interruption resume, stall recovery, end of
            // track, autoplay) without scattering manual sync calls.
            guard oldValue != isPlaying else { return }
            videoManager.setIsPlaying(isPlaying)
        }
    }
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isBuffering: Bool = false
    private(set) var lastError: String?
    /// Classifies the most recent `lastError`. Permanent errors (e.g., the
    /// video is region-blocked or removed) should not be auto-retried by the
    /// presentation layer because the result will not change.
    private(set) var lastErrorKind: PlaybackErrorKind = .transient
    /// The song ID that caused `lastError`. Pinned at error time so that
    /// consumers don't need to race against `currentTrack` updates.
    private(set) var lastFailedSongId: String?
    private(set) var isReconnecting: Bool = false
    private(set) var transferConsentViewState: TransferConsentViewState?
    private(set) var guardedPlaybackError: GuardedPlaybackError?
    private(set) var isPlayingFromAutoplay: Bool = false {
        didSet {
            guard oldValue != isPlayingFromAutoplay else { return }
            invalidateCrossfadePreparation(clearReservation: true)
        }
    }

    enum PlaybackErrorKind {
        case transient
        case permanent
    }

    enum CrossfadePreparationError: Error, Equatable, LocalizedError {
        case notLocallyAvailable

        var errorDescription: String? {
            switch self {
            case .notLocallyAvailable:
                "Crossfade source is not locally available"
            }
        }
    }

    var shuffleEnabled: Bool = false {
        didSet {
            guard oldValue != shuffleEnabled else { return }
            playbackPolicyRevision &+= 1
            invalidateCrossfadePreparation(clearReservation: true)
            if shuffleEnabled {
                generateShuffledOrder()
            } else {
                shuffledIndices = []
                shufflePosition = 0
                recentlyPlayedIndices = []
            }
            savePlaybackState()
        }
    }
    var repeatMode: RepeatMode = .off {
        didSet {
            guard oldValue != repeatMode else { return }
            playbackPolicyRevision &+= 1
            invalidateCrossfadePreparation(clearReservation: true)
        }
    }

    var playbackSpeed: Float = 1.0 {
        didSet {
            if isPlaying {
                player?.rate = playbackSpeed
            }
            applyAudioProcessing()
            UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed")
        }
    }

    var streamURLResolver: ((String) async throws -> (url: String, contentLength: Int64?))?
    var videoStreamURLResolver: ((String) async throws -> (url: String, contentLength: Int64?)?)? {
        didSet { videoManager.videoStreamURLResolver = videoStreamURLResolver }
    }
    var streamHeaders: [String: String] = [:] {
        didSet { videoManager.streamHeaders = streamHeaders }
    }

    /// Returns the YouTube auth cookie string (SAPISID, SID, __Secure-1PSID, etc.)
    /// needed for CDN authentication of session-signed URLs. Set from DIContainer.
    var authCookieProvider: (() -> String?)? = nil
    /// Closure providing current premium status. Injected by DIContainer.
    var isPremiumProvider: (() -> Bool)?

    /// Optional reference to the download manager for offline playback.
    var downloadManager: DownloadManager?

    /// Optional LRU cache manager for remuxed audio files.
    var audioCacheManager: AudioCacheManager?

    /// A file URL that has already passed the production local-source checks.
    /// Its initializer is intentionally unavailable outside AudioEngine so a
    /// test seam cannot manufacture or substitute a remote player item.
    struct CrossfadeLocalFile: Equatable, Sendable {
        let url: URL

        fileprivate init(url: URL) {
            self.url = url
        }
    }

    /// Internal observation/suspension seam used only after a cache/download
    /// provider has returned an existing file URL. It cannot replace the item
    /// that production constructs from the validated local file.
    var crossfadeLocalPreparationBarrier: ((CrossfadeLocalFile) async -> Void)?

    /// Called when the queue is exhausted and autoplay should fetch more songs.
    var onQueueExhausted: (() -> Void)?

    /// Optional persistence manager for saving/restoring playback state across app launches.
    var playbackStatePersistence: PlaybackStatePersistence?

    enum RepeatMode: String, Codable {
        case off, all, one
    }

    // MARK: - Private
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var itemObservations: [NSKeyValueObservation] = []
    private var timeControlObserver: NSKeyValueObservation?
    private var endOfTrackObserver: NSObjectProtocol?
    private var streamResolvedAt: Date?
    private var userInitiatedPause: Bool = false
    private var pendingSeekTime: TimeInterval?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var accessLogObserver: NSObjectProtocol?
    private var downloadTask: URLSessionTask?
    private(set) var localFileURL: URL?

    private struct GuardedResolvedContext {
        let descriptor: StreamDescriptor
        let qualified: QualifiedLegacyDescriptor
    }

    private struct GuardedConsentContext {
        let attempt: PlaybackTransferGateAttempt
        let challenge: FullTransferConsentChallenge
        let estimate: FullTransferEstimate
    }

    private struct GuardedPreparedRemuxContext {
        let fallbackSourceAttemptID: SourceAttemptID
        let resource: LegacyDownloadedResource
        let song: Song
        var isInstalled: Bool
    }

    private var guardedConfiguration: GuardedLegacyPlaybackConfiguration?
    private var guardedCoordinator: PlaybackCoordinator?
    private var guardedOwnerID: UUID?
    private var guardedQualificationTokens: ActivePlaybackTokens?
    private var guardedResolvedContext: GuardedResolvedContext?
    private var guardedConsentContext: GuardedConsentContext?
    private var guardedDownloadedResources: [SourceAttemptID: LegacyDownloadedResource] = [:]
    private var guardedPreparedRemuxContext: GuardedPreparedRemuxContext?
    private var guardedOwnedResources: [SourceAttemptID: LegacyDownloadedResource] = [:]
    private var guardedActiveRequest: LegacyPlaybackRequest?
    private var guardedResolutionFailureCount = 0
    private var guardedRemuxFailureCounts: [SourceAttemptID: Int] = [:]
    private var guardedPendingArtifactOwners: Set<UUID> = []
    private var guardedPendingConsentOwners: Set<UUID> = []
    private var guardedPendingGateAttempts: Set<PlaybackTransferGateAttemptID> = []
    private var guardedLatestNetworkSnapshot: NetworkSnapshot?
    private var guardedApplicationIsActive = true
    private var guardedPhoneUIAvailable = false

    var hasPendingGuardedArtifactOperation: Bool {
        !guardedPendingArtifactOwners.isEmpty
    }

    var hasPendingGuardedConsentOperation: Bool {
        !guardedPendingConsentOwners.isEmpty
    }

    var hasPendingGuardedGateOperation: Bool {
        !guardedPendingGateAttempts.isEmpty
    }

    var hasGuardedLegacyPlaybackConfiguration: Bool {
        guardedConfiguration != nil
    }

    var guardedPlaybackPhase: PlaybackPhase? {
        guardedCoordinator?.state.phase
    }

    @ObservationIgnored
    private lazy var guardedArtifactHostAdapter = AudioEngineGuardedArtifactHost(
        engine: self
    )

    var guardedLegacyArtifactHost: any GuardedLegacyArtifactHosting {
        guardedArtifactHostAdapter
    }

    // Stream-first playback: stream fMP4 immediately, download+remux in background
    private var resolveTask: Task<Void, Never>?
    private(set) var isStreamingMode: Bool = false
    private var backgroundRemuxTask: Task<Void, Never>?

    // Gapless playback (delegated to GaplessPreFetchManager)
    private let prefetchManager = GaplessPreFetchManager()

    // Fisher-Yates shuffle state
    private struct ShuffleProgress {
        let indices: [Int]
        let position: Int
        let recentlyPlayedIndices: [Int]
    }
    private var shuffledIndices: [Int] = []
    private var shufflePosition: Int = 0
    private var recentlyPlayedIndices: [Int] = []

    // Crossfade between tracks (delegated to CrossfadeManager)
    let crossfadeManager = CrossfadeManager()
    private enum CrossfadeDestination: Equatable {
        case queue(index: Int)
        case autoplay
    }
    private struct CrossfadeReservation: Equatable {
        let sourceSongID: String
        let sourceIndex: Int
        let sourceWasAutoplay: Bool
        let nextSongID: String
        let destination: CrossfadeDestination
        let queueRevision: UInt64
        let autoplayRevision: UInt64
        let playbackPolicyRevision: UInt64
        let shuffleEnabled: Bool
        let repeatMode: RepeatMode
    }
    private struct CrossfadePreparationToken: Equatable {
        let generation: UInt64
        let reservation: CrossfadeReservation
    }
    private var queueRevision: UInt64 = 0
    private var autoplayRevision: UInt64 = 0
    private var playbackPolicyRevision: UInt64 = 0
    private var crossfadePreparationGeneration: UInt64 = 0
    private var crossfadePreparationTask: Task<Void, Never>?
    private var crossfadeReservation: CrossfadeReservation?
    private var reservedShuffleProgress: ShuffleProgress?
    private var attemptedCrossfadeReservation: CrossfadeReservation?
    private var attemptedCrossfadeLocalURL: URL?
    private var activeCrossfadeToken: CrossfadePreparationToken?
    /// Secondary AVPlayer used exclusively during crossfade transitions.
    private var crossfadePlayer: AVPlayer?
    /// Observers attached to the crossfade player item.
    private var crossfadeItemObservations: [NSKeyValueObservation] = []
    /// Time observer for the crossfade player.
    private var crossfadeTimeObserver: Any?

    // Video playback (delegated to VideoPlaybackManager)
    private let videoManager = VideoPlaybackManager()
    var isVideoMode: Bool { videoManager.isVideoMode }
    var videoLoadState: VideoPlaybackManager.VideoLoadState { videoManager.videoLoadState }
    var videoPlayerItem: AVPlayerItem? { videoManager.videoPlayerItem }
    /// The AVPlayer instance used for video streaming (separate from audio player)
    var videoPlayer: AVPlayer? { videoManager.videoPlayer }

    // Equalizer
    private let eqProcessor = EQAudioProcessor()
    var equalizerManager: EqualizerManager? {
        didSet { applyEqualizer() }
    }
    private var equalizerObserver: NSObjectProtocol?

    // Skip Silence & Normalization
    private(set) var skipSilenceEnabled: Bool = false
    private(set) var normalizationEnabled: Bool = false
    private var skipSilenceObserver: NSObjectProtocol?
    private var normalizationObserver: NSObjectProtocol?
    private var normalizedVolume: Float = 1.0
    private var crossfadeDurationObserver: NSObjectProtocol?

    private let nowPlayingManager = NowPlayingManager()
    private let remoteCommandManager = RemoteCommandManager()
    @ObservationIgnored
    private lazy var recoveryService: PlaybackRecoveryService = {
        PlaybackRecoveryService(eventSink: { [weak self] event in
            self?.receivePlaybackRecoveryEvent(event)
        })
    }()
    private static let maxStreamRecoveryAttempts = 2
    private var streamRecoveryAttemptCount: Int = 0

    init() {
        let savedSpeed = UserDefaults.standard.float(forKey: "playbackSpeed")
        playbackSpeed = savedSpeed > 0 ? savedSpeed : 1.0
        recoveryService.delegate = self
        setupRemoteCommands()
        setupInterruptionHandling()
        setupAudioProcessingObservers()
        AudioSessionManager.onResume = { [weak self] in
            self?.resumePlayer()
            self?.isPlaying = true
        }
    }

    deinit {
        // deinit is nonisolated, but for a @MainActor class we can use
        // assumeIsolated to perform all cleanup synchronously — never use
        // Task {} in deinit as it is fire-and-forget and may never execute.
        MainActor.assumeIsolated {
            self.recoveryService.stopStallDetection()
            if let tObs = self.timeObserver { self.player?.removeTimeObserver(tObs) }
            if let endObs = self.endOfTrackObserver {
                NotificationCenter.default.removeObserver(endObs)
            }
            if let intObs = self.interruptionObserver {
                NotificationCenter.default.removeObserver(intObs)
            }
            if let routeObs = self.routeChangeObserver {
                NotificationCenter.default.removeObserver(routeObs)
            }
            if let errLogObs = self.errorLogObserver {
                NotificationCenter.default.removeObserver(errLogObs)
            }
            if let accLogObs = self.accessLogObserver {
                NotificationCenter.default.removeObserver(accLogObs)
            }
            if let skipObs = self.skipSilenceObserver {
                NotificationCenter.default.removeObserver(skipObs)
            }
            if let normObs = self.normalizationObserver {
                NotificationCenter.default.removeObserver(normObs)
            }
            if let crossObs = self.crossfadeDurationObserver {
                NotificationCenter.default.removeObserver(crossObs)
            }
            self.timeControlObserver?.invalidate()
            self.itemObservations.forEach { $0.invalidate() }
            self.resolveTask?.cancel()
            self.backgroundRemuxTask?.cancel()
            self.pauseInstalledGuardedArtifactIfNeeded()
            self.guardedCoordinator?.shutdown()
            if let configuration = self.guardedConfiguration {
                var resourcesBySourceAttempt: [
                    SourceAttemptID: LegacyDownloadedResource
                ] = [:]
                for resource in self.guardedDownloadedResources.values {
                    resourcesBySourceAttempt[
                        resource.request.tokens.currentSourceAttempt.id
                    ] = resource
                }
                for resource in self.guardedOwnedResources.values {
                    resourcesBySourceAttempt[
                        resource.request.tokens.currentSourceAttempt.id
                    ] = resource
                }
                if let prepared = self.guardedPreparedRemuxContext {
                    resourcesBySourceAttempt[
                        prepared.resource.request.tokens.currentSourceAttempt.id
                    ] = prepared.resource
                }
                self.guardedDownloadedResources.removeAll()
                self.guardedOwnedResources.removeAll()
                self.guardedPreparedRemuxContext = nil
                resourcesBySourceAttempt.values.forEach {
                    configuration.disposeCompletedArtifactSynchronously($0)
                }
            }
            self.crossfadePreparationTask?.cancel()
            self.prefetchManager.cancelPrefetch()
            self.crossfadeManager.cancelFade()
            self.cleanupCrossfadePlayer()

            self.remoteCommandManager.tearDown()
            AudioSessionManager.onResume = nil
        }
    }

    // MARK: - Public API

    private func pauseInstalledGuardedArtifactIfNeeded() {
        guard isPlaying, let configuration = guardedConfiguration else { return }
        let hasInstalledPreparedArtifact = guardedPreparedRemuxContext?.isInstalled == true
        let hasInstalledOwnedArtifact = !guardedOwnedResources.isEmpty
        let hasInstalledRawArtifact = guardedDownloadedResources.values.contains {
            $0.rawURL == localFileURL
        }
        guard hasInstalledPreparedArtifact
            || hasInstalledOwnedArtifact
            || hasInstalledRawArtifact
        else {
            return
        }
        configuration.artifactHost.pause()
        isPlaying = false
    }

    private func shutdownGuardedSession(clearError: Bool) {
        pauseInstalledGuardedArtifactIfNeeded()
        var downloadedOnlyBySourceAttempt: [
            SourceAttemptID: LegacyDownloadedResource
        ] = [:]
        for resource in guardedDownloadedResources.values {
            downloadedOnlyBySourceAttempt[
                resource.request.tokens.currentSourceAttempt.id
            ] = resource
        }
        var handedOffBySourceAttempt: [
            SourceAttemptID: LegacyDownloadedResource
        ] = [:]
        for resource in guardedOwnedResources.values {
            handedOffBySourceAttempt[
                resource.request.tokens.currentSourceAttempt.id
            ] = resource
        }
        if let preparedResource = guardedPreparedRemuxContext?.resource {
            handedOffBySourceAttempt[
                preparedResource.request.tokens.currentSourceAttempt.id
            ] = preparedResource
        }
        for sourceAttemptID in handedOffBySourceAttempt.keys {
            downloadedOnlyBySourceAttempt.removeValue(forKey: sourceAttemptID)
        }

        guardedCoordinator?.shutdown()
        guardedCoordinator = nil
        guardedOwnerID = nil
        transferConsentViewState = nil
        guardedConsentContext = nil
        guardedQualificationTokens = nil
        guardedResolvedContext = nil
        guardedActiveRequest = nil
        guardedDownloadedResources.removeAll()
        guardedPreparedRemuxContext = nil
        guardedOwnedResources.removeAll()
        guardedResolutionFailureCount = 0
        guardedRemuxFailureCounts.removeAll()
        if clearError { guardedPlaybackError = nil }

        guard let configuration = guardedConfiguration else { return }
        for resource in downloadedOnlyBySourceAttempt.values {
            Task {
                await configuration.legacyDriver.cancel(resource.request)
            }
        }
        for resource in handedOffBySourceAttempt.values {
            Task {
                await configuration.legacyDriver.dispose(resource)
            }
        }
    }

    private func disposeClaimedGuardedResourceIfPresent(
        sourceAttemptID: SourceAttemptID,
        resource: LegacyDownloadedResource,
        configuration: GuardedLegacyPlaybackConfiguration
    ) async {
        guard guardedOwnedResources[sourceAttemptID] == resource else { return }
        guardedOwnedResources.removeValue(forKey: sourceAttemptID)
        await configuration.legacyDriver.dispose(resource)
    }

    private func isCurrentGuardedOwner(
        _ ownerID: UUID,
        coordinator: PlaybackCoordinator
    ) -> Bool {
        guardedOwnerID == ownerID && guardedCoordinator === coordinator
    }

    func installGuardedLegacyPlayback(
        _ configuration: GuardedLegacyPlaybackConfiguration
    ) {
        shutdownGuardedSession(clearError: true)
        guardedConfiguration = configuration
        guardedLatestNetworkSnapshot = configuration.initialNetworkSnapshot
        guardedCoordinator = nil
        guardedQualificationTokens = nil
        guardedResolvedContext = nil
        guardedConsentContext = nil
        guardedDownloadedResources.removeAll()
        guardedPreparedRemuxContext = nil
        guardedOwnedResources.removeAll()
        guardedActiveRequest = nil
        transferConsentViewState = nil
        guardedPlaybackError = nil
    }

    func acceptsGuardedLegacyTokens(_ tokens: ActivePlaybackTokens) -> Bool {
        guard let coordinator = guardedCoordinator,
            coordinator.state.activeSessionID == tokens.sessionID,
            coordinator.state.activeSourceAttempt == tokens.currentSourceAttempt,
            tokens.currentSourceAttempt.source == .legacyDownloadRemux
        else {
            return false
        }
        return true
    }

    func respondToTransferConsent(_ disposition: TransferConsentUserDisposition) {
        guard let coordinator = guardedCoordinator,
            let ownerID = guardedOwnerID,
            let context = guardedConsentContext,
            let latestAttempt = coordinator.state.pendingTransferGateAttempt,
            latestAttempt.id == context.attempt.id
        else {
            return
        }

        transferConsentViewState = nil
        guardedConsentContext = nil
        switch disposition {
        case .decline, .dismissed:
            guardedPlaybackError = .transferConsentDeclined
            isPlaying = false
            isBuffering = false
            coordinator.send(.transferConsentDeclined(latestAttempt))

        case .accept:
            guard guardedApplicationIsActive, guardedPhoneUIAvailable,
                let configuration = guardedConfiguration
            else {
                guardedPlaybackError = .continueOnPhone
                isPlaying = false
                isBuffering = false
                coordinator.send(.transferConsentDeclined(latestAttempt))
                return
            }
            guardedPendingConsentOwners.insert(ownerID)
            Task { [weak self] in
                guard let self else { return }
                defer { self.guardedPendingConsentOwners.remove(ownerID) }
                let grant = await configuration.transferGate.acceptConsent(
                    context.challenge
                )
                guard self.isCurrentGuardedOwner(ownerID, coordinator: coordinator)
                else { return }
                guard self.guardedApplicationIsActive,
                    self.guardedPhoneUIAvailable,
                    coordinator.state.pendingTransferGateAttempt?.id == latestAttempt.id
                else {
                    self.guardedPlaybackError = .continueOnPhone
                    self.isPlaying = false
                    self.isBuffering = false
                    coordinator.send(.transferConsentDeclined(latestAttempt))
                    return
                }
                guard let grant,
                    let request = self.makeFullTransferRequest(for: latestAttempt)
                else {
                    self.guardedPlaybackError = .policyDenied(
                        .consentChallengeInvalidated
                    )
                    self.isPlaying = false
                    self.isBuffering = false
                    coordinator.send(
                        .fullTransferGateDenied(
                            latestAttempt,
                            denial: PlaybackTransferGateDenial(category: .transport)
                        )
                    )
                    return
                }
                let decision = await configuration.transferGate.evaluate(
                    request,
                    consentGrant: grant
                )
                guard self.isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    coordinator.state.pendingTransferGateAttempt?.id == latestAttempt.id,
                    self.guardedApplicationIsActive,
                    self.guardedPhoneUIAvailable
                else {
                    if case .allow(let reservationID) = decision {
                        await configuration.transferGate.releaseReservation(
                            reservationID
                        )
                    }
                    if self.isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                        (!self.guardedApplicationIsActive || !self.guardedPhoneUIAvailable)
                    {
                        self.guardedPlaybackError = .continueOnPhone
                        self.isPlaying = false
                        self.isBuffering = false
                        coordinator.send(.transferConsentDeclined(latestAttempt))
                    }
                    return
                }
                self.handleAcceptedConsentDecision(
                    decision,
                    attempt: latestAttempt,
                    coordinator: coordinator
                )
            }
        }
    }

    func updateTransferConsentPresentation(
        applicationIsActive: Bool,
        phoneUIAvailable: Bool
    ) {
        guardedApplicationIsActive = applicationIsActive
        guardedPhoneUIAvailable = phoneUIAvailable
        guard !applicationIsActive || !phoneUIAvailable else { return }
        let hadConsentFlow = transferConsentViewState != nil
            || guardedConsentContext != nil
            || guardedPlaybackError == .transferConsentDeclined
            || hasPendingGuardedConsentOperation
        guard hadConsentFlow else { return }
        transferConsentViewState = nil
        guardedConsentContext = nil
        guardedPlaybackError = .continueOnPhone
        isPlaying = false
        isBuffering = false
        if let coordinator = guardedCoordinator,
            let attempt = coordinator.state.pendingTransferGateAttempt
        {
            coordinator.send(.transferConsentDeclined(attempt))
        }
    }

    func receivePlaybackNetworkSnapshot(_ snapshot: NetworkSnapshot) {
        guardedLatestNetworkSnapshot = snapshot
        guard let configuration = guardedConfiguration else { return }
        let coordinator = guardedCoordinator
        let presentedConsentIdentity: (
            attemptID: PlaybackTransferGateAttemptID,
            token: FailedActionToken
        )? = {
            guard let context = guardedConsentContext,
                let viewState = transferConsentViewState,
                context.attempt.request.token == viewState.token
            else {
                return nil
            }
            return (context.attempt.id, viewState.token)
        }()
        coordinator?.send(.networkSnapshotChanged(snapshot))
        if let presentedConsentIdentity,
            coordinator?.state.pendingTransferGateAttempt?.id
                != presentedConsentIdentity.attemptID,
            guardedConsentContext?.attempt.id == presentedConsentIdentity.attemptID,
            transferConsentViewState?.token == presentedConsentIdentity.token
        {
            guardedConsentContext = nil
            transferConsentViewState = nil
            guardedPlaybackError = .policyDenied(.consentChallengeInvalidated)
            isPlaying = false
            isBuffering = false
        }
        Task { [weak self] in
            await configuration.transferGate.updateNetwork(snapshot)
            guard let self else { return }
            guard coordinator == nil || self.guardedCoordinator === coordinator else { return }
        }
    }

    func retryGuardedPlayback() {
        guard guardedConfiguration != nil, let song = currentTrack else { return }
        startGuardedPlayback(song: song, initialPosition: currentTime)
    }

    func receivePlaybackRecoveryEvent(_ event: PlaybackRecoveryEvent) {
        switch event {
        case .stallDetected(let trackID, _):
            guard currentTrack?.id == trackID else { return }
            if let coordinator = guardedCoordinator {
                pauseInstalledGuardedArtifactIfNeeded()
                guardedPlaybackError = .legacyTransportFailed
                isPlaying = false
                isBuffering = false
                coordinator.send(.stop)
            } else if let song = currentTrack, !recoveryService.hasAttemptedRetry {
                recoveryService.retryPlayback(for: song)
            }
        }
    }

    func reportPlaybackItemFailure() {
        if let coordinator = guardedCoordinator {
            pauseInstalledGuardedArtifactIfNeeded()
            guardedPlaybackError = .legacyTransportFailed
            isPlaying = false
            isBuffering = false
            coordinator.send(.stop)
            return
        }
        guard let song = currentTrack else { return }
        if !recoveryService.hasAttemptedRetry {
            recoveryService.retryPlayback(for: song)
        } else {
            isBuffering = false
            lastError = "Playback failed"
        }
    }

    func stop() {
        shutdownGuardedSession(clearError: true)
        resolveTask?.cancel()
        backgroundRemuxTask?.cancel()
        downloadTask?.cancel()
        cleanupPlayer()
        isPlaying = false
        isBuffering = false
    }

    func play(song: Song, fromQueue: [Song] = []) {
        // Round 2 — Fix 1 (review.md M1 / review-codex MED #5):
        // Reset `lastError` at entry so consumers (e.g. CarPlay
        // `handleSongTap`) can detect a *new* failure when two consecutive
        // attempts fail with an identical message. Without this reset, the
        // second attempt's diff against the snapshot baseline would compare
        // equal and the failure would be invisible.
        lastError = nil
        lastErrorKind = .transient
        shutdownGuardedSession(clearError: true)
        invalidateCrossfadePreparation(clearReservation: true)
        resolveTask?.cancel()
        resolveTask = nil
        backgroundRemuxTask?.cancel()
        backgroundRemuxTask = nil
        prefetchManager.cancelPrefetch()
        crossfadeManager.cancelFade()
        cleanupCrossfadePlayer()
        isPlayingFromAutoplay = false
        if !fromQueue.isEmpty {
            queue = fromQueue
            currentIndex = fromQueue.firstIndex(where: { $0.id == song.id }) ?? 0
            autoplayQueue.removeAll()
            if shuffleEnabled { generateShuffledOrder() }
        }
        currentTrack = song
        loadAndPlay(song: song)
    }

    func playPause() {
        if let coordinator = guardedCoordinator,
            coordinator.state.phase != .idle
        {
            if coordinator.state.desiredPlaybackIntent == .playing {
                coordinator.send(.userPaused)
                userInitiatedPause = true
                player?.pause()
                isPlaying = false
            } else {
                coordinator.send(.userPlayed)
                userInitiatedPause = false
                if player?.currentItem != nil {
                    resumePlayer()
                    isPlaying = true
                }
            }
            return
        }
        guard let player else { return }
        if isPlaying {
            invalidateCrossfadePreparation(clearReservation: false)
            userInitiatedPause = true
            player.pause()
            isPlaying = false
            savePlaybackState()
        } else {
            userInitiatedPause = false
            resumePlayer()
            isPlaying = true
        }
        // The `isPlaying` didSet above mirrors playback state onto the
        // muted video layer — no manual sync needed here.
        nowPlayingManager.updatePlaybackState(
            isPlaying: isPlaying,
            currentTime: currentTime,
            rate: isPlaying ? Double(playbackSpeed) : 0.0
        )
    }

    func next() {
        shutdownGuardedSession(clearError: true)
        let reservedQueueIndex: Int?
        if let reservation = crossfadeReservation,
            isCrossfadeReservationValid(reservation),
            case .queue(let index) = reservation.destination
        {
            reservedQueueIndex = index
            commitReservedShuffleProgress(for: reservation)
        } else {
            reservedQueueIndex = nil
        }
        invalidateCrossfadePreparation(clearReservation: true)

        // Cancel any in-progress crossfade — user explicitly skipped
        crossfadeManager.cancelFade()
        cleanupCrossfadePlayer()
        resolveTask?.cancel()
        resolveTask = nil
        backgroundRemuxTask?.cancel()
        backgroundRemuxTask = nil
        recoveryService.resetRetry()

        // If currently playing from autoplay queue
        if isPlayingFromAutoplay {
            if !autoplayQueue.isEmpty {
                playNextFromAutoplay()
                return
            } else if repeatMode == .all && !queue.isEmpty {
                isPlayingFromAutoplay = false
                if shuffleEnabled { generateShuffledOrder() }
                currentIndex = shuffleEnabled ? (shuffledIndices.first ?? 0) : 0
            } else if onQueueExhausted != nil {
                onQueueExhausted?()
                return
            } else {
                isPlaying = false
                isPlayingFromAutoplay = false
                return
            }
        } else {
            guard !queue.isEmpty else { return }

            if shuffleEnabled {
                currentIndex = reservedQueueIndex ?? getNextShuffledIndex()
            } else {
                let nextIdx = currentIndex + 1
                if nextIdx >= queue.count {
                    // End of user queue in sequential mode
                    if repeatMode == .off && !autoplayQueue.isEmpty {
                        playNextFromAutoplay()
                        return
                    }
                    currentIndex = 0
                } else {
                    currentIndex = nextIdx
                }
            }
        }

        let song = queue[currentIndex]
        currentTrack = song
        currentTime = 0
        duration = 0

        // Use pre-fetched item if available for this song
        if let prefetched = prefetchManager.prefetchedPlayerItem,
            prefetchManager.prefetchedSongId == song.id
        {
            let fileURL = prefetchManager.prefetchedLocalFileURL
            prefetchManager.cancelPrefetch()
            cleanupPlayer()

            isStreamingMode = false
            localFileURL = fileURL
            isBuffering = true
            isPlaying = true
            userInitiatedPause = false

            configurePlayer(with: prefetched)
            setupPlayerItemObserver(prefetched)

            // Metadata write before activation + playback (D-2, D-3).
            if let songDuration = song.duration, songDuration > 0 {
                duration = TimeInterval(songDuration)
            }
            nowPlayingManager.updateNowPlayingInfo(song: song, duration: duration)

            // Lazy-activate the audio session (D-1).
            AudioSessionManager.activate()

            resumePlayer()
            applyAudioProcessing()
            recoveryService.startStallDetection()
            Log.audio.info("Using pre-fetched item for: \(song.title, privacy: .public)")
        } else {
            prefetchManager.cancelPrefetch()
            loadAndPlay(song: song)
        }
    }

    /// Deterministic local-only prefetch seam used by the guarded lifecycle tests.
    func prepareNextLocalItemForPlayback() {
        syncPrefetchDependencies()
        prefetchManager.prefetchNextTrack()
    }

    func previous() {
        invalidateCrossfadePreparation(clearReservation: true)
        // Cancel any in-progress crossfade — user explicitly went back
        crossfadeManager.cancelFade()
        cleanupCrossfadePlayer()
        resolveTask?.cancel()
        resolveTask = nil
        backgroundRemuxTask?.cancel()
        backgroundRemuxTask = nil
        prefetchManager.cancelPrefetch()
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        // If playing from autoplay, go back to last song in user queue
        if isPlayingFromAutoplay {
            isPlayingFromAutoplay = false
            let song = queue[currentIndex]
            currentTrack = song
            currentTime = 0
            duration = 0
            loadAndPlay(song: song)
            return
        }
        currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        let song = queue[currentIndex]
        currentTrack = song
        currentTime = 0
        duration = 0
        loadAndPlay(song: song)
    }

    private var isSeeking: Bool = false

    func seek(to time: TimeInterval) {
        // Seeking changes the playback timeline but not the selected next-track
        // candidate. Cancel any pending/active fade and allow a later trigger
        // to retry the same reservation.
        invalidateCrossfadePreparation(clearReservation: false)

        if let coordinator = guardedCoordinator,
            coordinator.state.phase != .idle,
            time.isFinite,
            time >= 0
        {
            coordinator.send(.requestSeek(targetSeconds: time))
            currentTime = time
            if let viewState = transferConsentViewState {
                transferConsentViewState = TransferConsentViewState(
                    token: viewState.token,
                    targetSeconds: time,
                    networkUpperBoundBytes: viewState.networkUpperBoundBytes,
                    temporaryStorageUpperBoundBytes: viewState.temporaryStorageUpperBoundBytes
                )
            }
            return
        }

        // In streaming mode (fMP4), AVPlayer cannot seek (empty stbl).
        // Queue the seek — it will be applied after handoff to local remuxed file.
        if isStreamingMode {
            Log.audio.info("Seek queued at \(time)s — waiting for background download to complete")
            pendingSeekTime = time
            currentTime = time
            isBuffering = true
            nowPlayingManager.updatePlaybackState(
                isPlaying: isPlaying, currentTime: time,
                rate: isPlaying ? Double(playbackSpeed) : 0.0
            )
            return
        }

        isBuffering = true
        Log.audio.debug("Seeking to \(time)s")

        guard let player = player, player.currentItem != nil else {
            Log.audio.warning("No player or item for seek")
            isBuffering = false
            return
        }

        // Remuxed standard MP4 has populated stbl (sample tables),
        // so AVPlayer seek(to:) works natively with byte-accurate random access.
        isSeeking = true
        player.pause()
        // Pause the muted video too — otherwise it keeps playing during the
        // scrub, accumulating drift. It will resume in the completion below.
        videoManager.videoPlayer?.pause()

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Skip if this seek was superseded by a newer one (finished=false)
                guard finished else { return }
                self.isSeeking = false
                self.currentTime = time
                Log.audio.debug("Seek completed: finished=\(finished, privacy: .public)")
                if self.isPlaying {
                    self.resumePlayer()
                }
                self.syncVideoToAudioTime(time)
                if self.isPlaying { self.videoManager.videoPlayer?.play() }
                self.isBuffering = false
                self.nowPlayingManager.updatePlaybackState(
                    isPlaying: self.isPlaying, currentTime: time,
                    rate: self.isPlaying ? Double(self.playbackSpeed) : 0.0
                )
            }
        }
    }

    func addToQueue(_ song: Song) {
        queue.append(song)
        if shuffleEnabled { regenerateShuffleForQueueChange() }
        savePlaybackState()
    }

    func addToQueue(songs: [Song]) {
        queue.append(contentsOf: songs)
        if shuffleEnabled { regenerateShuffleForQueueChange() }
        savePlaybackState()
    }

    // MARK: - Autoplay Queue Management

    func setAutoplayQueue(_ songs: [Song]) {
        autoplayQueue = songs
        savePlaybackState()
    }

    func appendToAutoplayQueue(_ songs: [Song]) {
        autoplayQueue.append(contentsOf: songs)
        savePlaybackState()
    }

    func clearAutoplayQueue() {
        autoplayQueue.removeAll()
        savePlaybackState()
    }

    /// Play the next song from the autoplay queue.
    func playNextFromAutoplay() {
        guard !autoplayQueue.isEmpty else { return }
        invalidateCrossfadePreparation(clearReservation: true)
        resolveTask?.cancel()
        resolveTask = nil
        backgroundRemuxTask?.cancel()
        backgroundRemuxTask = nil
        prefetchManager.cancelPrefetch()
        crossfadeManager.cancelFade()
        cleanupCrossfadePlayer()

        let song = autoplayQueue.removeFirst()
        isPlayingFromAutoplay = true
        currentTrack = song
        currentTime = 0
        duration = 0
        loadAndPlay(song: song)
        savePlaybackState()

        // Pre-fetch more when running low
        if autoplayQueue.count <= 2 {
            onQueueExhausted?()
        }
    }

    /// Skip to a specific index in the autoplay queue and start playing.
    func skipAutoplayTo(index: Int) {
        guard index < autoplayQueue.count else { return }
        autoplayQueue.removeFirst(index)
        playNextFromAutoplay()
    }

    func removeFromQueue(at index: Int) {
        guard index < queue.count else { return }
        prefetchManager.cancelPrefetch()
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        }
        savePlaybackState()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        prefetchManager.cancelPrefetch()
        let currentId = currentTrack?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let id = currentId, let newIdx = queue.firstIndex(where: { $0.id == id }) {
            currentIndex = newIdx
        }
        if shuffleEnabled { regenerateShuffleForQueueChange() }
        savePlaybackState()
    }

    /// Insert a song at a specific queue position without changing playback.
    /// Clamps `index` to `[0, queue.count]`. If the song is already in the queue,
    /// it is moved (not duplicated). Adjusts `currentIndex` so the
    /// currently-playing track keeps its identity-based position.
    func insertInQueue(_ song: Song, at index: Int) {
        let clamped = max(0, min(index, queue.count))
        let currentId = currentTrack?.id

        // Dedupe: if song is already in the queue, remove its existing entry first.
        if let existing = queue.firstIndex(where: { $0.id == song.id }) {
            // Don't move the currently-playing song.
            if existing == currentIndex { return }
            queue.remove(at: existing)
            // Account for the shift when computing final insert position.
            let adjusted = existing < clamped ? clamped - 1 : clamped
            queue.insert(song, at: max(0, min(adjusted, queue.count)))
        } else {
            queue.insert(song, at: clamped)
        }

        // Re-anchor currentIndex to the still-playing track by id.
        if let id = currentId, let newIdx = queue.firstIndex(where: { $0.id == id }) {
            currentIndex = newIdx
        }

        if shuffleEnabled { regenerateShuffleForQueueChange() }
        savePlaybackState()
    }

    func resumePlayer() {
        player?.rate = playbackSpeed
    }

    /// Persist current playback state (called on significant state changes)
    func savePlaybackState() {
        playbackStatePersistence?.save(
            queue: queue,
            autoplayQueue: autoplayQueue,
            currentIndex: currentIndex,
            currentTime: currentTime,
            isPlaying: isPlaying,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode.rawValue
        )
    }

    /// Restore queue and position from persisted state (does NOT auto-play)
    func restorePlaybackState(_ state: PlaybackStatePersistence.PersistedPlaybackState) {
        self.queue = state.queue
        self.autoplayQueue = state.autoplayQueue
        self.currentIndex = state.currentIndex
        self.shuffleEnabled = state.shuffleEnabled
        if let mode = RepeatMode(rawValue: state.repeatMode) {
            self.repeatMode = mode
        }
        // Set current track so the UI shows the restored song, but don't trigger playback
        if state.currentIndex >= 0, state.currentIndex < state.queue.count {
            self.currentTrack = state.queue[state.currentIndex]
        }
    }

    // MARK: - Fisher-Yates Shuffle

    /// Generate a shuffled order of queue indices using Fisher-Yates algorithm.
    /// Places the current index at position 0 so the current song isn't disrupted.
    private func generateShuffledOrder() {
        guard !queue.isEmpty else {
            shuffledIndices = []
            shufflePosition = 0
            recentlyPlayedIndices = []
            return
        }
        shuffledIndices = makeShuffledIndices()
        shufflePosition = 0
        recentlyPlayedIndices = [currentIndex]
    }

    private func makeShuffledIndices() -> [Int] {
        var indices = Array(0..<queue.count)
        guard indices.count > 1 else { return indices }
        for i in stride(from: indices.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            indices.swapAt(i, j)
        }
        // Put current index at beginning so we don't immediately change song
        if let pos = indices.firstIndex(of: currentIndex) {
            indices.swapAt(0, pos)
        }
        return indices
    }

    private func makeNextShuffleSelection() -> (index: Int, progress: ShuffleProgress)? {
        var indices = shuffledIndices
        var position = shufflePosition
        var recent = recentlyPlayedIndices

        if indices.isEmpty {
            indices = makeShuffledIndices()
            guard !indices.isEmpty else { return nil }
            position = 0
            recent = [currentIndex]
        }

        if indices.count == 1 {
            return (
                index: indices[0],
                progress: ShuffleProgress(
                    indices: indices,
                    position: 0,
                    recentlyPlayedIndices: [indices[0]]
                )
            )
        }

        position += 1
        if position >= indices.count {
            indices = makeShuffledIndices()
            guard indices.count > 1 else { return nil }
            position = 1  // Skip position 0 (current song)
            recent = [currentIndex]
        }

        var candidate = indices[position]

        // No-repeat-recent: try to avoid last 5 played indices when queue is large enough
        if recent.contains(candidate) && queue.count > 5 {
            let startPosition = position
            var attempts = 0
            repeat {
                position += 1
                if position >= indices.count {
                    position = 0
                }
                candidate = indices[position]
                attempts += 1
            } while recent.contains(candidate)
                && attempts < indices.count
                && position != startPosition
        }

        recent.append(candidate)
        if recent.count > 5 {
            recent.removeFirst()
        }

        return (
            index: candidate,
            progress: ShuffleProgress(
                indices: indices,
                position: position,
                recentlyPlayedIndices: recent
            )
        )
    }

    private func applyShuffleProgress(_ progress: ShuffleProgress) {
        shuffledIndices = progress.indices
        shufflePosition = progress.position
        recentlyPlayedIndices = progress.recentlyPlayedIndices
    }

    /// Get the next index from the shuffled order, avoiding recent repeats.
    private func getNextShuffledIndex() -> Int {
        guard let selection = makeNextShuffleSelection() else { return 0 }
        applyShuffleProgress(selection.progress)
        return selection.index
    }

    /// Regenerate shuffle order when queue changes (add/remove/move) while preserving current position.
    private func regenerateShuffleForQueueChange() {
        guard shuffleEnabled, !queue.isEmpty else { return }
        let currentSongId = currentTrack?.id
        generateShuffledOrder()
        if let id = currentSongId, let idx = queue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            if let pos = shuffledIndices.firstIndex(of: idx) {
                shuffledIndices.swapAt(0, pos)
            }
            shufflePosition = 0
        }
    }

    /// Syncs dynamic state into the prefetch manager before a prefetch operation.
    private func syncPrefetchDependencies() {
        prefetchManager.queue = queue
        prefetchManager.currentIndex = currentIndex
        prefetchManager.shuffleEnabled = shuffleEnabled
        prefetchManager.repeatMode = repeatMode
        prefetchManager.audioCacheManager = audioCacheManager
        prefetchManager.downloadManager = downloadManager
    }

    // MARK: - Private

    private func loadAndPlay(song: Song) {
        shutdownGuardedSession(clearError: true)
        var songToPlay = song
        lastError = nil
        lastErrorKind = .transient
        isReconnecting = false
        streamRecoveryAttemptCount = 0
        recoveryService.resetRetry()
        crossfadeManager.resetTrigger()

        // Check if existing stream URL is likely expired (YouTube URLs expire ~6 hours)
        if songToPlay.streamURL != nil, let resolvedAt = streamResolvedAt,
            Date().timeIntervalSince(resolvedAt) > 6 * 3600
        {
            Log.audio.warning("Stream URL likely expired, re-resolving...")
            songToPlay.streamURL = nil
            songToPlay.streamContentLength = nil
            if currentIndex < queue.count {
                queue[currentIndex].streamURL = nil
                queue[currentIndex].streamContentLength = nil
            }
        }

        // S1: Offline-first ordering. Before invoking the network resolver,
        // short-circuit to a downloaded copy or a cached remuxed file if one
        // exists. `performLoadAndPlay` already prefers these branches, so we
        // bypass the resolver entirely and let it handle local playback.
        // This restores playback while offline (no resolver call required).
        let hasDownloadedFile = downloadManager?.localFileURL(songId: songToPlay.id) != nil
        let hasCachedFile =
            !hasDownloadedFile
            && (audioCacheManager?.getFile(for: songToPlay.id) != nil)
        let hasBundledFile =
            !hasDownloadedFile
            && !hasCachedFile
            && (Bundle.main.url(forResource: songToPlay.id, withExtension: "m4a") != nil)

        if hasDownloadedFile || hasCachedFile || hasBundledFile {
            // Cancel any in-flight resolver task (re-entrancy guard).
            resolveTask?.cancel()
            resolveTask = nil
            Log.audio.info(
                "Offline-first: using local file for \(songToPlay.id, privacy: .public) (downloaded=\(hasDownloadedFile), cached=\(hasCachedFile), bundled=\(hasBundledFile))"
            )
            performLoadAndPlay(song: songToPlay)
            return
        }

        if guardedConfiguration != nil {
            startGuardedPlayback(song: songToPlay, initialPosition: 0)
            return
        }

        if songToPlay.streamURL == nil, let resolver = streamURLResolver {
            resolveTask?.cancel()
            resolveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    self.isBuffering = true
                    Log.audio.info("Resolving stream URL for: \(songToPlay.id, privacy: .public)")
                    let result = try await resolver(songToPlay.id)
                    guard !Task.isCancelled else { return }
                    Log.audio.info("Got stream URL: \(result.url.prefix(80), privacy: .public)...")
                    songToPlay.streamURL = result.url
                    songToPlay.streamContentLength = result.contentLength
                    self.streamResolvedAt = Date()
                    self.currentTrack = songToPlay
                    if self.currentIndex < self.queue.count {
                        self.queue[self.currentIndex].streamURL = result.url
                        self.queue[self.currentIndex].streamContentLength = result.contentLength
                    }
                    self.performLoadAndPlay(song: songToPlay)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isBuffering = false
                    self.lastFailedSongId = songToPlay.id
                    if let innerTubeError = error as? InnerTubeError, innerTubeError.isPermanent {
                        self.lastErrorKind = .permanent
                    } else {
                        self.lastErrorKind = .transient
                    }
                    self.lastError = error.localizedDescription
                    Log.audio.error(
                        "Resolving stream URL for \(songToPlay.id, privacy: .public): \(error, privacy: .public)"
                    )
                    #if DEBUG
                    #endif
                }
            }
        } else {
            performLoadAndPlay(song: songToPlay)
        }
    }

    private func startGuardedPlayback(
        song: Song,
        initialPosition: TimeInterval
    ) {
        guard let configuration = guardedConfiguration else { return }
        shutdownGuardedSession(clearError: true)
        guardedResolvedContext = nil
        guardedConsentContext = nil
        guardedDownloadedResources.removeAll()
        guardedPreparedRemuxContext = nil
        guardedActiveRequest = nil
        guardedResolutionFailureCount = 0
        transferConsentViewState = nil
        guardedPlaybackError = nil
        isPlaying = false
        isBuffering = true

        guard guardedApplicationIsActive, guardedPhoneUIAvailable else {
            guardedPlaybackError = .continueOnPhone
            isBuffering = false
            return
        }

        let tokens = ActivePlaybackTokens.freshSession(
            source: .legacyDownloadRemux
        )
        let ownerID = UUID()
        guardedOwnerID = ownerID
        guardedQualificationTokens = tokens
        let coordinatorBox = GuardedCoordinatorBox()
        let coordinator = PlaybackCoordinator(
            effectOperation: { [weak self, coordinatorBox] effect in
                switch effect {
                case .releaseStorageReservation(let reservationID):
                    await configuration.transferGate.releaseReservation(reservationID)
                    return nil
                case .releaseReservationAndEvaluateFullResourceTransferGate(
                    let oldReservationID,
                    let attempt
                ):
                    await configuration.transferGate.releaseReservation(oldReservationID)
                    guard let self,
                        let coordinator = coordinatorBox.coordinator,
                        self.isCurrentGuardedOwner(ownerID, coordinator: coordinator)
                    else {
                        return nil
                    }
                    return await self.evaluateGuardedTransferGate(
                        attempt,
                        ownerID: ownerID,
                        coordinator: coordinator,
                        configuration: configuration
                    )
                default:
                    break
                }
                guard let self else { return nil }
                guard let coordinator = coordinatorBox.coordinator else {
                    return nil
                }
                return await self.performGuardedPlaybackEffect(
                    effect,
                    ownerID: ownerID,
                    coordinator: coordinator,
                    configuration: configuration
                )
            },
            monotonicClock: configuration.monotonicClock,
            watchdogScheduler: configuration.watchdogScheduler,
            networkSnapshot: guardedLatestNetworkSnapshot
                ?? configuration.initialNetworkSnapshot
        )
        coordinatorBox.coordinator = coordinator
        guardedCoordinator = coordinator
        coordinator.send(
            .replaceSession(
                sessionID: tokens.sessionID,
                desiredIntent: .playing,
                initialPosition: initialPosition
            )
        )
    }

    private func performGuardedPlaybackEffect(
        _ effect: PlaybackEffect,
        ownerID: UUID,
        coordinator: PlaybackCoordinator,
        configuration: GuardedLegacyPlaybackConfiguration
    ) async -> PlaybackEvent? {
        if case .releaseStorageReservation(let reservationID) = effect {
            await configuration.transferGate.releaseReservation(reservationID)
            return nil
        }
        if case .releaseReservationAndEvaluateFullResourceTransferGate(
            let oldReservationID,
            let attempt
        ) = effect {
            await configuration.transferGate.releaseReservation(oldReservationID)
            guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
                return nil
            }
            return await evaluateGuardedTransferGate(
                attempt,
                ownerID: ownerID,
                coordinator: coordinator,
                configuration: configuration
            )
        }
        guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
            return nil
        }

        switch effect {
        case .resolveDescriptor(let sessionID):
            guard let song = currentTrack,
                let tokens = guardedQualificationTokens,
                tokens.sessionID == sessionID
            else {
                return nil
            }
            do {
                let descriptor = try await configuration.descriptorResolver(song.id)
                try Task.checkCancellation()
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
                    return nil
                }
                let qualified = try await configuration.descriptorQualifier.qualify(
                    descriptor: descriptor,
                    tokens: tokens
                )
                try Task.checkCancellation()
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
                    return nil
                }
                guardedResolvedContext = GuardedResolvedContext(
                    descriptor: descriptor,
                    qualified: qualified
                )
                guardedResolutionFailureCount = 0
                return .descriptorResolved(
                    sessionID: sessionID,
                    sources: PlaybackSourceAvailability(
                        hasExplicitDownload: false,
                        hasValidLocalRemux: false,
                        rangeEligible: configuration.isRangeEligible(descriptor),
                        generationFingerprint: qualified.generationScope.localFingerprint
                    )
                )
            } catch is CancellationError {
                return nil
            } catch {
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
                    return nil
                }
                let qualificationError = error as? LegacyDescriptorQualificationError
                    ?? .cannotEstablishValidatedGeneration
                guardedResolutionFailureCount += 1
                if guardedResolutionFailureCount >= 2 {
                    guardedPlaybackError = .descriptorQualificationFailed(
                        qualificationError
                    )
                    isPlaying = false
                    isBuffering = false
                }
                return .descriptorResolutionFailed(
                    sessionID: sessionID,
                    category: .resolution
                )
            }

        case .evaluateFullResourceTransferGate(let attempt):
            return await evaluateGuardedTransferGate(
                attempt,
                ownerID: ownerID,
                coordinator: coordinator,
                configuration: configuration
            )

        case .releaseReservationAndEvaluateFullResourceTransferGate(
            _, _
        ):
            return nil

        case .presentFullTransferConsent(let attempt):
            guard let context = guardedConsentContext,
                context.attempt.id == attempt.id
            else {
                return nil
            }
            guard guardedApplicationIsActive, guardedPhoneUIAvailable else {
                guardedConsentContext = nil
                transferConsentViewState = nil
                guardedPlaybackError = .continueOnPhone
                isPlaying = false
                isBuffering = false
                return .transferConsentDeclined(attempt)
            }
            transferConsentViewState = TransferConsentViewState(
                token: attempt.request.token,
                targetSeconds: attempt.request.targetSeconds,
                networkUpperBoundBytes: context.estimate.networkUpperBoundBytes,
                temporaryStorageUpperBoundBytes: context.estimate
                    .temporaryStorageUpperBoundBytes
            )
            isPlaying = false
            return nil

        case .releaseStorageReservation(let reservationID):
            await configuration.transferGate.releaseReservation(reservationID)
            return nil

        case .startLegacyTransfer(let attempt):
            guard let resolved = guardedResolvedContext,
                currentTrack != nil
            else {
                return nil
            }
            guard let tokens = ActivePlaybackTokens.validatedLegacyFallback(attempt) else {
                guardedPlaybackError = .descriptorQualificationFailed(
                    .generationScopeMismatch
                )
                isPlaying = false
                isBuffering = false
                return .legacyTransferFailed(
                    attempt,
                    currentNetwork: coordinator.state.networkSnapshot,
                    failure: .localArtifact
                )
            }
            guard case .attemptOnly(let sessionID, let sourceAttemptID, _) =
                resolved.qualified.generationScope,
                sessionID == tokens.sessionID,
                sourceAttemptID == tokens.currentSourceAttempt.id
            else {
                guardedPlaybackError = .descriptorQualificationFailed(
                    .generationScopeMismatch
                )
                isPlaying = false
                isBuffering = false
                return .legacyTransferFailed(
                    attempt,
                    currentNetwork: coordinator.state.networkSnapshot,
                    failure: .localArtifact
                )
            }
            let request = LegacyPlaybackRequest(
                descriptor: resolved.descriptor,
                validatedContentLength: resolved.qualified.validatedContentLength,
                targetSeconds: attempt.targetSeconds,
                intent: attempt.intent,
                reservationID: attempt.reservationID,
                tokens: tokens
            )
            guardedActiveRequest = request
            let startedSnapshot = coordinator.state.networkSnapshot
            do {
                let downloaded = try await configuration.legacyDriver.download(
                    request,
                    progressSink: { [weak self] progress in
                        await self?.forwardGuardedLegacyProgress(progress)
                    }
                )
                guard !Task.isCancelled,
                    isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    case .legacyDownloading(let currentAttempt) = coordinator.state.phase,
                    currentAttempt.sourceAttempt == attempt.sourceAttempt,
                    currentAttempt.reservationID == attempt.reservationID
                else {
                    await configuration.legacyDriver.cancel(request)
                    return nil
                }
                guardedDownloadedResources[attempt.sourceAttempt.id] = downloaded
                if currentAttempt.targetSeconds == 0,
                    coordinator.state.latestRequestedTarget == nil,
                    coordinator.state.desiredPlaybackIntent == .playing,
                    let song = currentTrack
                {
                    configuration.hostCommandSink(.playRawArtifact)
                    configuration.artifactHost.installArtifact(
                        downloaded.rawURL,
                        song: song,
                        isRaw: true
                    )
                    configuration.artifactHost.play()
                    isStreamingMode = true
                    localFileURL = downloaded.rawURL
                    isPlaying = true
                }
                return .legacyTransferCompleted(
                    attempt,
                    trackDurationSeconds: TimeInterval(currentTrack?.duration ?? 0)
                )
            } catch is CancellationError {
                await configuration.legacyDriver.cancel(request)
                return nil
            } catch let error as LegacyPlaybackDriverError {
                let currentNetwork = await configuration.currentNetworkSnapshot()
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
                    return nil
                }
                if case .transportRequiresRegate = error {
                    if isMetered(startedSnapshot) {
                        guardedPlaybackError = .legacyTransportFailed
                        isPlaying = false
                        isBuffering = false
                    }
                    return .legacyTransferFailed(
                        attempt,
                        currentNetwork: currentNetwork,
                        failure: .transport
                    )
                }
                guardedPlaybackError = .legacyTransportFailed
                isPlaying = false
                isBuffering = false
                return .legacyTransferFailed(
                    attempt,
                    currentNetwork: currentNetwork,
                    failure: .localArtifact
                )
            } catch {
                let currentNetwork = await configuration.currentNetworkSnapshot()
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
                    return nil
                }
                guardedPlaybackError = .legacyTransportFailed
                isPlaying = false
                isBuffering = false
                return .legacyTransferFailed(
                    attempt,
                    currentNetwork: currentNetwork,
                    failure: .localArtifact
                )
            }

        case .startLegacyRemux(let attempt, _),
            .retryLegacyRemux(let attempt, _):
            configuration.legacyRemuxWillBegin(attempt)
            guard !Task.isCancelled,
                isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                case .legacyRemuxing(let currentAttempt) = coordinator.state.phase,
                currentAttempt == attempt
            else {
                return nil
            }
            guard let resource = guardedDownloadedResources[attempt.sourceAttempt.id]
            else {
                return .legacyRemuxFailed(attempt)
            }
            do {
                _ = try await configuration.legacyDriver.remux(
                    resource,
                    progressSink: { [weak self] progress in
                        await self?.forwardGuardedLegacyProgress(progress)
                    }
                )
                guard !Task.isCancelled,
                    isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    case .legacyRemuxing(let currentAttempt) = coordinator.state.phase,
                    currentAttempt.sourceAttempt == attempt.sourceAttempt,
                    let song = currentTrack
                else {
                    await configuration.legacyDriver.cancel(resource.request)
                    return nil
                }
                let observedRawPosition = configuration.artifactHost.currentPosition
                let handoffTarget: TimeInterval
                if let explicitTarget = coordinator.state.latestRequestedTarget {
                    handoffTarget = explicitTarget
                } else if currentAttempt.targetSeconds > 0 {
                    handoffTarget = currentAttempt.targetSeconds
                } else {
                    handoffTarget = max(0, observedRawPosition)
                }
                if abs(handoffTarget - currentAttempt.targetSeconds) > 0.001
                    || (coordinator.state.latestRequestedTarget == nil
                        && handoffTarget > 0)
                {
                    coordinator.send(.requestSeek(targetSeconds: handoffTarget))
                }
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    case .legacyRemuxing(let latestAttempt) = coordinator.state.phase,
                    latestAttempt.sourceAttempt == attempt.sourceAttempt
                else {
                    await configuration.legacyDriver.cancel(resource.request)
                    return nil
                }
                guardedPreparedRemuxContext = GuardedPreparedRemuxContext(
                    fallbackSourceAttemptID: attempt.sourceAttempt.id,
                    resource: resource,
                    song: song,
                    isInstalled: false
                )
                guardedRemuxFailureCounts.removeValue(forKey: attempt.sourceAttempt.id)
                isBuffering = false
                return .legacyRemuxSucceeded(attempt)
            } catch is CancellationError {
                await configuration.legacyDriver.cancel(resource.request)
                return nil
            } catch {
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator) else {
                    await configuration.legacyDriver.cancel(resource.request)
                    return nil
                }
                let failureCount = (guardedRemuxFailureCounts[attempt.sourceAttempt.id] ?? 0) + 1
                guardedRemuxFailureCounts[attempt.sourceAttempt.id] = failureCount
                if failureCount >= 2 {
                    guardedPlaybackError = .legacyRemuxFailed
                    isPlaying = false
                    isBuffering = false
                    configuration.artifactHost.pause()
                    guardedDownloadedResources.removeValue(
                        forKey: attempt.sourceAttempt.id
                    )
                    await configuration.legacyDriver.dispose(resource)
                }
                return .legacyRemuxFailed(attempt)
            }

        case .startSource(let attempt):
            guard attempt.source == .remuxCache else {
                guardedPlaybackError = .rangePathUnavailable
                isPlaying = false
                isBuffering = false
                return nil
            }
            guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                case .preparing(let currentAttempt) = coordinator.state.phase,
                currentAttempt == attempt
            else {
                return nil
            }
            guard var prepared = guardedPreparedRemuxContext else {
                guardedPlaybackError = .legacyRemuxFailed
                isPlaying = false
                isBuffering = false
                return nil
            }
            guardedPreparedRemuxContext = nil
            guardedDownloadedResources.removeValue(
                forKey: prepared.fallbackSourceAttemptID
            )
            guardedOwnedResources[attempt.id] = prepared.resource
            await configuration.legacyDriver.finish(prepared.resource)
            guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                case .preparing(let currentAttempt) = coordinator.state.phase,
                currentAttempt == attempt
            else {
                await disposeClaimedGuardedResourceIfPresent(
                    sourceAttemptID: attempt.id,
                    resource: prepared.resource,
                    configuration: configuration
                )
                return nil
            }
            if !prepared.isInstalled {
                configuration.hostCommandSink(.installRemuxedArtifact)
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    case .preparing(let currentAttempt) = coordinator.state.phase,
                    currentAttempt == attempt,
                    guardedOwnedResources[attempt.id] == prepared.resource
                else {
                    await disposeClaimedGuardedResourceIfPresent(
                        sourceAttemptID: attempt.id,
                        resource: prepared.resource,
                        configuration: configuration
                    )
                    return nil
                }
                configuration.artifactHost.installArtifact(
                    prepared.resource.remuxedURL,
                    song: prepared.song,
                    isRaw: false
                )
                prepared.isInstalled = true
            }
            isStreamingMode = false
            localFileURL = prepared.resource.remuxedURL
            if coordinator.state.desiredPlaybackIntent == .playing {
                configuration.artifactHost.play()
                isPlaying = true
            } else {
                configuration.artifactHost.pause()
                isPlaying = false
            }
            isBuffering = false
            return .sourceBecamePlayable(attempt)

        case .startSeek(let attempt):
            guard attempt.sourceAttempt.source == .remuxCache else {
                guardedPlaybackError = .rangePathUnavailable
                isPlaying = false
                isBuffering = false
                return nil
            }
            guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                case .seeking(let currentAttempt) = coordinator.state.phase,
                currentAttempt == attempt
            else {
                return nil
            }
            if var prepared = guardedPreparedRemuxContext,
                !prepared.isInstalled
            {
                guardedPreparedRemuxContext = nil
                guardedDownloadedResources.removeValue(
                    forKey: prepared.fallbackSourceAttemptID
                )
                guardedOwnedResources[attempt.sourceAttempt.id] = prepared.resource
                await configuration.legacyDriver.finish(prepared.resource)
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    case .seeking(let currentAttempt) = coordinator.state.phase,
                    currentAttempt == attempt,
                    guardedOwnedResources[attempt.sourceAttempt.id]
                        == prepared.resource
                else {
                    await disposeClaimedGuardedResourceIfPresent(
                        sourceAttemptID: attempt.sourceAttempt.id,
                        resource: prepared.resource,
                        configuration: configuration
                    )
                    return nil
                }
                configuration.hostCommandSink(.installRemuxedArtifact)
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    case .seeking(let currentAttempt) = coordinator.state.phase,
                    currentAttempt == attempt,
                    guardedOwnedResources[attempt.sourceAttempt.id]
                        == prepared.resource
                else {
                    await disposeClaimedGuardedResourceIfPresent(
                        sourceAttemptID: attempt.sourceAttempt.id,
                        resource: prepared.resource,
                        configuration: configuration
                    )
                    return nil
                }
                configuration.artifactHost.installArtifact(
                    prepared.resource.remuxedURL,
                    song: prepared.song,
                    isRaw: false
                )
                prepared.isInstalled = true
                isStreamingMode = false
                localFileURL = prepared.resource.remuxedURL
            }
            guard guardedPreparedRemuxContext != nil
                || guardedOwnedResources[attempt.sourceAttempt.id] != nil
            else {
                guardedPlaybackError = .legacyRemuxFailed
                isPlaying = false
                isBuffering = false
                return nil
            }
            guardedPendingArtifactOwners.insert(ownerID)
            defer { guardedPendingArtifactOwners.remove(ownerID) }
            configuration.hostCommandSink(
                .seekLocalArtifact(targetSeconds: attempt.targetSeconds)
            )
            guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                case .seeking(let currentAttempt) = coordinator.state.phase,
                currentAttempt == attempt
            else {
                if let resource = guardedOwnedResources[attempt.sourceAttempt.id] {
                    await disposeClaimedGuardedResourceIfPresent(
                        sourceAttemptID: attempt.sourceAttempt.id,
                        resource: resource,
                        configuration: configuration
                    )
                }
                return nil
            }
            let confirmedPosition = await configuration.artifactHost.seek(
                to: attempt.targetSeconds
            )
            guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                case .seeking(let currentAttempt) = coordinator.state.phase,
                currentAttempt == attempt
            else {
                if let resource = guardedOwnedResources[attempt.sourceAttempt.id] {
                    await disposeClaimedGuardedResourceIfPresent(
                        sourceAttemptID: attempt.sourceAttempt.id,
                        resource: resource,
                        configuration: configuration
                    )
                }
                return nil
            }
            guard let confirmedPosition,
                abs(confirmedPosition - attempt.targetSeconds) <= 0.5
            else {
                guardedPlaybackError = .legacyRemuxFailed
                isPlaying = false
                isBuffering = false
                return nil
            }
            currentTime = confirmedPosition
            return .seekPrepared(attempt)

        case .startSeekVerification(let attempt):
            guard attempt.sourceAttempt.source == .remuxCache else {
                guardedPlaybackError = .rangePathUnavailable
                isPlaying = false
                isBuffering = false
                return nil
            }
            let confirmedPosition = configuration.artifactHost.currentPosition
            guard confirmedPosition.isFinite,
                confirmedPosition >= 0,
                abs(confirmedPosition - attempt.targetSeconds) <= 0.5
            else {
                guardedPlaybackError = .legacyRemuxFailed
                isPlaying = false
                isBuffering = false
                return nil
            }
            if let prepared = guardedPreparedRemuxContext {
                await configuration.legacyDriver.finish(prepared.resource)
                guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                    case .verifyingSeek(let currentAttempt) = coordinator.state.phase,
                    currentAttempt == attempt
                else {
                    await configuration.legacyDriver.dispose(prepared.resource)
                    return nil
                }
                guardedDownloadedResources.removeValue(
                    forKey: prepared.fallbackSourceAttemptID
                )
                guardedOwnedResources[attempt.sourceAttempt.id] = prepared.resource
                guardedPreparedRemuxContext = nil
            }
            currentTime = confirmedPosition
            if coordinator.state.desiredPlaybackIntent == .playing {
                configuration.artifactHost.play()
                isPlaying = true
            } else {
                configuration.artifactHost.pause()
                isPlaying = false
            }
            isBuffering = false
            return .seekVerified(
                attempt,
                confirmedPosition: confirmedPosition
            )

        case .resumeSource(let attempt):
            guard attempt.source == .remuxCache else { return nil }
            configuration.artifactHost.play()
            isPlaying = true
            return nil

        case .cancelAllEffects, .cancelAllEffectsAndReleaseLegacy,
            .cancelSeekEffects, .cancelActiveRangeMonitor, .cancelTransferGate,
            .monitorActiveRange, .retryRangeTransport,
            .retrySeekUpstream:
            return nil
        }
    }

    private func evaluateGuardedTransferGate(
        _ attempt: PlaybackTransferGateAttempt,
        ownerID: UUID,
        coordinator: PlaybackCoordinator,
        configuration: GuardedLegacyPlaybackConfiguration
    ) async -> PlaybackEvent? {
        guard isCurrentGuardedOwner(ownerID, coordinator: coordinator),
            let descriptor = guardedResolvedContext?.descriptor,
            let qualificationTokens = ActivePlaybackTokens
                .validatedLegacyGateAttempt(attempt)
        else {
            return nil
        }
        guardedPendingGateAttempts.insert(attempt.id)
        defer { guardedPendingGateAttempts.remove(attempt.id) }
        let qualified: QualifiedLegacyDescriptor
        do {
            qualified = try await configuration.descriptorQualifier.qualify(
                descriptor: descriptor,
                tokens: qualificationTokens
            )
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled,
                isCurrentGuardedOwner(ownerID, coordinator: coordinator),
                coordinator.state.pendingTransferGateAttempt?.id == attempt.id
            else {
                return nil
            }
            guardedPlaybackError = .descriptorQualificationFailed(
                error as? LegacyDescriptorQualificationError
                    ?? .cannotEstablishValidatedGeneration
            )
            isPlaying = false
            isBuffering = false
            return .fullTransferGateDenied(
                attempt,
                denial: PlaybackTransferGateDenial(category: .resolution)
            )
        }
        guard !Task.isCancelled,
            isCurrentGuardedOwner(ownerID, coordinator: coordinator),
            coordinator.state.pendingTransferGateAttempt?.id == attempt.id
        else {
            return nil
        }
        guardedResolvedContext = GuardedResolvedContext(
            descriptor: descriptor,
            qualified: qualified
        )
        guard let request = makeFullTransferRequest(
            for: attempt,
            qualified: qualified
        ) else {
            return nil
        }
        let currentNetwork = await configuration.currentNetworkSnapshot()
        guard !Task.isCancelled,
            isCurrentGuardedOwner(ownerID, coordinator: coordinator),
            coordinator.state.pendingTransferGateAttempt?.id == attempt.id
        else {
            return nil
        }
        await configuration.transferGate.updateNetwork(currentNetwork)
        guard !Task.isCancelled,
            isCurrentGuardedOwner(ownerID, coordinator: coordinator),
            coordinator.state.pendingTransferGateAttempt?.id == attempt.id
        else {
            return nil
        }
        let decision = await configuration.transferGate.evaluate(
            request,
            consentGrant: nil
        )
        guard !Task.isCancelled,
            isCurrentGuardedOwner(ownerID, coordinator: coordinator),
            coordinator.state.pendingTransferGateAttempt?.id == attempt.id
        else {
            if case .allow(let reservationID) = decision {
                await configuration.transferGate.releaseReservation(reservationID)
            }
            return nil
        }
        switch decision {
        case .allow(let reservationID):
            guardedConsentContext = nil
            transferConsentViewState = nil
            return .fullTransferGateAllowed(
                attempt,
                reservationID: reservationID
            )
        case .requireTransferConsent(let estimate, _, let challenge):
            guardedConsentContext = GuardedConsentContext(
                attempt: attempt,
                challenge: challenge,
                estimate: estimate
            )
            return .fullTransferGateRequiresConsent(attempt)
        case .deny(let denial):
            guardedPlaybackError = .policyDenied(denial)
            isPlaying = false
            isBuffering = false
            return .fullTransferGateDenied(
                attempt,
                denial: PlaybackTransferGateDenial(
                    category: denial == .offline ? .transport : .storage
                )
            )
        }
    }

    private func makeFullTransferRequest(
        for attempt: PlaybackTransferGateAttempt,
        qualified explicitQualification: QualifiedLegacyDescriptor? = nil
    ) -> FullResourceTransferRequest? {
        guard let qualified = explicitQualification ?? guardedResolvedContext?.qualified
        else { return nil }
        return FullResourceTransferRequest(
            sessionID: attempt.request.sourceAttempt.sessionID,
            actionID: attempt.request.token.actionID,
            initialGeneration: qualified.generationScope,
            failureCategory: attempt.request.token.failureCategory,
            intent: attempt.request.token.intent,
            validatedContentLength: qualified.validatedContentLength,
            latestSeekTargetSeconds: attempt.request.targetSeconds
        )
    }

    private func handleAcceptedConsentDecision(
        _ decision: FullResourceTransferDecision,
        attempt: PlaybackTransferGateAttempt,
        coordinator: PlaybackCoordinator
    ) {
        switch decision {
        case .allow(let reservationID):
            guardedPlaybackError = nil
            coordinator.send(
                .transferConsentAccepted(
                    attempt,
                    reservationID: reservationID
                )
            )
        case .deny(let denial):
            guardedPlaybackError = .policyDenied(denial)
            isPlaying = false
            isBuffering = false
            coordinator.send(
                .fullTransferGateDenied(
                    attempt,
                    denial: PlaybackTransferGateDenial(category: .storage)
                )
            )
        case .requireTransferConsent:
            guardedPlaybackError = .policyDenied(.consentChallengeInvalidated)
            isPlaying = false
            isBuffering = false
            coordinator.send(
                .fullTransferGateDenied(
                    attempt,
                    denial: PlaybackTransferGateDenial(category: .transport)
                )
            )
        }
    }

    private func forwardGuardedLegacyProgress(
        _ progress: LegacyPlaybackProgress
    ) {
        guard let coordinator = guardedCoordinator,
            let request = guardedActiveRequest,
            request.tokens == progress.tokens,
            let watchdogToken = coordinator.activeWatchdogTokens.first(where: {
                $0.matches(request.tokens.currentSourceAttempt)
            })
        else {
            return
        }
        switch progress {
        case .validatedResponseBodyBytes(_, let totalUniqueBytes):
            coordinator.receiveWatchdogSignal(
                .validatedResponseBodyBytes(totalUniqueBytes: totalUniqueBytes),
                token: watchdogToken
            )
        case .remuxOutputBytes(_, let totalBytes):
            coordinator.receiveWatchdogSignal(
                .remuxOutputBytes(totalBytes: totalBytes),
                token: watchdogToken
            )
        }
    }

    fileprivate var guardedObservedPosition: TimeInterval {
        let observed = player?.currentTime().seconds ?? currentTime
        return observed.isFinite && observed >= 0 ? observed : max(0, currentTime)
    }

    fileprivate func installGuardedHostArtifact(
        _ url: URL,
        song: Song,
        isRaw: Bool
    ) {
        installGuardedArtifact(url, song: song, isRaw: isRaw, autoplay: false)
    }

    fileprivate func physicallySeekGuardedHostArtifact(
        to targetSeconds: TimeInterval
    ) async -> TimeInterval? {
        guard targetSeconds.isFinite, targetSeconds >= 0, let player else {
            return nil
        }
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let finished = await withCheckedContinuation { continuation in
            player.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                continuation.resume(returning: finished)
            }
        }
        guard finished else { return nil }
        let observed = player.currentTime().seconds
        guard observed.isFinite, observed >= 0 else { return nil }
        currentTime = observed
        return observed
    }

    fileprivate func playGuardedHostArtifact() {
        AudioSessionManager.activate()
        resumePlayer()
        isPlaying = true
    }

    fileprivate func pauseGuardedHostArtifact() {
        player?.pause()
        isPlaying = false
    }

    private func installGuardedArtifact(
        _ url: URL,
        song: Song,
        isRaw: Bool,
        autoplay: Bool
    ) {
        cleanupPlayer()
        isStreamingMode = isRaw
        localFileURL = url
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 0
        configurePlayer(with: item)
        setupPlayerItemObserver(item)
        if let songDuration = song.duration, songDuration > 0 {
            duration = TimeInterval(songDuration)
        }
        nowPlayingManager.updateNowPlayingInfo(song: song, duration: duration)
        if autoplay {
            AudioSessionManager.activate()
            resumePlayer()
            isPlaying = true
        } else {
            player?.pause()
            isPlaying = false
        }
    }

    private func seekInstalledGuardedArtifact(to targetSeconds: TimeInterval) {
        currentTime = targetSeconds
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func isMetered(_ snapshot: NetworkSnapshot) -> Bool {
        snapshot.classification != .wifiUnconstrained
            || snapshot.isExpensive
            || snapshot.isConstrained
    }

    func performLoadAndPlay(song: Song, seekTo initialSeek: TimeInterval? = nil) {
        // HLS (m3u8) from VISIONOS client takes priority — bypass local cache.
        // AVPlayer handles HLS natively with full duration and seek.
        if let streamURL = song.streamURL,
           (streamURL.contains("/manifest/hls") || streamURL.hasSuffix(".m3u8")),
           let url = URL(string: streamURL) {
            cleanupPlayer()
            isBuffering = true
            isPlaying = true
            userInitiatedPause = false
            Log.audio.info("HLS stream: using direct AVPlayer for \(song.title, privacy: .public)")
            // For YouTube HLS, signed URLs work without custom headers —
            // AVURLAssetHTTPHeaderFieldsKey can interfere with HLS sub-requests.
            startHLSStreaming(url: url, song: song, seekTo: initialSeek)
            return
        }

        // Check for downloaded file first (offline playback)
        if let downloadedURL = downloadManager?.localFileURL(songId: song.id) {
            Log.audio.info(
                "Playing from downloaded file: \(downloadedURL.lastPathComponent, privacy: .public)"
            )
            isStreamingMode = false
            playLocalFile(downloadedURL, song: song, seekTo: initialSeek)
            return
        }

        // Check LRU cache for a previously remuxed file (seekable local playback)
        if let cachedURL = audioCacheManager?.getFile(for: song.id) {
            Log.audio.info(
                "Playing from cached remuxed file: \(cachedURL.lastPathComponent, privacy: .public)"
            )
            isStreamingMode = false
            playLocalFile(cachedURL, song: song, seekTo: initialSeek)
            return
        }

        // Check for bundled audio file (demo/review mode)
        if let bundledURL = Bundle.main.url(forResource: song.id, withExtension: "m4a") {
            Log.audio.info(
                "Playing from bundled file: \(bundledURL.lastPathComponent, privacy: .public)"
            )
            isStreamingMode = false
            playLocalFile(bundledURL, song: song, seekTo: initialSeek)
            return
        }

        guard let streamURL = song.streamURL, let url = URL(string: streamURL) else {
            lastError = "Invalid stream URL"
            isBuffering = false
            Log.audio.error("Invalid or nil stream URL for \(song.title, privacy: .public)")
            return
        }

        // Direct local playback for file:// URLs (e.g. resolved demo/local resources)
        if url.isFileURL {
            Log.audio.info(
                "Playing from local file URL: \(url.lastPathComponent, privacy: .public)"
            )
            isStreamingMode = false
            playLocalFile(url, song: song, seekTo: initialSeek)
            return
        }

        cleanupPlayer()

        isBuffering = true
        isPlaying = true
        userInitiatedPause = false

        Log.audio.info("Download-and-play for: \(song.title, privacy: .public)")

        let headers: [String: String] =
            streamHeaders.isEmpty ? AppConstants.youtubeStreamHeaders : streamHeaders

        // YouTube serves DASH fMP4 (fragmented MP4 with empty stbl + sidx segments).
        // AVPlayer CANNOT stream fMP4 from network (causes stall at 0s / unknown error).
        // AVPlayer CAN play fMP4 from a LOCAL file for linear playback.
        // Strategy: download to local file → play raw fMP4 immediately → remux in
        // background → seamless handoff to remuxed file for seek capability.
        startDownloadThenPlay(url: url, headers: headers, song: song, seekTo: initialSeek)
    }

    /// Plays a local audio file directly (for downloaded/offline/cached tracks).
    private func playLocalFile(_ fileURL: URL, song: Song, seekTo initialSeek: TimeInterval? = nil)
    {
        cleanupPlayer()

        isStreamingMode = false
        isBuffering = true
        isPlaying = true
        userInitiatedPause = false

        self.localFileURL = fileURL
        let asset = AVURLAsset(url: fileURL)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        self.configurePlayer(with: playerItem)

        self.setupPlayerItemObserver(playerItem)

        if let seekTime = initialSeek {
            self.pendingSeekTime = seekTime
            self.currentTime = seekTime
        }

        // Write Now Playing metadata BEFORE activating + starting playback so
        // iOS samples a fully-populated dictionary at the moment it binds this
        // app as the current Now Playing app (F1/F2 — D-2, D-3).
        // Use Song.duration (domain) as deterministic first-write value; the
        // KVO `.readyToPlay` observer will refine it from AVPlayerItem if needed.
        if let songDuration = song.duration, songDuration > 0 {
            self.duration = TimeInterval(songDuration)
        }
        self.nowPlayingManager.updateNowPlayingInfo(song: song, duration: self.duration)

        // Activate the audio session immediately before playback begins (D-1).
        AudioSessionManager.activate()

        self.resumePlayer()
        self.applyAudioProcessing()
        self.recoveryService.startStallDetection()
    }

    /// Downloads YouTube fMP4 audio, remuxes to standard MP4 for seekable playback.
    /// YouTube serves DASH fMP4 (empty stbl + sidx segments) which AVPlayer cannot
    /// seek in — even from a local file. Remuxing via AVAssetReader/Writer produces
    /// a standard MP4 with populated stbl sample tables for proper random access.
    private func downloadToLocalFile(
        url: URL, headers: [String: String], videoId: String,
        completion: @escaping @Sendable (URL?) -> Void
    ) {
        let cacheManager = self.audioCacheManager

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LovelyMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let remuxedURL = cacheDir.appendingPathComponent("\(videoId)_remuxed.m4a")

        // Check LRU cache for a valid remuxed file
        if let cachedURL = cacheManager?.getFile(for: videoId) {
            Log.audio.info("Using cached remuxed file for \(videoId, privacy: .public)")
            completion(cachedURL)
            return
        }

        // Add &range=0- to bypass YouTube's progressive download throttling.
        var downloadURL = url
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "range" }
            items.append(URLQueryItem(name: "range", value: "0-"))
            components.queryItems = items
            if let newURL = components.url {
                downloadURL = newURL
            }
        }

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        Log.audio.info("Downloading audio for \(videoId, privacy: .public)...")
        let task = URLSession.shared.downloadTask(with: request) { tempURL, response, error in
            if let error {
                Log.audio.error("Download error: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            guard let tempURL else {
                Log.audio.error("Download returned no file")
                completion(nil)
                return
            }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.audio.debug("Downloaded to temp file (HTTP \(httpStatus))")

            // Move downloaded file from temp location to raw URL for remuxing
            let rawURL = cacheDir.appendingPathComponent("\(videoId)_raw.m4a")
            do {
                try? FileManager.default.removeItem(at: rawURL)
                try FileManager.default.moveItem(at: tempURL, to: rawURL)
            } catch {
                Log.audio.error("Failed to move raw file: \(error, privacy: .public)")
                completion(nil)
                return
            }

            // Remux fMP4 → standard MP4 with populated stbl for seekable playback
            Task {
                // Reserve the cache slot BEFORE the remux/move writes the file
                // to disk, so a concurrent `removeOrphans` Pass 2 cannot treat
                // the freshly-written `_remuxed.m4a` as an orphan. The slot is
                // overwritten with the real size by `registerFile` below.
                cacheManager?.reserveSlot(videoId: videoId, fileURL: remuxedURL)
                let success = await Self.remuxToStandardMP4(source: rawURL, destination: remuxedURL)
                if success {
                    try? FileManager.default.removeItem(at: rawURL)
                    cacheManager?.registerFile(videoId: videoId, fileURL: remuxedURL)
                    Log.audio.info("Remuxed to standard MP4 successfully")
                    completion(remuxedURL)
                } else {
                    Log.audio.warning("Remux failed, falling back to raw fMP4")
                    do {
                        try? FileManager.default.removeItem(at: remuxedURL)
                        try FileManager.default.moveItem(at: rawURL, to: remuxedURL)
                        cacheManager?.registerFile(videoId: videoId, fileURL: remuxedURL)
                        completion(remuxedURL)
                    } catch {
                        try? FileManager.default.removeItem(at: rawURL)
                        completion(nil)
                    }
                }
            }
        }
        self.downloadTask = task
        task.resume()
    }

    /// HLS streaming via VISIONOS client — no custom headers needed (URLs are self-signed).
    private func startHLSStreaming(url: URL, song: Song, seekTo initialSeek: TimeInterval? = nil) {
        isStreamingMode = false
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        // YouTube HLS uses DVR-style manifest — disable live edge positioning
        playerItem.automaticallyPreservesTimeOffsetFromLive = false
        playerItem.preferredForwardBufferDuration = 2
        configurePlayer(with: playerItem)
        // pendingSeekTime = 0 so readyToPlay seeks to start (DVR defaults to live edge)
        pendingSeekTime = initialSeek ?? 0
        setupPlayerItemObserver(playerItem)
        if let d = song.duration, d > 0 { duration = TimeInterval(d) }
        nowPlayingManager.updateNowPlayingInfo(song: song, duration: duration)
        AudioSessionManager.activate()
        resumePlayer()
        applyAudioProcessing()
        recoveryService.startStallDetection()
        Log.audio.info("HLS streaming for: \(song.title, privacy: .public)")
    }

    /// Downloads fMP4 to a local file, starts playback from the raw file immediately
    /// (linear playback works on local fMP4), then remuxes in background for seek.
    /// YouTube DASH fMP4 cannot be streamed from network by AVPlayer (causes
    /// err=-12371/-12864 and UI freeze), but local file playback works fine.
    private func startDownloadThenPlay(
        url: URL, headers: [String: String], song: Song, seekTo initialSeek: TimeInterval? = nil
    ) {
        backgroundRemuxTask = Task { [weak self] in
            guard let self else { return }

            let cacheManager = self.audioCacheManager
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LovelyMusic", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: cacheDir, withIntermediateDirectories: true)
            let rawURL = cacheDir.appendingPathComponent("\(song.id)_raw.m4a")
            let remuxedURL = cacheDir.appendingPathComponent("\(song.id)_remuxed.m4a")

            // Check LRU cache (may have been populated by prefetch)
            if let cachedURL = cacheManager?.getFile(for: song.id) {
                guard !Task.isCancelled else { return }
                Log.audio.info("Found cached remuxed file for \(song.id, privacy: .public)")
                self.isStreamingMode = false
                self.playLocalFile(cachedURL, song: song, seekTo: initialSeek)
                return
            }

            // YouTube CDN enforces segment-aligned access via sidx box boundaries.
            // Download: (1) header to parse sidx, (2) each segment by exact byte range.
            var baseRequest = URLRequest(url: url)
            baseRequest.timeoutInterval = 60
            for (key, value) in headers {
                baseRequest.setValue(value, forHTTPHeaderField: key)
            }
            let sessionCookieStr = HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.youtube.com")!)
                .map { $0.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") } ?? ""
            let authCookieStr = authCookieProvider?() ?? ""
            let merged = [sessionCookieStr, authCookieStr].filter { !$0.isEmpty }.joined(separator: "; ")
            if !merged.isEmpty {
                baseRequest.setValue(merged, forHTTPHeaderField: "Cookie")
            }

            Log.audio.info("Downloading audio for \(song.id, privacy: .public)...")

            do {
                let startTime = Date()

                // Step 1: Download header (first 4KB covers all fMP4 init boxes).
                var headerReq = baseRequest
                headerReq.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
                let (headerData, headerResp) = try await URLSession.shared.data(for: headerReq)
                guard (headerResp as? HTTPURLResponse)?.statusCode ?? -1 == 206 else {
                    throw URLError(.badServerResponse)
                }

                // Step 2: Parse sidx to find segment boundaries.
                let (headerEnd, segSizes) = parseSIDX(headerData)
                Log.audio.info("Segments: header=\(headerEnd)B segs=\(segSizes.count)")

                // Write incrementally to FileHandle to avoid buffering full song in memory.
                try? FileManager.default.removeItem(at: rawURL)
                guard FileManager.default.createFile(atPath: rawURL.path, contents: nil) else {
                    throw URLError(.cannotCreateFile)
                }
                let fileHandle = try FileHandle(forWritingTo: rawURL)
                defer { fileHandle.closeFile() }

                if segSizes.isEmpty {
                    // No sidx — non-segmented fMP4, try large single request.
                    var fallbackReq = baseRequest
                    fallbackReq.setValue("bytes=0-399999", forHTTPHeaderField: "Range")
                    let (d, _) = try await URLSession.shared.data(for: fallbackReq)
                    fileHandle.write(d)
                } else {
                    // Full header may be > 4096 bytes — re-request if needed.
                    if headerEnd <= 4096 {
                        fileHandle.write(headerData.prefix(headerEnd))
                    } else {
                        var fullHeaderReq = baseRequest
                        fullHeaderReq.setValue("bytes=0-\(headerEnd - 1)", forHTTPHeaderField: "Range")
                        let (hd, _) = try await URLSession.shared.data(for: fullHeaderReq)
                        fileHandle.write(hd)
                    }
                    // Step 3: Download each segment by exact byte range.
                    // YouTube CDN allows ~5 segments per URL before returning 403.
                    // Refresh via streamURLResolver every 5 segments.
                    var segOffset = headerEnd
                    var currentSegRequest = baseRequest
                    var segsThisURL = 0
                    for segSize in segSizes {
                        if segsThisURL >= 5,
                           let resolved = try? await self.streamURLResolver?(song.id),
                           let freshURL = URL(string: resolved.url) {
                            var refreshed = URLRequest(url: freshURL)
                            refreshed.timeoutInterval = 60
                            for (k, v) in headers { refreshed.setValue(v, forHTTPHeaderField: k) }
                            if !merged.isEmpty { refreshed.setValue(merged, forHTTPHeaderField: "Cookie") }
                            currentSegRequest = refreshed
                            segsThisURL = 0
                        }
                        let segEnd = segOffset + segSize - 1
                        var segReq = currentSegRequest
                        segReq.setValue("bytes=\(segOffset)-\(segEnd)", forHTTPHeaderField: "Range")
                        let (segData, segResp) = try await URLSession.shared.data(for: segReq)
                        let code = (segResp as? HTTPURLResponse)?.statusCode ?? -1
                        if code == 206 || code == 200 {
                            fileHandle.write(segData)
                        } else {
                            // CDN per-session limit reached — play partial file (first N segments).
                            let written = (try? fileHandle.seekToEndOfFile()) ?? 0
                            Log.audio.info("CDN limit at seg \(segOffset): playing \(written)B partial")
                            break
                        }
                        segOffset += segSize
                        segsThisURL += 1
                        guard !Task.isCancelled else { fileHandle.closeFile(); return }
                    }
                }

                fileHandle.closeFile()
                let writtenBytes = (try? FileManager.default.attributesOfItem(atPath: rawURL.path)[.size] as? Int64) ?? 0
                Log.audio.info("Download complete for \(song.id, privacy: .public): \(writtenBytes)B in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")

                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: rawURL)
                    return
                }

                // Verify still playing the same song after download
                guard self.currentTrack?.id == song.id else {
                    try? FileManager.default.removeItem(at: rawURL)
                    return
                }

                // Play the raw fMP4 immediately — linear playback works from local file.
                // Seeking won't work yet (empty stbl) but audio starts right away.
                self.isStreamingMode = true
                self.localFileURL = rawURL
                let asset = AVURLAsset(url: rawURL)
                let playerItem = AVPlayerItem(asset: asset)
                playerItem.preferredForwardBufferDuration = 0
                self.configurePlayer(with: playerItem)
                self.setupPlayerItemObserver(playerItem)

                if let seekTime = initialSeek {
                    self.pendingSeekTime = seekTime
                    self.currentTime = seekTime
                }

                // Write Now Playing metadata BEFORE activating + starting playback
                // so iOS samples a fully-populated dictionary on bind (D-2, D-3).
                if let songDuration = song.duration, songDuration > 0 {
                    self.duration = TimeInterval(songDuration)
                }
                self.nowPlayingManager.updateNowPlayingInfo(song: song, duration: self.duration)

                // Activate the audio session immediately before playback begins (D-1).
                AudioSessionManager.activate()

                self.resumePlayer()
                self.applyAudioProcessing()
                self.recoveryService.startStallDetection()
                Log.audio.info(
                    "Playing from raw fMP4, starting background remux for seek capability")

                guard !Task.isCancelled else { return }

                // Remux in background for seekable playback
                // Reserve the cache slot BEFORE the remux writes to disk so a
                // concurrent `removeOrphans` Pass 2 cannot delete the file in
                // the window between write and `registerFile`.
                cacheManager?.reserveSlot(videoId: song.id, fileURL: remuxedURL)
                let success = await Self.remuxToStandardMP4(source: rawURL, destination: remuxedURL)
                guard !Task.isCancelled, self.currentTrack?.id == song.id else {
                    try? FileManager.default.removeItem(at: remuxedURL)
                    return
                }

                if success {
                    cacheManager?.registerFile(videoId: song.id, fileURL: remuxedURL)
                    Log.audio.info("Background remux completed for \(song.id, privacy: .public)")
                    self.handoffToLocalFile(remuxedURL, song: song)
                    try? FileManager.default.removeItem(at: rawURL)
                } else {
                    Log.audio.warning(
                        "Background remux failed for \(song.id, privacy: .public), seek unavailable"
                    )
                    // Keep isStreamingMode = true — raw fMP4 has no seek capability.
                    // Do NOT cache the raw file to avoid future plays loading unseekable audio.
                    try? FileManager.default.removeItem(at: remuxedURL)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isBuffering = false
                self.isPlaying = false
                self.lastError = "Download failed"
                Log.audio.error(
                    "Download failed for \(song.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                #if DEBUG
                #endif
            }
        }
    }

    /// Seamlessly replaces the raw fMP4 player item with a remuxed local file.
    /// Records the current playback position and seeks to it after replacement,
    /// giving the user full seek capability without audible interruption.
    private func handoffToLocalFile(_ localURL: URL, song: Song) {
        // Guard: only handoff if still playing the same song
        guard currentTrack?.id == song.id else {
            Log.audio.debug("Handoff skipped: song changed from \(song.id, privacy: .public)")
            return
        }
        // Guard: only handoff if currently in streaming mode (playing raw fMP4)
        guard isStreamingMode else {
            Log.audio.debug("Handoff skipped: not in streaming mode")
            return
        }

        let handoffTime = player?.currentTime().seconds ?? currentTime
        let wasPlaying = isPlaying

        Log.audio.info(
            "Handoff: switching to remuxed file at \(handoffTime)s for \(song.title, privacy: .public)"
        )

        // Remove old observers before replacing item
        if let observer = endOfTrackObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfTrackObserver = nil
        }
        if let observer = errorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            errorLogObserver = nil
        }
        if let observer = accessLogObserver {
            NotificationCenter.default.removeObserver(observer)
            accessLogObserver = nil
        }
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()

        // Create new player item from remuxed file
        localFileURL = localURL
        let asset = AVURLAsset(url: localURL)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0

        // Replace in-place on existing AVPlayer (avoids audio graph teardown)
        player?.replaceCurrentItem(with: playerItem)
        isStreamingMode = false
        recoveryService.resetRetry()

        // Re-attach EQ processing tap
        if let audioMix = eqProcessor.createAudioMix(for: playerItem.asset) {
            playerItem.audioMix = audioMix
        }

        // Setup observers for the new item
        setupPlayerItemObserver(playerItem)

        // Seek to where playback left off (or apply any pending seek)
        let targetTime = pendingSeekTime ?? handoffTime
        pendingSeekTime = nil

        if targetTime > 0.5 {
            let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.currentTime = targetTime
                    self.isBuffering = false
                    if wasPlaying {
                        self.resumePlayer()
                    }
                    self.syncVideoToAudioTime(targetTime)
                    Log.audio.info(
                        "Handoff seek completed at \(targetTime)s, finished=\(finished, privacy: .public)"
                    )
                }
            }
        } else {
            isBuffering = false
            if wasPlaying {
                resumePlayer()
            }
        }

        nowPlayingManager.updateNowPlayingInfo(song: song, duration: duration)
        Log.audio.info("Handoff complete: now playing from remuxed file with seek capability")
    }

    /// Remuxes a fragmented MP4 (fMP4) to a standard interleaved MP4 using
    /// AVAssetReader + AVAssetWriter. The output has populated stbl (sample table)
    /// atoms, enabling AVPlayer to perform byte-accurate seeking.
    /// This is a passthrough operation — no transcoding, just container reformatting.
    nonisolated static func remuxToStandardMP4(
        source: URL, destination: URL
    ) async -> Bool {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let reader = try? AVAssetReader(asset: asset),
            let writer = try? AVAssetWriter(url: destination, fileType: .m4a)
        else {
            Log.audio.error("Remux: failed to create AVAssetReader/Writer")
            return false
        }

        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            Log.audio.error("Remux: no audio track found")
            return false
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack, outputSettings: nil
        )
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            Log.audio.error("Remux: cannot add reader output")
            return false
        }
        reader.add(readerOutput)

        guard let formatDesc = try? await audioTrack.load(.formatDescriptions).first else {
            Log.audio.error("Remux: no format description available")
            return false
        }

        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: formatDesc
        )
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else {
            Log.audio.error("Remux: cannot add writer input")
            return false
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            Log.audio.error(
                "Remux: reader failed to start: \(reader.error?.localizedDescription ?? "?", privacy: .public)"
            )
            return false
        }
        guard writer.startWriting() else {
            Log.audio.error(
                "Remux: writer failed to start: \(writer.error?.localizedDescription ?? "?", privacy: .public)"
            )
            return false
        }
        writer.startSession(atSourceTime: .zero)

        // Bridge the pull-loop to async via checked continuation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.lovelymusic.remux")
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

        guard reader.status == .completed else {
            Log.audio.error(
                "Remux: reader ended with status \(reader.status.rawValue): \(reader.error?.localizedDescription ?? "?", privacy: .public)"
            )
            return false
        }

        await writer.finishWriting()
        let success = writer.status == .completed
        if !success {
            Log.audio.error(
                "Remux: writer finish error: \(writer.error?.localizedDescription ?? "?", privacy: .public)"
            )
        }
        return success
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Suppress updates while a pending seek is queued to prevent
                // the scrubber from flickering between actual and desired position
                guard self.pendingSeekTime == nil else { return }
                self.currentTime = time.seconds

                // Pre-fetch next track when playback reaches 75%
                if self.duration > 0 && self.prefetchManager.isIdle {
                    let progress = self.currentTime / self.duration
                    if progress > 0.75 {
                        self.syncPrefetchDependencies()
                        self.prefetchManager.prefetchNextTrack()
                    }
                }

                // Trigger crossfade when approaching end of track
                if self.duration > 0,
                    self.crossfadeManager.shouldTrigger(
                        currentTime: self.currentTime,
                        duration: self.duration,
                        repeatMode: self.repeatMode
                    )
                {
                    self.beginCrossfade()
                }
            }
        }
    }

    private func setupPlayerItemObserver(_ item: AVPlayerItem) {
        // Status observer with retry logic.
        // `.initial` ensures we receive the current value at attach time so we
        // don't miss `.readyToPlay` if the item transitioned synchronously
        // before observation began (F3 — KVO race on cold-start local-file
        // playback).
        let statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    // Refine duration from the player item only if it provides a
                    // valid finite value. We may have already populated duration
                    // from Song.duration (D-3) — don't clobber it with NaN/0.
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite, itemDuration > 0 {
                        self.duration = itemDuration
                    }
                    self.lastError = nil
                    Log.audio.info("Ready to play, duration: \(self.duration)s")
                    self.nowPlayingManager.updateNowPlayingInfo(
                        song: self.currentTrack,
                        duration: self.duration
                    )

                    // Deferred seek: used when performLoadAndPlay(seekTo:) sets a target position.
                    if let seekTime = self.pendingSeekTime {
                        self.pendingSeekTime = nil
                        let cmTime = CMTime(seconds: seekTime, preferredTimescale: 600)
                        self.player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        { [weak self] finished in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.currentTime = seekTime
                                Log.audio.debug(
                                    "Deferred seek completed: finished=\(finished, privacy: .public)"
                                )
                                if self.isPlaying {
                                    self.resumePlayer()
                                }
                                self.syncVideoToAudioTime(seekTime)
                                self.isBuffering = false
                            }
                        }
                    } else {
                        self.isBuffering = false
                    }
                case .failed:
                    if self.guardedCoordinator != nil {
                        self.reportPlaybackItemFailure()
                        return
                    }
                    // Check if failure is due to expired stream URL (HTTP 403/410)
                    if self.isStreamExpiryError(item.error),
                        !self.isReconnecting,
                        let song = self.currentTrack
                    {
                        Log.audio.warning(
                            "Playback failed with stream expiry error, attempting recovery")
                        self.attemptStreamRecovery(for: song)
                    } else if !self.recoveryService.hasAttemptedRetry,
                        let currentSong = self.currentTrack
                    {
                        Log.audio.error(
                            "Playback failed, attempting retry for: \(currentSong.title, privacy: .public)"
                        )
                        self.recoveryService.retryPlayback(for: currentSong)
                    } else {
                        self.isBuffering = false
                        self.lastError = item.error?.localizedDescription ?? "Playback failed"
                        Log.audio.error(
                            "AVPlayerItem FAILED (no retry): \(item.error?.localizedDescription ?? "unknown", privacy: .public)"
                        )
                    }
                default:
                    break
                }
            }
        }
        itemObservations.append(statusObs)

        // Buffer empty → set buffering state
        let bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new, .initial]) {
            [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.isPlaybackBufferEmpty {
                    self.isBuffering = true
                    Log.audio.debug("Buffer empty")
                }
            }
        }
        itemObservations.append(bufferEmptyObs)

        // Buffer likely to keep up → resume if was buffering
        let bufferKeepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new, .initial]) {
            [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.isPlaybackLikelyToKeepUp && self.isBuffering {
                    self.isBuffering = false
                    if self.isPlaying {
                        self.resumePlayer()
                    }
                    Log.audio.info("Buffer recovered, resuming playback")
                }
            }
        }
        itemObservations.append(bufferKeepUpObs)

        // Buffer full (monitoring only)
        let bufferFullObs = item.observe(\.isPlaybackBufferFull, options: [.new, .initial]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                Log.audio.debug("Buffer full")
            }
        }
        itemObservations.append(bufferFullObs)

        endOfTrackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTrackEnd()
            }
        }

        // Observe error log entries for HTTP-level diagnostics during seeking
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let log = item.errorLog() {
                    for event in log.events {
                        Log.audio.error(
                            "ErrorLog: status=\(event.serverAddress ?? "?", privacy: .public) code=\(event.errorStatusCode) domain=\(event.errorDomain, privacy: .public) comment=\(event.errorComment ?? "none", privacy: .public)"
                        )

                        // Detect stream URL expiry: HTTP 403 (Forbidden) or 410 (Gone)
                        let httpCode = abs(event.errorStatusCode)
                        if httpCode == 403 || httpCode == 410,
                            self.isPlaying,
                            !self.isReconnecting,
                            let song = self.currentTrack
                        {
                            Log.audio.warning(
                                "Stream URL expired (HTTP \(httpCode)), attempting auto-recovery")
                            self.attemptStreamRecovery(for: song)
                        }
                    }
                }
            }
        }

        // Observe access log for HTTP request details
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self != nil else { return }
                if let log = item.accessLog(), let event = log.events.last {
                    Log.audio.debug(
                        "AccessLog: uri=\(event.uri?.prefix(60) ?? "?", privacy: .public) bytesTransferred=\(event.numberOfBytesTransferred) stalls=\(event.numberOfStalls)"
                    )
                }
            }
        }
    }

    func handleTrackEnd() {
        Log.audio.debug("Track ended: repeat=\(self.repeatMode.rawValue, privacy: .public)")
        // If crossfade is active, the next track is already playing — ignore the end notification
        // from the outgoing player.
        guard !crossfadeManager.isCrossfading else { return }

        switch repeatMode {
        case .one:
            seek(to: 0)
            resumePlayer()
        case .all:
            next()
        case .off:
            if isPlayingFromAutoplay {
                if !autoplayQueue.isEmpty {
                    playNextFromAutoplay()
                } else if onQueueExhausted != nil {
                    onQueueExhausted?()
                } else {
                    isPlaying = false
                    isPlayingFromAutoplay = false
                }
            } else if shuffleEnabled && queue.count > 1 {
                next()
            } else if currentIndex < queue.count - 1 {
                next()
            } else if !autoplayQueue.isEmpty {
                playNextFromAutoplay()
            } else if onQueueExhausted != nil {
                onQueueExhausted?()
            } else {
                isPlaying = false
            }
        }
    }

    // MARK: - Stream Expiry Recovery

    /// Checks whether an AVPlayerItem error indicates an expired stream URL.
    private func isStreamExpiryError(_ error: Error?) -> Bool {
        guard let nsError = error as? NSError else { return false }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorUserAuthenticationRequired,  // -1012
                NSURLErrorNoPermissionsToReadFile,  // -1102
                NSURLErrorFileDoesNotExist:  // -1100
                return true
            default:
                break
            }
        }
        // Check underlying errors recursively
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isStreamExpiryError(underlying)
        }
        return false
    }

    /// Attempts to recover from an expired stream URL by re-resolving and
    /// resuming playback at the saved position. Max 2 auto-retry attempts.
    private func attemptStreamRecovery(for song: Song) {
        guard guardedCoordinator == nil else {
            reportPlaybackItemFailure()
            return
        }
        guard !isReconnecting else { return }
        guard streamRecoveryAttemptCount < Self.maxStreamRecoveryAttempts else {
            Log.audio.error(
                "Stream recovery: max attempts (\(Self.maxStreamRecoveryAttempts)) reached for \(song.id, privacy: .public)"
            )
            lastError = "Stream expired. Please try again."
            isBuffering = false
            return
        }
        guard let resolver = streamURLResolver else {
            Log.audio.error("Stream recovery: no resolver available")
            lastError = "Cannot reconnect — no stream resolver"
            return
        }

        isReconnecting = true
        streamRecoveryAttemptCount += 1
        let savedPosition = player?.currentTime().seconds ?? currentTime

        Log.audio.info(
            "Stream recovery: attempt \(self.streamRecoveryAttemptCount)/\(Self.maxStreamRecoveryAttempts) for \(song.id, privacy: .public) at \(savedPosition)s"
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await resolver(song.id)
                guard self.currentTrack?.id == song.id else {
                    self.isReconnecting = false
                    return
                }

                Log.audio.info("Stream recovery: got fresh URL, resuming at \(savedPosition)s")

                var recoveredSong = song
                recoveredSong.streamURL = result.url
                recoveredSong.streamContentLength = result.contentLength
                self.streamResolvedAt = Date()
                self.currentTrack = recoveredSong
                if self.currentIndex < self.queue.count {
                    self.queue[self.currentIndex].streamURL = result.url
                    self.queue[self.currentIndex].streamContentLength = result.contentLength
                }

                self.isReconnecting = false
                self.performLoadAndPlay(song: recoveredSong, seekTo: savedPosition)
            } catch {
                guard self.currentTrack?.id == song.id else {
                    self.isReconnecting = false
                    return
                }
                Log.audio.error(
                    "Stream recovery attempt \(self.streamRecoveryAttemptCount) failed: \(error.localizedDescription, privacy: .public)"
                )
                self.isReconnecting = false

                // Retry if attempts remain
                if self.streamRecoveryAttemptCount < AudioEngine.maxStreamRecoveryAttempts {
                    self.attemptStreamRecovery(for: song)
                } else {
                    self.lastError = "Stream expired. Please try again."
                    self.isBuffering = false
                }
            }
        }
    }

    // MARK: - Video Playback (delegated to VideoPlaybackManager)

    func setVideoMode(_ enabled: Bool) {
        videoManager.setVideoMode(enabled)
    }

    func loadVideoStream(for song: Song) {
        videoManager.isPlaying = isPlaying
        videoManager.loadVideoStream(for: song)
    }

    func cleanupVideoPlayer() {
        videoManager.cleanupVideoPlayer()
    }

    /// Re-anchor the muted video layer to a specific audio time. Called
    /// from every seek completion path (direct seek, deferred-on-ready
    /// seek, fMP4→remux handoff seek) so the two streams never drift —
    /// the drift is invisible until the user opens the fullscreen video
    /// viewer, which is exactly the bug we're guarding against.
    private func syncVideoToAudioTime(_ time: TimeInterval) {
        videoManager.seek(to: time)
    }

    // MARK: - Time Control Status

    private func setupTimeControlObserver() {
        timeControlObserver = player?.observe(\.timeControlStatus, options: [.new]) {
            [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .paused:
                    // Skip recovery if player has no item (song transition in progress)
                    guard player.currentItem != nil else { return }
                    // Skip recovery if at end of file — partial download reached EOF normally
                    let ct = player.currentTime()
                    let dur = player.currentItem?.duration ?? .invalid
                    let atEOF = dur.isValid && !dur.isIndefinite &&
                                CMTimeGetSeconds(ct) >= CMTimeGetSeconds(dur) - 0.5
                    if !self.userInitiatedPause && !self.isSeeking && self.isPlaying && !atEOF
                        && !self.isBuffering  // suppress during song transitions/initial buffering
                    {
                        Log.audio.warning("Unexpected pause detected, attempting recovery...")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        // Re-check after delay: item may have been replaced during sleep
                        if self.isPlaying && !self.isSeeking
                            && player.currentItem != nil
                            && player.timeControlStatus == .paused
                        {
                            self.resumePlayer()
                            Log.audio.debug("Recovery: called play()")
                        }
                    }
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                    Log.audio.debug("Waiting to play at specified rate")
                case .playing:
                    self.isBuffering = false
                @unknown default:
                    Log.audio.warning("Unexpected state encountered")
                }
            }
        }
    }

    private func cleanupPlayer() {
        pendingSeekTime = nil
        isReconnecting = false
        streamRecoveryAttemptCount = 0
        resolveTask?.cancel()
        resolveTask = nil
        backgroundRemuxTask?.cancel()
        backgroundRemuxTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        if let observer = endOfTrackObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfTrackObserver = nil
        }
        if let observer = errorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            errorLogObserver = nil
        }
        if let observer = accessLogObserver {
            NotificationCenter.default.removeObserver(observer)
            accessLogObserver = nil
        }
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        recoveryService.stopStallDetection()
        // Suppress watchdog before pausing — cleanupPlayer is intentional, not a stall.
        userInitiatedPause = true
        // Reset stale state from previous song
        isStreamingMode = false
        localFileURL = nil
        currentTime = 0
        duration = 0
        // Remove current item to prevent the recovery observer from resuming
        // the old song during song transitions, then pause.
        player?.replaceCurrentItem(with: nil)
        player?.pause()
    }

    // MARK: - Crossfade

    /// Invalidates every async preparation token and safely tears down an active
    /// fade. Callers explicitly choose whether the reserved next-track candidate
    /// survives (seek/system pause) or is discarded (track/queue/policy change).
    private func invalidateCrossfadePreparation(clearReservation: Bool) {
        let wasCrossfading = crossfadeManager.isCrossfading
        let hadCrossfadePlayer = crossfadePlayer != nil
        crossfadePreparationGeneration &+= 1
        crossfadePreparationTask?.cancel()
        crossfadePreparationTask = nil
        activeCrossfadeToken = nil

        crossfadeManager.cancelFade()
        if hadCrossfadePlayer {
            cleanupCrossfadePlayer()
        }
        if wasCrossfading {
            player?.volume = normalizationEnabled ? normalizedVolume : Float(1.0)
        }
        crossfadeManager.resetTrigger()

        attemptedCrossfadeReservation = nil
        attemptedCrossfadeLocalURL = nil
        if clearReservation {
            crossfadeReservation = nil
            reservedShuffleProgress = nil
        }
    }

    private func commitReservedShuffleProgress(for reservation: CrossfadeReservation) {
        guard reservation == crossfadeReservation,
            reservation.shuffleEnabled,
            let reservedShuffleProgress
        else { return }
        applyShuffleProgress(reservedShuffleProgress)
        self.reservedShuffleProgress = nil
    }

    private func validatedLocalCrossfadeFile(for song: Song) -> CrossfadeLocalFile? {
        let candidateURL = audioCacheManager?.getFile(for: song.id)
            ?? downloadManager?.localFileURL(songId: song.id)
            ?? Bundle.main.url(forResource: song.id, withExtension: "m4a")
        guard let candidateURL,
            candidateURL.isFileURL,
            FileManager.default.fileExists(atPath: candidateURL.path)
        else { return nil }
        return CrossfadeLocalFile(url: candidateURL)
    }

    private func localCrossfadeURL(for song: Song) -> URL? {
        validatedLocalCrossfadeFile(for: song)?.url
    }

    private func isCrossfadeReservationValid(_ reservation: CrossfadeReservation) -> Bool {
        guard reservation.sourceSongID == currentTrack?.id,
            reservation.sourceIndex == currentIndex,
            reservation.sourceWasAutoplay == isPlayingFromAutoplay,
            reservation.queueRevision == queueRevision,
            reservation.autoplayRevision == autoplayRevision,
            reservation.playbackPolicyRevision == playbackPolicyRevision,
            reservation.shuffleEnabled == shuffleEnabled,
            reservation.repeatMode == repeatMode
        else { return false }

        switch reservation.destination {
        case .queue(let index):
            return queue.indices.contains(index) && queue[index].id == reservation.nextSongID
        case .autoplay:
            return autoplayQueue.first?.id == reservation.nextSongID
        }
    }

    private func reserveNextCrossfadeCandidate() -> CrossfadeReservation? {
        if let reservation = crossfadeReservation,
            isCrossfadeReservationValid(reservation)
        {
            return reservation
        }

        crossfadeReservation = nil
        reservedShuffleProgress = nil
        attemptedCrossfadeReservation = nil
        attemptedCrossfadeLocalURL = nil

        guard let sourceSongID = currentTrack?.id else { return nil }

        let nextSong: Song
        let destination: CrossfadeDestination
        if isPlayingFromAutoplay {
            guard let autoplaySong = autoplayQueue.first else { return nil }
            nextSong = autoplaySong
            destination = .autoplay
        } else {
            guard !queue.isEmpty else { return nil }
            if shuffleEnabled && queue.count > 1 {
                guard let selection = makeNextShuffleSelection() else { return nil }
                let nextIndex = selection.index
                guard queue.indices.contains(nextIndex) else { return nil }
                reservedShuffleProgress = selection.progress
                nextSong = queue[nextIndex]
                destination = .queue(index: nextIndex)
            } else if currentIndex + 1 < queue.count {
                let nextIndex = currentIndex + 1
                nextSong = queue[nextIndex]
                destination = .queue(index: nextIndex)
            } else if repeatMode == .all {
                guard let firstSong = queue.first else { return nil }
                nextSong = firstSong
                destination = .queue(index: 0)
            } else if let autoplaySong = autoplayQueue.first {
                nextSong = autoplaySong
                destination = .autoplay
            } else {
                return nil
            }
        }

        let reservation = CrossfadeReservation(
            sourceSongID: sourceSongID,
            sourceIndex: currentIndex,
            sourceWasAutoplay: isPlayingFromAutoplay,
            nextSongID: nextSong.id,
            destination: destination,
            queueRevision: queueRevision,
            autoplayRevision: autoplayRevision,
            playbackPolicyRevision: playbackPolicyRevision,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode
        )
        crossfadeReservation = reservation
        return reservation
    }

    private func song(for reservation: CrossfadeReservation) -> Song? {
        switch reservation.destination {
        case .queue(let index):
            guard queue.indices.contains(index) else { return nil }
            return queue[index]
        case .autoplay:
            return autoplayQueue.first
        }
    }

    private func isCrossfadeTokenValid(_ token: CrossfadePreparationToken) -> Bool {
        token.generation == crossfadePreparationGeneration
            && token.reservation == crossfadeReservation
            && isCrossfadeReservationValid(token.reservation)
    }

    private func clearCrossfadePreparationTask(for token: CrossfadePreparationToken) {
        guard token.generation == crossfadePreparationGeneration else { return }
        crossfadePreparationTask = nil
    }

    private func scheduleCrossfadePreparation(
        for reservation: CrossfadeReservation,
        nextSong: Song
    ) -> Task<Void, Never>? {
        guard isCrossfadeReservationValid(reservation) else { return nil }

        if attemptedCrossfadeReservation == reservation,
            let crossfadePreparationTask
        {
            return crossfadePreparationTask
        }

        let localURL = localCrossfadeURL(for: nextSong)
        if attemptedCrossfadeReservation == reservation,
            attemptedCrossfadeLocalURL == localURL
        {
            return nil
        }

        attemptedCrossfadeReservation = reservation
        attemptedCrossfadeLocalURL = localURL
        let token = CrossfadePreparationToken(
            generation: crossfadePreparationGeneration,
            reservation: reservation
        )

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.clearCrossfadePreparationTask(for: token) }

            do {
                let item = try await self.prepareCrossfadePlayerItem(for: nextSong)
                guard !Task.isCancelled,
                    self.isCrossfadeTokenValid(token),
                    !self.crossfadeManager.isCrossfading
                else { return }

                switch reservation.destination {
                case .queue(let nextIndex):
                    self.startCrossfadePlayback(
                        with: item,
                        nextSong: nextSong,
                        nextIndex: nextIndex,
                        localFileURL: self.localCrossfadeURL(for: nextSong),
                        token: token
                    )
                case .autoplay:
                    self.startAutoplayCrossfadePlayback(
                        with: item,
                        nextSong: nextSong,
                        token: token
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCrossfadeTokenValid(token) else { return }
                Log.audio.error(
                    "Crossfade: failed to prepare next track: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        crossfadePreparationTask = task
        return task
    }

    /// Determines the next song for crossfade and starts the dual-player transition.
    @discardableResult
    func beginCrossfade() -> Task<Void, Never>? {
        guard let reservation = reserveNextCrossfadeCandidate(),
            let nextSong = song(for: reservation)
        else {
            if isPlayingFromAutoplay || (!queue.isEmpty && !shuffleEnabled) {
                onQueueExhausted?()
            }
            return nil
        }

        Log.audio.info("Crossfade: preparing next track \(nextSong.title, privacy: .public)")

        if case .queue(let nextIndex) = reservation.destination,
            let prefetchedItem = prefetchManager.prefetchedPlayerItem,
            prefetchManager.prefetchedSongId == nextSong.id
        {
            let fileURL = prefetchManager.prefetchedLocalFileURL
            prefetchManager.cancelPrefetch()
            let token = CrossfadePreparationToken(
                generation: crossfadePreparationGeneration,
                reservation: reservation
            )
            startCrossfadePlayback(
                with: prefetchedItem,
                nextSong: nextSong,
                nextIndex: nextIndex,
                localFileURL: fileURL,
                token: token
            )
            return nil
        }

        prefetchManager.cancelPrefetch()
        return scheduleCrossfadePreparation(for: reservation, nextSong: nextSong)
    }

    /// Builds a speculative crossfade item only from bytes already on-device.
    /// Internal visibility is intentional so the zero-network policy can be
    /// tested through the production decision boundary without exposing it as
    /// public API.
    func prepareCrossfadePlayerItem(for song: Song) async throws -> AVPlayerItem {
        guard let localFile = validatedLocalCrossfadeFile(for: song) else {
            throw CrossfadePreparationError.notLocallyAvailable
        }
        if let crossfadeLocalPreparationBarrier {
            await crossfadeLocalPreparationBarrier(localFile)
        }
        try Task.checkCancellation()

        let asset = AVURLAsset(url: localFile.url)
        return AVPlayerItem(asset: asset)
    }

    /// Prepares crossfade transition for an autoplay song (no queue index).
    /// Starts local-only autoplay crossfade preparation. Returning the task
    /// lets internal policy tests await the real failure path deterministically.
    @discardableResult
    func prepareCrossfadeForAutoplay(nextSong: Song) -> Task<Void, Never> {
        Log.audio.info("Crossfade: preparing autoplay track \(nextSong.title, privacy: .public)")
        let reservation: CrossfadeReservation
        if let existing = crossfadeReservation,
            existing.nextSongID == nextSong.id,
            existing.destination == .autoplay,
            isCrossfadeReservationValid(existing)
        {
            reservation = existing
        } else {
            guard let sourceSongID = currentTrack?.id,
                autoplayQueue.first?.id == nextSong.id
            else { return Task {} }

            attemptedCrossfadeReservation = nil
            attemptedCrossfadeLocalURL = nil
            reservedShuffleProgress = nil
            reservation = CrossfadeReservation(
                sourceSongID: sourceSongID,
                sourceIndex: currentIndex,
                sourceWasAutoplay: isPlayingFromAutoplay,
                nextSongID: nextSong.id,
                destination: .autoplay,
                queueRevision: queueRevision,
                autoplayRevision: autoplayRevision,
                playbackPolicyRevision: playbackPolicyRevision,
                shuffleEnabled: shuffleEnabled,
                repeatMode: repeatMode
            )
            crossfadeReservation = reservation
        }

        return scheduleCrossfadePreparation(for: reservation, nextSong: nextSong) ?? Task {}
    }

    private func startAutoplayCrossfadePlayback(
        with playerItem: AVPlayerItem,
        nextSong: Song,
        token: CrossfadePreparationToken
    ) {
        guard isCrossfadeTokenValid(token),
            let outgoing = player
        else { return }

        let incoming = AVPlayer(playerItem: playerItem)
        incoming.automaticallyWaitsToMinimizeStalling = false
        incoming.volume = 0.0
        incoming.rate = playbackSpeed
        crossfadePlayer = incoming

        if let audioMix = eqProcessor.createAudioMix(for: playerItem.asset) {
            playerItem.audioMix = audioMix
        }

        activeCrossfadeToken = token
        let currentVolume = normalizationEnabled ? normalizedVolume : Float(1.0)
        crossfadeManager.start(
            outgoing: outgoing,
            incoming: incoming,
            volume: currentVolume
        ) { [weak self] in
            guard let self,
                self.activeCrossfadeToken == token,
                self.isCrossfadeTokenValid(token)
            else { return }

            self.activeCrossfadeToken = nil
            // Adopt the incoming player before publishing autoplay state changes.
            // Their observers invalidate speculative work; while the player is
            // still stored in `crossfadePlayer`, that teardown would empty the
            // very item we are committing as active playback.
            self.completeCrossfade(
                incomingPlayer: incoming,
                nextSong: nextSong,
                nextIndex: self.currentIndex,
                localFileURL: self.localCrossfadeURL(for: nextSong)
            )
            if self.autoplayQueue.first?.id == token.reservation.nextSongID {
                self.autoplayQueue.removeFirst()
            }
            self.isPlayingFromAutoplay = true
            self.savePlaybackState()
            if self.autoplayQueue.count <= 2 {
                self.onQueueExhausted?()
            }
        }

        Log.audio.info(
            "Crossfade: incoming autoplay player started for \(nextSong.title, privacy: .public)"
        )
    }

    /// Starts playing the next track on the crossfade player and begins the volume fade.
    private func startCrossfadePlayback(
        with playerItem: AVPlayerItem,
        nextSong: Song,
        nextIndex: Int,
        localFileURL: URL?,
        token: CrossfadePreparationToken
    ) {
        guard isCrossfadeTokenValid(token),
            let outgoing = player
        else { return }

        // Create crossfade player
        let incoming = AVPlayer(playerItem: playerItem)
        incoming.automaticallyWaitsToMinimizeStalling = false
        incoming.volume = 0.0
        incoming.rate = playbackSpeed
        crossfadePlayer = incoming

        // Attach EQ processing tap to the crossfade player item
        if let audioMix = eqProcessor.createAudioMix(for: playerItem.asset) {
            playerItem.audioMix = audioMix
        }

        // Store references for completion
        let capturedIndex = nextIndex
        let capturedSong = nextSong
        let capturedLocalURL = localFileURL

        let currentVolume = normalizationEnabled ? normalizedVolume : Float(1.0)

        activeCrossfadeToken = token
        crossfadeManager.start(
            outgoing: outgoing,
            incoming: incoming,
            volume: currentVolume
        ) { [weak self] in
            guard let self,
                self.activeCrossfadeToken == token,
                self.isCrossfadeTokenValid(token)
            else { return }
            self.commitReservedShuffleProgress(for: token.reservation)
            self.activeCrossfadeToken = nil
            self.completeCrossfade(
                incomingPlayer: incoming,
                nextSong: capturedSong,
                nextIndex: capturedIndex,
                localFileURL: capturedLocalURL
            )
        }

        Log.audio.info("Crossfade: incoming player started for \(nextSong.title, privacy: .public)")
    }

    /// Called when crossfade volume animation finishes. Swaps players and updates state.
    private func completeCrossfade(
        incomingPlayer: AVPlayer,
        nextSong: Song,
        nextIndex: Int,
        localFileURL: URL?
    ) {
        let oldPlayer = player

        // Swap player references — incoming becomes the main player
        player = incomingPlayer
        crossfadePlayer = nil

        // Remove time observer from old player and attach to new one
        if let tObs = timeObserver {
            oldPlayer?.removeTimeObserver(tObs)
            timeObserver = nil
        }
        timeControlObserver?.invalidate()
        timeControlObserver = nil

        // Clean up old player observers
        if let observer = endOfTrackObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfTrackObserver = nil
        }
        if let observer = errorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            errorLogObserver = nil
        }
        if let observer = accessLogObserver {
            NotificationCenter.default.removeObserver(observer)
            accessLogObserver = nil
        }
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        crossfadeItemObservations.forEach { $0.invalidate() }
        crossfadeItemObservations.removeAll()
        recoveryService.stopStallDetection()

        // Clean up old outgoing player
        crossfadeManager.cleanupOutgoingPlayer()
        oldPlayer?.pause()
        oldPlayer?.replaceCurrentItem(with: nil)

        // Update track state
        currentIndex = nextIndex
        currentTrack = nextSong
        currentTime = 0
        isStreamingMode = false
        self.localFileURL = localFileURL
        streamRecoveryAttemptCount = 0
        isReconnecting = false

        // Re-setup observers on new player
        setupPlayerObservers()
        if let item = player?.currentItem {
            setupPlayerItemObserver(item)
        }

        recoveryService.resetRetry()
        recoveryService.startStallDetection()
        crossfadeManager.resetTrigger()

        // Update Now Playing info
        if let item = player?.currentItem,
            item.duration.seconds.isFinite && item.duration.seconds > 0
        {
            duration = item.duration.seconds
        }
        nowPlayingManager.updateNowPlayingInfo(song: nextSong, duration: duration)
        nowPlayingManager.updatePlaybackState(
            isPlaying: isPlaying,
            currentTime: 0,
            rate: Double(playbackSpeed)
        )

        // Trigger pre-fetch for the next-next track
        syncPrefetchDependencies()
        prefetchManager.prefetchNextTrack()

        savePlaybackState()
        Log.audio.info("Crossfade complete: now playing \(nextSong.title, privacy: .public)")
    }

    /// Cleans up the secondary crossfade player and its observers.
    private func cleanupCrossfadePlayer() {
        if let tObs = crossfadeTimeObserver {
            crossfadePlayer?.removeTimeObserver(tObs)
            crossfadeTimeObserver = nil
        }
        crossfadeItemObservations.forEach { $0.invalidate() }
        crossfadeItemObservations.removeAll()
        crossfadePlayer?.pause()
        crossfadePlayer?.replaceCurrentItem(with: nil)
        crossfadePlayer = nil
    }

    /// Reuses an existing AVPlayer via `replaceCurrentItem` to avoid the cost of
    /// tearing down and re-creating the AVPlayer graph on every track change.
    /// Observer setup only happens once — on the first player creation.
    private func configurePlayer(with playerItem: AVPlayerItem) {
        if let existingPlayer = player {
            existingPlayer.replaceCurrentItem(with: playerItem)
        } else {
            player = AVPlayer(playerItem: playerItem)
            setupPlayerObservers()
        }
        player?.automaticallyWaitsToMinimizeStalling = false

        // Attach real-time EQ processing tap to the audio pipeline
        if let audioMix = eqProcessor.createAudioMix(for: playerItem.asset) {
            playerItem.audioMix = audioMix
        }
    }

    /// One-time setup of player-level observers (time observer, time control status).
    /// Called only when a new AVPlayer instance is created.
    private func setupPlayerObservers() {
        setupTimeObserver()
        setupTimeControlObserver()
        NotificationCenter.default.addObserver(
            forName: .premiumStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.revalidatePremiumState()
        }
    }

    private func setupRemoteCommands() {
        remoteCommandManager.onPlay = { [weak self] in self?.playPause() }
        remoteCommandManager.onPause = { [weak self] in self?.playPause() }
        remoteCommandManager.onNext = { [weak self] in self?.next() }
        remoteCommandManager.onPrevious = { [weak self] in self?.previous() }
        remoteCommandManager.onSeek = { [weak self] time in self?.seek(to: time) }
        remoteCommandManager.currentTime = { [weak self] in self?.currentTime ?? 0 }
        remoteCommandManager.duration = { [weak self] in self?.duration ?? 0 }
        remoteCommandManager.setup()
    }

    private func setupAudioProcessingObservers() {
        // Remove old observers first to prevent leaks on re-registration
        if let observer = skipSilenceObserver {
            NotificationCenter.default.removeObserver(observer)
            skipSilenceObserver = nil
        }
        if let observer = normalizationObserver {
            NotificationCenter.default.removeObserver(observer)
            normalizationObserver = nil
        }
        if let observer = equalizerObserver {
            NotificationCenter.default.removeObserver(observer)
            equalizerObserver = nil
        }
        if let observer = crossfadeDurationObserver {
            NotificationCenter.default.removeObserver(observer)
            crossfadeDurationObserver = nil
        }

        // Load initial state from UserDefaults
        skipSilenceEnabled = UserDefaults.standard.bool(forKey: "skipSilence")
        normalizationEnabled = UserDefaults.standard.bool(forKey: "audioNormalization")

        skipSilenceObserver = NotificationCenter.default.addObserver(
            forName: .skipSilenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.skipSilenceEnabled = UserDefaults.standard.bool(forKey: "skipSilence")
                self?.applyAudioProcessing()
            }
        }

        normalizationObserver = NotificationCenter.default.addObserver(
            forName: .audioNormalizationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.normalizationEnabled = UserDefaults.standard.bool(
                    forKey: "audioNormalization")
                self?.applyAudioProcessing()
            }
        }

        equalizerObserver = NotificationCenter.default.addObserver(
            forName: .equalizerChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyEqualizer()
            }
        }

        crossfadeDurationObserver = NotificationCenter.default.addObserver(
            forName: .crossfadeDurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let duration = UserDefaults.standard.double(forKey: "crossfade_duration")
                self?.crossfadeManager.crossfadeDuration = duration
            }
        }
    }

    private func applyAudioProcessing() {
        if skipSilenceEnabled || playbackSpeed != 1.0 {
            player?.currentItem?.audioTimePitchAlgorithm = .timeDomain
        } else {
            player?.currentItem?.audioTimePitchAlgorithm = .timeDomain
        }

        if normalizationEnabled {
            normalizedVolume = 0.85
            player?.volume = normalizedVolume
        } else {
            normalizedVolume = 1.0
            player?.volume = 1.0
        }
    }

    private func applyEqualizer() {
        guard let em = equalizerManager else { return }
        let isActive = em.isEnabled && (isPremiumProvider?() ?? true)
        eqProcessor.updateBands(em.customBands, enabled: isActive)
    }

    /// Re-evaluates premium-gated audio features when premium status changes at runtime.
    func revalidatePremiumState() {
        applyEqualizer()
    }

    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            invalidateCrossfadePreparation(clearReservation: false)
            if isPlaying {
                // Mark as user-initiated so the watchdog doesn't fire recovery loops
                // while the system holds the audio session (phone call, Siri, etc.)
                userInitiatedPause = true
                player?.pause()
                isPlaying = false
            }
        case .ended:
            userInitiatedPause = false
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                resumePlayer()
                isPlaying = true
            }
        @unknown default:
            Log.audio.warning("Unexpected state encountered")
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        if reason == .oldDeviceUnavailable {
            invalidateCrossfadePreparation(clearReservation: false)
            if isPlaying {
                player?.pause()
                isPlaying = false
            }
        }
    }
}

// MARK: - PlaybackRecoveryDelegate

extension AudioEngine: PlaybackRecoveryDelegate {
    // `duration`, `isPlaying`, `isBuffering`, `currentTime` are already declared on AudioEngine.
    var currentTrackID: String? { currentTrack?.id }

    /// Protocol-required entry point (delegates to the full overload).
    func performRecoveryLoadAndPlay(song: Song) {
        performLoadAndPlay(song: song, seekTo: nil)
    }

    func updateRetryState(song: Song, streamURL: String, contentLength: Int64?) {
        if streamURL.isEmpty {
            // Retry failed or no resolver
            isBuffering = false
            lastError =
                streamURLResolver == nil
                ? "No stream URL resolver available for retry"
                : "Retry failed"
        } else {
            streamResolvedAt = Date()
            currentTrack = song
            if currentIndex < queue.count {
                queue[currentIndex].streamURL = streamURL
                queue[currentIndex].streamContentLength = contentLength
            }
        }
    }
}

/// Parse the fMP4 `sidx` (Segment Index) box from a data buffer.
/// Returns (headerEnd, segmentSizes) where headerEnd is the byte offset where
/// audio segments begin, and segmentSizes contains each segment's byte count.
/// Returns (0, []) if no sidx box is found.
private func parseSIDX(_ data: Data) -> (headerEnd: Int, segmentSizes: [Int]) {
    let sidxTag = Data([0x73, 0x69, 0x64, 0x78])  // "sidx"
    guard let tagRange = data.range(of: sidxTag) else { return (0, []) }

    let boxStart = tagRange.lowerBound - 4
    // Minimum sidx box (version=0, 0 entries) = 32 bytes; guard full parse depth.
    guard boxStart >= 0, boxStart + 32 <= data.count else { return (0, []) }

    let boxSize = Int(data[boxStart]) << 24 | Int(data[boxStart + 1]) << 16 |
                  Int(data[boxStart + 2]) << 8 | Int(data[boxStart + 3])
    let headerEnd = boxStart + boxSize

    var p = tagRange.upperBound  // right after "sidx" tag
    let ver = data[p]; p += 1  // version
    p += 3                     // flags
    p += 4                     // reference_id
    p += 4                     // timescale
    if ver == 0 { p += 4 + 4 } else { p += 8 + 8 }  // earliest_pt + first_offset
    p += 2                     // reserved
    guard p + 2 <= data.count else { return (0, []) }
    let refCount = Int(data[p]) << 8 | Int(data[p + 1]); p += 2

    var sizes: [Int] = []
    for _ in 0..<refCount {
        guard p + 4 <= data.count else { break }
        let raw = Int(data[p]) << 24 | Int(data[p + 1]) << 16 |
                  Int(data[p + 2]) << 8 | Int(data[p + 3])
        sizes.append(raw & 0x7FFF_FFFF)  // clear reference_type bit
        p += 12  // size(4) + duration(4) + SAP(4)
    }

    return (headerEnd, sizes)
}
