import Foundation

struct PlaybackSourceAvailability: Equatable, Sendable {
    let hasExplicitDownload: Bool
    let hasValidLocalRemux: Bool
    let rangeEligible: Bool
    let generationFingerprint: LocalGenerationFingerprint
}

struct PlaybackTransferGateDenial: Equatable, Sendable {
    let category: PlaybackFailureCategory
}

enum PlaybackLegacyAttemptFailure: Equatable, Sendable {
    case transport
    case localArtifact
}

struct PlaybackTransferGateAttemptID: Hashable, Sendable {
    let rawValue: UUID

    static func fresh() -> Self {
        Self(rawValue: UUID())
    }
}

struct PlaybackTransferGateAttempt: Equatable, Sendable {
    let id: PlaybackTransferGateAttemptID
    let request: FallbackRequest
    let networkClass: PlaybackNetworkClass
    let networkPathVersion: UInt64
    let replacedLegacySourceAttemptID: SourceAttemptID?

    init(
        id: PlaybackTransferGateAttemptID,
        request: FallbackRequest,
        networkClass: PlaybackNetworkClass,
        networkPathVersion: UInt64 = 0,
        replacedLegacySourceAttemptID: SourceAttemptID? = nil
    ) {
        self.id = id
        self.request = request
        self.networkClass = networkClass
        self.networkPathVersion = networkPathVersion
        self.replacedLegacySourceAttemptID = replacedLegacySourceAttemptID
    }
}

enum PlaybackEffect: Equatable, Sendable {
    case cancelAllEffects
    case cancelAllEffectsAndReleaseLegacy(FallbackAttempt)
    case cancelSeekEffects(SeekRequestID)
    case cancelActiveRangeMonitor(SourceAttemptID)
    case cancelTransferGate(PlaybackTransferGateAttemptID)
    case resolveDescriptor(PlaybackSessionID)
    case startSource(SourceAttempt)
    case evaluateFullResourceTransferGate(PlaybackTransferGateAttempt)
    case releaseReservationAndEvaluateFullResourceTransferGate(
        oldReservationID: StorageReservationID,
        attempt: PlaybackTransferGateAttempt
    )
    case presentFullTransferConsent(PlaybackTransferGateAttempt)
    case releaseStorageReservation(StorageReservationID)
    case startLegacyTransfer(FallbackAttempt)
    case startLegacyRemux(
        FallbackAttempt,
        trackDurationSeconds: TimeInterval
    )
    case startSeek(SeekAttempt)
    case startSeekVerification(SeekAttempt)
    case monitorActiveRange(SourceAttempt)
    case resumeSource(SourceAttempt)
    case retryRangeTransport(SourceAttempt)
    case retrySeekUpstream(SeekAttempt)
    case retryLegacyRemux(
        FallbackAttempt,
        trackDurationSeconds: TimeInterval
    )

    fileprivate var taskID: PlaybackEffectID? {
        switch self {
        case .cancelAllEffects, .cancelAllEffectsAndReleaseLegacy,
            .cancelSeekEffects, .cancelActiveRangeMonitor,
            .cancelTransferGate:
            return nil
        case .resolveDescriptor(let sessionID):
            return .resolution(sessionID)
        case .startSource(let attempt),
            .monitorActiveRange(let attempt),
            .resumeSource(let attempt),
            .retryRangeTransport(let attempt):
            return .source(attempt.id)
        case .evaluateFullResourceTransferGate(let attempt),
            .releaseReservationAndEvaluateFullResourceTransferGate(_, let attempt),
            .presentFullTransferConsent(let attempt):
            return .transferGate(attempt.id)
        case .releaseStorageReservation(let reservationID):
            return .reservationRelease(reservationID)
        case .startLegacyTransfer(let attempt):
            return .legacyTransfer(attempt.sourceAttempt.id)
        case .startSeek(let attempt):
            return .seekUpstream(attempt.id)
        case .retrySeekUpstream(let attempt):
            return .seekUpstream(attempt.id)
        case .startSeekVerification(let attempt):
            return .seekVerification(attempt.id)
        case .startLegacyRemux(let attempt, _),
            .retryLegacyRemux(let attempt, _):
            return .legacyRemux(attempt.sourceAttempt.id)
        }
    }
}

enum PlaybackEffectID: Hashable, Sendable {
    case resolution(PlaybackSessionID)
    case source(SourceAttemptID)
    case transferGate(PlaybackTransferGateAttemptID)
    case reservationRelease(StorageReservationID)
    case legacyTransfer(SourceAttemptID)
    case legacyRemux(SourceAttemptID)
    case seekUpstream(SeekRequestID)
    case seekVerification(SeekRequestID)
}

enum PlaybackEvent: Equatable, Sendable {
    case replaceSession(
        sessionID: PlaybackSessionID,
        desiredIntent: DesiredPlaybackIntent,
        initialPosition: TimeInterval
    )
    case userSkipped(
        to: PlaybackSessionID,
        desiredIntent: DesiredPlaybackIntent,
        initialPosition: TimeInterval
    )
    case descriptorResolved(
        sessionID: PlaybackSessionID,
        sources: PlaybackSourceAvailability
    )
    case descriptorResolutionFailed(
        sessionID: PlaybackSessionID,
        category: PlaybackFailureCategory
    )
    case sourceBecamePlayable(SourceAttempt)
    case requestSeek(targetSeconds: TimeInterval)
    case seekPrepared(SeekAttempt)
    case seekVerified(SeekAttempt, confirmedPosition: TimeInterval)
    case userPaused
    case userPlayed
    case requestLegacyFallback(
        sourceAttempt: SourceAttempt,
        token: FailedActionToken
    )
    case fullTransferGateRequiresConsent(PlaybackTransferGateAttempt)
    case fullTransferGateAllowed(
        PlaybackTransferGateAttempt,
        reservationID: StorageReservationID
    )
    case transferConsentAccepted(
        PlaybackTransferGateAttempt,
        reservationID: StorageReservationID
    )
    case releaseOrphanedTransferReservation(StorageReservationID)
    case transferConsentDeclined(PlaybackTransferGateAttempt)
    case fullTransferGateDenied(
        PlaybackTransferGateAttempt,
        denial: PlaybackTransferGateDenial
    )
    case networkClassChanged(PlaybackNetworkClass)
    case networkSnapshotChanged(NetworkSnapshot)
    case legacyPolicyCancellationTimedOut(PlaybackTransferGateAttemptID)
    case legacyTransferCompleted(
        FallbackAttempt,
        trackDurationSeconds: TimeInterval
    )
    case legacyTransferFailed(
        FallbackAttempt,
        currentNetwork: NetworkSnapshot,
        failure: PlaybackLegacyAttemptFailure
    )
    case legacyRemuxSucceeded(FallbackAttempt)
    case legacyRemuxFailed(FallbackAttempt)
    case watchdogStarted(
        kind: PlaybackWatchdogKind,
        token: PlaybackWatchdogToken
    )
    case watchdogStopped(
        kind: PlaybackWatchdogKind,
        token: PlaybackWatchdogToken
    )
    case watchdogExpired(PlaybackWatchdogExpiry)
    case watchdogCancellationTimedOut(PlaybackWatchdogExpiry)
    case stop
}

private enum PlaybackWatchdogScope: Hashable, Sendable {
    case resolver(PlaybackSessionID)
    case initialRange(PlaybackSessionID, SourceAttemptID)
    case activeRange(PlaybackSessionID, SourceAttemptID)
    case seekUpstream(PlaybackSessionID, SourceAttemptID, SeekRequestID)
    case seekVerification(PlaybackSessionID, SourceAttemptID, SeekRequestID)
    case legacyDownload(PlaybackSessionID, SourceAttemptID)
    case legacyRemux(PlaybackSessionID, SourceAttemptID)
}

private struct ActivePlaybackWatchdog: Equatable, Sendable {
    let kind: PlaybackWatchdogKind
    let token: PlaybackWatchdogToken
}

private enum PlaybackTransferGateStage: Equatable, Sendable {
    case evaluating
    case awaitingUserDecision
}

private enum PlaybackTransferGateReason: Equatable, Sendable {
    case initial
    case transportRetry
    case policyRevalidation
}

private struct PendingPlaybackTransferGate: Equatable, Sendable {
    var attempt: PlaybackTransferGateAttempt
    var stage: PlaybackTransferGateStage
    let replacedLegacyAttempt: FallbackAttempt?
    let reason: PlaybackTransferGateReason
}

struct PlaybackSessionState: Equatable, Sendable {
    private(set) var phase: PlaybackPhase
    private(set) var selectedSource: PlaybackSource?
    private(set) var desiredPlaybackIntent: DesiredPlaybackIntent
    private(set) var latestRequestedTarget: TimeInterval?
    private(set) var lastConfirmedPosition: TimeInterval
    var sessionBudget: PlaybackSessionFailureBudget
    private(set) var consumedConsentTokens: Set<FailedActionToken>
    private(set) var resourceGenerationFingerprint: LocalGenerationFingerprint?
    private(set) var networkClass: PlaybackNetworkClass = .wifiUnconstrained
    private(set) var networkSnapshot: NetworkSnapshot = .wifi(
        expensive: false,
        constrained: false
    )
    private var activeWatchdogs: [PlaybackWatchdogScope: ActivePlaybackWatchdog] = [:]
    private var pendingTransferGate: PendingPlaybackTransferGate? = nil
    private var releasedReservationIDs: Set<StorageReservationID> = []
    private var activeLegacyToken: FailedActionToken? = nil
    private var activeLegacyStartedMetered = false

    static let idle = Self(
        phase: .idle,
        selectedSource: nil,
        desiredPlaybackIntent: .paused,
        latestRequestedTarget: nil,
        lastConfirmedPosition: 0,
        sessionBudget: .initial,
        consumedConsentTokens: [],
        resourceGenerationFingerprint: nil
    )

    init(
        phase: PlaybackPhase,
        selectedSource: PlaybackSource?,
        desiredPlaybackIntent: DesiredPlaybackIntent,
        latestRequestedTarget: TimeInterval?,
        lastConfirmedPosition: TimeInterval,
        sessionBudget: PlaybackSessionFailureBudget,
        consumedConsentTokens: Set<FailedActionToken>,
        resourceGenerationFingerprint: LocalGenerationFingerprint?
    ) {
        self.phase = phase
        self.selectedSource = selectedSource
        self.desiredPlaybackIntent = desiredPlaybackIntent
        self.latestRequestedTarget = latestRequestedTarget
        self.lastConfirmedPosition = lastConfirmedPosition
        self.sessionBudget = sessionBudget
        self.consumedConsentTokens = consumedConsentTokens
        self.resourceGenerationFingerprint = resourceGenerationFingerprint
    }

    var activeSessionID: PlaybackSessionID? {
        switch phase {
        case .idle, .failed:
            return nil
        case .resolving(let sessionID):
            return sessionID
        case .preparing(let attempt), .playing(let attempt), .paused(let attempt):
            return attempt.sessionID
        case .seeking(let seek),
            .seekPreparedWhilePaused(let seek),
            .verifyingSeek(let seek):
            return seek.sourceAttempt.sessionID
        case .awaitingTransferConsent(let request):
            return request.sourceAttempt.sessionID
        case .legacyDownloading(let attempt), .legacyRemuxing(let attempt):
            return attempt.sourceAttempt.sessionID
        }
    }

    var activeSourceAttempt: SourceAttempt? {
        switch phase {
        case .preparing(let attempt), .playing(let attempt), .paused(let attempt):
            return attempt
        case .seeking(let seek),
            .seekPreparedWhilePaused(let seek),
            .verifyingSeek(let seek):
            return seek.sourceAttempt
        case .awaitingTransferConsent(let request):
            return request.sourceAttempt
        case .legacyDownloading(let attempt), .legacyRemuxing(let attempt):
            return attempt.sourceAttempt
        case .idle, .resolving, .failed:
            return nil
        }
    }

    var activeSeekAttempt: SeekAttempt? {
        switch phase {
        case .seeking(let attempt),
            .seekPreparedWhilePaused(let attempt),
            .verifyingSeek(let attempt):
            return attempt
        case .idle, .resolving, .preparing, .playing, .paused,
            .awaitingTransferConsent, .legacyDownloading, .legacyRemuxing, .failed:
            return nil
        }
    }

    var pendingFallbackRequest: FallbackRequest? {
        guard case .awaitingTransferConsent(let request) = phase else { return nil }
        return request
    }

    var pendingTransferGateAttempt: PlaybackTransferGateAttempt? {
        pendingTransferGate?.attempt
    }

    mutating func reduce(_ event: PlaybackEvent) -> [PlaybackEffect] {
        switch event {
        case .networkClassChanged(let networkClass):
            return handleNetworkClassChanged(networkClass)

        case .networkSnapshotChanged(let snapshot):
            return handleNetworkSnapshotChanged(snapshot)

        case .legacyPolicyCancellationTimedOut(let attemptID):
            guard let gate = pendingTransferGate,
                gate.attempt.id == attemptID,
                gate.reason == .policyRevalidation
            else {
                return []
            }
            pendingTransferGate = nil
            fail(category: .transport)
            return [.cancelTransferGate(attemptID)]

        case .replaceSession(let sessionID, let desiredIntent, let initialPosition),
            .userSkipped(let sessionID, let desiredIntent, let initialPosition):
            return replaceSession(
                sessionID: sessionID,
                desiredIntent: desiredIntent,
                initialPosition: initialPosition
            )

        case .descriptorResolved(let sessionID, let sources):
            return routeResolvedDescriptor(sessionID: sessionID, sources: sources)

        case .descriptorResolutionFailed(let sessionID, let category):
            guard case .resolving(let activeSessionID) = phase,
                activeSessionID == sessionID
            else {
                return []
            }
            if sessionBudget.consume(.resolverRetry) {
                return [.resolveDescriptor(sessionID)]
            }
            fail(category: category)
            return []

        case .sourceBecamePlayable(let attempt):
            guard case .preparing(let currentAttempt) = phase,
                currentAttempt == attempt,
                selectedSource == attempt.source
            else {
                return []
            }
            phase = desiredPlaybackIntent == .playing
                ? .playing(attempt)
                : .paused(attempt)
            if desiredPlaybackIntent == .playing,
                attempt.source == .rangeStream
            {
                return [.monitorActiveRange(attempt)]
            }
            return []

        case .requestSeek(let targetSeconds):
            return requestSeek(targetSeconds: targetSeconds)

        case .seekPrepared(let attempt):
            guard case .seeking(let currentAttempt) = phase,
                currentAttempt == attempt
            else {
                return []
            }
            if desiredPlaybackIntent == .paused {
                phase = .seekPreparedWhilePaused(attempt)
                return []
            }
            phase = .verifyingSeek(attempt)
            return [.startSeekVerification(attempt)]

        case .seekVerified(let attempt, let confirmedPosition):
            guard case .verifyingSeek(let currentAttempt) = phase,
                currentAttempt == attempt,
                confirmedPosition.isFinite,
                confirmedPosition >= 0
            else {
                return []
            }
            lastConfirmedPosition = confirmedPosition
            if desiredPlaybackIntent == .playing {
                phase = .playing(attempt.sourceAttempt)
                if attempt.sourceAttempt.source == .rangeStream {
                    return [.monitorActiveRange(attempt.sourceAttempt)]
                }
            } else {
                phase = .seekPreparedWhilePaused(attempt)
            }
            return []

        case .userPaused:
            desiredPlaybackIntent = .paused
            switch phase {
            case .playing(let attempt):
                phase = .paused(attempt)
                return []
            case .verifyingSeek(let attempt):
                phase = .seekPreparedWhilePaused(attempt)
                return [.cancelSeekEffects(attempt.id)]
            case .awaitingTransferConsent(let request):
                updatePendingTransferRequest(
                    replacing(request, intent: .paused)
                )
                return []
            case .legacyDownloading(let attempt):
                phase = .legacyDownloading(replacing(attempt, intent: .paused))
                return []
            case .legacyRemuxing(let attempt):
                phase = .legacyRemuxing(replacing(attempt, intent: .paused))
                return []
            case .idle, .resolving, .preparing, .paused, .seeking,
                .seekPreparedWhilePaused, .failed:
                return []
            }

        case .userPlayed:
            desiredPlaybackIntent = .playing
            switch phase {
            case .paused(let attempt):
                phase = .playing(attempt)
                return [.resumeSource(attempt)]
            case .seekPreparedWhilePaused(let attempt):
                phase = .verifyingSeek(attempt)
                return [.startSeekVerification(attempt)]
            case .awaitingTransferConsent(let request):
                updatePendingTransferRequest(
                    replacing(request, intent: .playing)
                )
                return []
            case .legacyDownloading(let attempt):
                phase = .legacyDownloading(replacing(attempt, intent: .playing))
                return []
            case .legacyRemuxing(let attempt):
                phase = .legacyRemuxing(replacing(attempt, intent: .playing))
                return []
            case .idle, .resolving, .preparing, .playing, .seeking,
                .verifyingSeek, .failed:
                return []
            }

        case .requestLegacyFallback(let sourceAttempt, let token):
            guard selectedSource == .rangeStream,
                activeSourceAttempt == sourceAttempt,
                sourceAttempt.source == .rangeStream,
                token.sessionID == sourceAttempt.sessionID,
                token.generationFingerprint == resourceGenerationFingerprint,
                pendingTransferGate == nil
            else {
                return []
            }
            return beginLegacyGate(
                sourceAttempt: sourceAttempt,
                token: token,
                targetSeconds: latestRequestedTarget ?? lastConfirmedPosition
            )

        case .fullTransferGateRequiresConsent(let callbackAttempt):
            guard var pendingGate = pendingTransferGate(
                matching: callbackAttempt
            ),
                pendingGate.stage == .evaluating,
                !consumedConsentTokens.contains(pendingGate.attempt.request.token),
                sessionBudget.consume(
                    .consentPrompt(pendingGate.attempt.request.token)
                )
            else {
                return []
            }
            consumedConsentTokens.insert(pendingGate.attempt.request.token)
            pendingGate.stage = .awaitingUserDecision
            pendingTransferGate = pendingGate
            return [.presentFullTransferConsent(pendingGate.attempt)]

        case .fullTransferGateAllowed(let callbackAttempt, let reservationID):
            guard let pendingGate = pendingTransferGate(
                matching: callbackAttempt
            ) else {
                return releaseRejectedReservation(reservationID)
            }
            guard pendingGate.stage == .evaluating else {
                return releaseRejectedReservation(reservationID)
            }
            return commitLegacy(
                pendingGate: pendingGate,
                reservationID: reservationID
            )

        case .transferConsentAccepted(let callbackAttempt, let reservationID):
            guard let pendingGate = pendingTransferGate(
                matching: callbackAttempt
            ) else {
                return releaseRejectedReservation(reservationID)
            }
            guard pendingGate.stage == .awaitingUserDecision,
                consumedConsentTokens.contains(pendingGate.attempt.request.token)
            else {
                return releaseRejectedReservation(reservationID)
            }
            return commitLegacy(
                pendingGate: pendingGate,
                reservationID: reservationID
            )

        case .releaseOrphanedTransferReservation(let reservationID):
            return releaseRejectedReservation(reservationID)

        case .transferConsentDeclined(let callbackAttempt):
            guard let pendingGate = pendingTransferGate(
                matching: callbackAttempt
            ),
                pendingGate.stage == .awaitingUserDecision,
                consumedConsentTokens.contains(pendingGate.attempt.request.token)
            else {
                return []
            }
            let request = pendingGate.attempt.request
            phase = .failed(
                PlaybackFailure(
                    category: request.token.failureCategory,
                    isRecoverable: true,
                    lastConfirmedPosition: lastConfirmedPosition
                )
            )
            pendingTransferGate = nil
            return [.cancelTransferGate(pendingGate.attempt.id)]

        case .fullTransferGateDenied(let callbackAttempt, let denial):
            guard let pendingGate = pendingTransferGate(
                matching: callbackAttempt
            ) else {
                return []
            }
            phase = .failed(
                PlaybackFailure(
                    category: denial.category,
                    isRecoverable: true,
                    lastConfirmedPosition: lastConfirmedPosition
                )
            )
            pendingTransferGate = nil
            return [.cancelTransferGate(pendingGate.attempt.id)]

        case .legacyTransferCompleted(let callbackAttempt, let trackDurationSeconds):
            guard case .legacyDownloading(let currentAttempt) = phase,
                currentAttempt.sourceAttempt == callbackAttempt.sourceAttempt,
                currentAttempt.reservationID == callbackAttempt.reservationID
            else {
                return []
            }
            phase = .legacyRemuxing(currentAttempt)
            return [
                .startLegacyRemux(
                    currentAttempt,
                    trackDurationSeconds: trackDurationSeconds
                )
            ]

        case .legacyTransferFailed(
            let callbackAttempt,
            let currentNetwork,
            let failure
        ):
            guard case .legacyDownloading(let currentAttempt) = phase,
                currentAttempt.sourceAttempt == callbackAttempt.sourceAttempt,
                currentAttempt.reservationID == callbackAttempt.reservationID
            else {
                return []
            }
            networkSnapshot = currentNetwork
            networkClass = currentNetwork.classification
            guard failure == .transport else {
                fail(category: .storage)
                return releaseRejectedReservation(currentAttempt.reservationID)
            }
            let retryCounter: FailureCounter = !activeLegacyStartedMetered
                ? .legacyWiFiTransportRetry
                : .legacyMeteredTransportRetry
            if sessionBudget.consume(retryCounter) {
                return beginLegacyTransportRetry(currentAttempt)
            }
            fail(category: .transport)
            return releaseRejectedReservation(currentAttempt.reservationID)

        case .legacyRemuxSucceeded(let callbackAttempt):
            return handleLegacyRemuxSuccess(callbackAttempt)

        case .legacyRemuxFailed(let callbackAttempt):
            guard case .legacyRemuxing(let currentAttempt) = phase,
                currentAttempt.sourceAttempt == callbackAttempt.sourceAttempt,
                currentAttempt.reservationID == callbackAttempt.reservationID
            else {
                return []
            }
            if sessionBudget.consume(.legacyRemuxRetry) {
                return [
                    .retryLegacyRemux(
                        currentAttempt,
                        trackDurationSeconds: 0
                    )
                ]
            }
            fail(category: .remux)
            return releaseRejectedReservation(currentAttempt.reservationID)

        case .watchdogStarted(let kind, let token):
            guard accepts(kind: kind, token: token),
                let scope = watchdogScope(for: kind, token: token)
            else {
                return []
            }
            activeWatchdogs[scope] = ActivePlaybackWatchdog(
                kind: kind,
                token: token
            )
            return []

        case .watchdogStopped(let kind, let token):
            guard let scope = watchdogScope(for: kind, token: token),
                activeWatchdogs[scope] == ActivePlaybackWatchdog(
                    kind: kind,
                    token: token
                )
            else {
                return []
            }
            activeWatchdogs.removeValue(forKey: scope)
            return []

        case .watchdogExpired(let expiry):
            return handleWatchdogExpiry(expiry)

        case .watchdogCancellationTimedOut(let expiry):
            return handleWatchdogCancellationTimeout(expiry)

        case .stop:
            let currentNetworkSnapshot = networkSnapshot
            let legacyAttempt = activeLegacyAttempt
            self = .idle
            configureInitialNetworkSnapshot(currentNetworkSnapshot)
            if let legacyAttempt {
                return [.cancelAllEffectsAndReleaseLegacy(legacyAttempt)]
            }
            return [.cancelAllEffects]
        }
    }

    private mutating func replaceSession(
        sessionID: PlaybackSessionID,
        desiredIntent: DesiredPlaybackIntent,
        initialPosition: TimeInterval
    ) -> [PlaybackEffect] {
        let legacyAttempt = activeLegacyAttempt
        let safePosition = initialPosition.isFinite && initialPosition >= 0
            ? initialPosition
            : 0
        phase = .resolving(sessionID)
        selectedSource = nil
        desiredPlaybackIntent = desiredIntent
        latestRequestedTarget = nil
        lastConfirmedPosition = safePosition
        sessionBudget = .initial
        consumedConsentTokens = []
        resourceGenerationFingerprint = nil
        activeWatchdogs.removeAll()
        pendingTransferGate = nil
        releasedReservationIDs.removeAll()
        activeLegacyToken = nil
        activeLegacyStartedMetered = false
        let cancellation: PlaybackEffect = legacyAttempt.map {
            .cancelAllEffectsAndReleaseLegacy($0)
        } ?? .cancelAllEffects
        return [cancellation, .resolveDescriptor(sessionID)]
    }

    private var activeLegacyAttempt: FallbackAttempt? {
        switch phase {
        case .legacyDownloading(let attempt), .legacyRemuxing(let attempt):
            return attempt
        case .idle, .resolving, .preparing, .playing, .paused, .seeking,
            .seekPreparedWhilePaused, .verifyingSeek, .awaitingTransferConsent,
            .failed:
            return nil
        }
    }

    fileprivate var activeLegacyAttemptForCleanup: FallbackAttempt? {
        activeLegacyAttempt
    }

    private mutating func routeResolvedDescriptor(
        sessionID: PlaybackSessionID,
        sources: PlaybackSourceAvailability
    ) -> [PlaybackEffect] {
        guard case .resolving(let activeSessionID) = phase,
            activeSessionID == sessionID,
            selectedSource == nil
        else {
            return []
        }

        resourceGenerationFingerprint = sources.generationFingerprint
        if sources.hasExplicitDownload {
            return selectSource(.explicitDownload, sessionID: sessionID)
        }
        if sources.hasValidLocalRemux {
            return selectSource(.remuxCache, sessionID: sessionID)
        }
        if sources.rangeEligible {
            return selectSource(.rangeStream, sessionID: sessionID)
        }

        let legacyCandidate = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .legacyDownloadRemux
        )
        let token = FailedActionToken(
            sessionID: sessionID,
            actionID: .fresh(),
            generationFingerprint: sources.generationFingerprint,
            failureCategory: .structuralCompatibility,
            intent: .initialPlayback
        )
        return beginLegacyGate(
            sourceAttempt: legacyCandidate,
            token: token,
            targetSeconds: latestRequestedTarget ?? lastConfirmedPosition
        )
    }

    private mutating func selectSource(
        _ source: PlaybackSource,
        sessionID: PlaybackSessionID
    ) -> [PlaybackEffect] {
        guard selectedSource == nil, source != .legacyDownloadRemux else { return [] }
        let attempt = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: source
        )
        selectedSource = source
        phase = .preparing(attempt)
        return [.startSource(attempt)]
    }

    private mutating func requestSeek(targetSeconds: TimeInterval) -> [PlaybackEffect] {
        guard targetSeconds.isFinite, targetSeconds >= 0 else { return [] }
        latestRequestedTarget = targetSeconds

        if case .awaitingTransferConsent(let request) = phase {
            updatePendingTransferRequest(
                replacing(
                    request,
                    targetSeconds: targetSeconds,
                    intent: desiredPlaybackIntent
                )
            )
            return []
        }
        if case .legacyDownloading(let attempt) = phase {
            phase = .legacyDownloading(replacing(attempt, targetSeconds: targetSeconds))
            return []
        }
        if case .legacyRemuxing(let attempt) = phase {
            phase = .legacyRemuxing(replacing(attempt, targetSeconds: targetSeconds))
            return []
        }

        guard let sourceAttempt = seekableSourceAttempt else { return [] }
        let obsoleteSeek = activeSeekAttempt
        let shouldCancelActiveRangeMonitor: Bool
        if case .playing(let playingAttempt) = phase {
            shouldCancelActiveRangeMonitor = playingAttempt == sourceAttempt
                && sourceAttempt.source == .rangeStream
        } else {
            shouldCancelActiveRangeMonitor = false
        }
        let attempt = SeekAttempt(
            sourceAttempt: sourceAttempt,
            id: .fresh(),
            targetSeconds: targetSeconds
        )
        phase = .seeking(attempt)

        var effects: [PlaybackEffect] = []
        if shouldCancelActiveRangeMonitor {
            effects.append(.cancelActiveRangeMonitor(sourceAttempt.id))
        }
        if let obsoleteSeek {
            effects.append(.cancelSeekEffects(obsoleteSeek.id))
        }
        effects.append(.startSeek(attempt))
        return effects
    }

    private var seekableSourceAttempt: SourceAttempt? {
        switch phase {
        case .playing(let attempt), .paused(let attempt):
            return attempt
        case .seeking(let attempt),
            .seekPreparedWhilePaused(let attempt),
            .verifyingSeek(let attempt):
            return attempt.sourceAttempt
        case .idle, .resolving, .preparing, .awaitingTransferConsent,
            .legacyDownloading, .legacyRemuxing, .failed:
            return nil
        }
    }

    private mutating func beginLegacyGate(
        sourceAttempt: SourceAttempt,
        token: FailedActionToken,
        targetSeconds: TimeInterval
    ) -> [PlaybackEffect] {
        let legacyCandidate: SourceAttempt
        if sourceAttempt.source == .legacyDownloadRemux {
            legacyCandidate = sourceAttempt
        } else {
            legacyCandidate = SourceAttempt(
                sessionID: sourceAttempt.sessionID,
                id: .fresh(),
                source: .legacyDownloadRemux
            )
        }
        let request = FallbackRequest(
            sourceAttempt: legacyCandidate,
            targetSeconds: targetSeconds,
            intent: desiredPlaybackIntent,
            token: token
        )
        return beginTransferGate(request: request)
    }

    private mutating func beginTransferGate(
        request: FallbackRequest,
        replacingLegacyAttempt: FallbackAttempt? = nil,
        reason: PlaybackTransferGateReason = .initial
    ) -> [PlaybackEffect] {
        let attempt = PlaybackTransferGateAttempt(
            id: .fresh(),
            request: request,
            networkClass: networkClass,
            networkPathVersion: networkSnapshot.pathVersion,
            replacedLegacySourceAttemptID: replacingLegacyAttempt?.sourceAttempt.id
        )
        pendingTransferGate = PendingPlaybackTransferGate(
            attempt: attempt,
            stage: .evaluating,
            replacedLegacyAttempt: replacingLegacyAttempt,
            reason: reason
        )
        phase = .awaitingTransferConsent(request)

        if let replacingLegacyAttempt {
            return [
                .releaseReservationAndEvaluateFullResourceTransferGate(
                    oldReservationID: replacingLegacyAttempt.reservationID,
                    attempt: attempt
                )
            ]
        }
        return [.evaluateFullResourceTransferGate(attempt)]
    }

    private mutating func handleNetworkClassChanged(
        _ newNetworkClass: PlaybackNetworkClass
    ) -> [PlaybackEffect] {
        guard newNetworkClass != networkClass else { return [] }
        let nextPathVersion = networkSnapshot.pathVersion &+ 1
        let snapshot: NetworkSnapshot
        switch newNetworkClass {
        case .wifiUnconstrained:
            snapshot = .wifi(
                expensive: false,
                constrained: false,
                pathVersion: nextPathVersion
            )
        case .cellular:
            snapshot = .cellular(
                constrained: false,
                pathVersion: nextPathVersion
            )
        case .constrained:
            snapshot = NetworkSnapshot(
                classification: .constrained,
                isExpensive: networkSnapshot.isExpensive,
                isConstrained: true,
                usesWiFi: networkSnapshot.usesWiFi,
                usesCellular: networkSnapshot.usesCellular,
                pathVersion: nextPathVersion
            )
        case .offline:
            snapshot = NetworkSnapshot(
                classification: .offline,
                isExpensive: false,
                isConstrained: false,
                usesWiFi: false,
                usesCellular: false,
                pathVersion: nextPathVersion
            )
        }
        return handleNetworkSnapshotChanged(snapshot)
    }

    private mutating func handleNetworkSnapshotChanged(
        _ newSnapshot: NetworkSnapshot
    ) -> [PlaybackEffect] {
        let previousSnapshot = networkSnapshot
        guard newSnapshot != previousSnapshot else { return [] }
        networkSnapshot = newSnapshot
        networkClass = newSnapshot.classification

        let policyChanged = previousSnapshot.classification != newSnapshot.classification
            || previousSnapshot.isExpensive != newSnapshot.isExpensive
            || previousSnapshot.isConstrained != newSnapshot.isConstrained
            || previousSnapshot.usesWiFi != newSnapshot.usesWiFi
            || previousSnapshot.usesCellular != newSnapshot.usesCellular
        guard policyChanged else { return [] }

        if case .legacyDownloading(let fallback) = phase,
            let token = activeLegacyToken
        {
            let revalidationToken: FailedActionToken
            if consumedConsentTokens.contains(token) {
                revalidationToken = FailedActionToken(
                    sessionID: token.sessionID,
                    actionID: .fresh(),
                    generationFingerprint: token.generationFingerprint,
                    failureCategory: token.failureCategory,
                    intent: token.intent
                )
            } else {
                revalidationToken = token
            }
            let revalidationSourceAttempt = SourceAttempt(
                sessionID: fallback.sourceAttempt.sessionID,
                id: .fresh(),
                source: .legacyDownloadRemux
            )
            let request = FallbackRequest(
                sourceAttempt: revalidationSourceAttempt,
                targetSeconds: latestRequestedTarget ?? fallback.targetSeconds,
                intent: desiredPlaybackIntent,
                token: revalidationToken
            )
            releasedReservationIDs.insert(fallback.reservationID)
            return beginTransferGate(
                request: request,
                replacingLegacyAttempt: fallback,
                reason: .policyRevalidation
            )
        }

        guard let currentGate = pendingTransferGate,
            case .awaitingTransferConsent = phase
        else {
            return []
        }

        if currentGate.stage == .awaitingUserDecision {
            fail(category: currentGate.attempt.request.token.failureCategory)
            pendingTransferGate = nil
            return [.cancelTransferGate(currentGate.attempt.id)]
        }

        let refreshedAttempt = PlaybackTransferGateAttempt(
            id: .fresh(),
            request: currentGate.attempt.request,
            networkClass: newSnapshot.classification,
            networkPathVersion: newSnapshot.pathVersion,
            replacedLegacySourceAttemptID: currentGate.attempt
                .replacedLegacySourceAttemptID
        )
        pendingTransferGate = PendingPlaybackTransferGate(
            attempt: refreshedAttempt,
            stage: .evaluating,
            replacedLegacyAttempt: currentGate.replacedLegacyAttempt,
            reason: currentGate.reason
        )

        var effects: [PlaybackEffect] = [
            .cancelTransferGate(currentGate.attempt.id)
        ]
        if let replacedLegacyAttempt = currentGate.replacedLegacyAttempt {
            effects.append(
                .releaseReservationAndEvaluateFullResourceTransferGate(
                    oldReservationID: replacedLegacyAttempt.reservationID,
                    attempt: refreshedAttempt
                )
            )
        } else {
            effects.append(.evaluateFullResourceTransferGate(refreshedAttempt))
        }
        return effects
    }

    private mutating func updatePendingTransferRequest(
        _ request: FallbackRequest
    ) {
        phase = .awaitingTransferConsent(request)
        guard var pendingGate = pendingTransferGate,
            pendingGate.attempt.request.token == request.token,
            pendingGate.attempt.request.sourceAttempt == request.sourceAttempt
        else {
            return
        }
        pendingGate.attempt = PlaybackTransferGateAttempt(
            id: pendingGate.attempt.id,
            request: request,
            networkClass: pendingGate.attempt.networkClass,
            networkPathVersion: pendingGate.attempt.networkPathVersion,
            replacedLegacySourceAttemptID: pendingGate.attempt
                .replacedLegacySourceAttemptID
        )
        pendingTransferGate = pendingGate
    }

    private mutating func commitLegacy(
        pendingGate: PendingPlaybackTransferGate,
        reservationID: StorageReservationID
    ) -> [PlaybackEffect] {
        guard pendingTransferGate == pendingGate,
            pendingFallbackRequest == pendingGate.attempt.request
        else {
            return []
        }
        let request = pendingGate.attempt.request

        if pendingGate.replacedLegacyAttempt?.reservationID == reservationID {
            fail(category: .storage)
            pendingTransferGate = nil
            return [.cancelTransferGate(pendingGate.attempt.id)]
        }

        if selectedSource == .rangeStream {
            guard sessionBudget.consume(.rangeToLegacyDowngrade) else {
                phase = .failed(
                    PlaybackFailure(
                        category: request.token.failureCategory,
                        isRecoverable: true,
                        lastConfirmedPosition: lastConfirmedPosition
                    )
                )
                pendingTransferGate = nil
                return failGateAndReleaseReservation(
                    gateAttemptID: pendingGate.attempt.id,
                    reservationID: reservationID
                )
            }
        } else if selectedSource == .legacyDownloadRemux {
            guard pendingGate.reason == .policyRevalidation
                || (pendingGate.reason == .transportRetry
                    && request.token.intent == .transportRetry)
            else {
                fail(category: request.token.failureCategory)
                pendingTransferGate = nil
                return failGateAndReleaseReservation(
                    gateAttemptID: pendingGate.attempt.id,
                    reservationID: reservationID
                )
            }
        } else if selectedSource != nil {
            fail(category: request.token.failureCategory)
            pendingTransferGate = nil
            return failGateAndReleaseReservation(
                gateAttemptID: pendingGate.attempt.id,
                reservationID: reservationID
            )
        }

        guard request.sourceAttempt.source == .legacyDownloadRemux else {
            fail(category: request.token.failureCategory)
            pendingTransferGate = nil
            return failGateAndReleaseReservation(
                gateAttemptID: pendingGate.attempt.id,
                reservationID: reservationID
            )
        }
        let fallback = FallbackAttempt(
            sourceAttempt: request.sourceAttempt,
            targetSeconds: request.targetSeconds,
            intent: request.intent,
            reservationID: reservationID
        )
        selectedSource = .legacyDownloadRemux
        activeLegacyToken = request.token
        activeLegacyStartedMetered = networkSnapshot.classification != .wifiUnconstrained
            || networkSnapshot.isExpensive
            || networkSnapshot.isConstrained
        phase = .legacyDownloading(fallback)
        pendingTransferGate = nil
        return [.startLegacyTransfer(fallback)]
    }

    private mutating func releaseRejectedReservation(
        _ reservationID: StorageReservationID
    ) -> [PlaybackEffect] {
        guard activeStorageReservationID != reservationID else {
            return []
        }
        return releaseStorageReservationOnce(reservationID)
    }

    private mutating func releaseStorageReservationOnce(
        _ reservationID: StorageReservationID
    ) -> [PlaybackEffect] {
        guard releasedReservationIDs.insert(reservationID).inserted else {
            return []
        }
        return [.releaseStorageReservation(reservationID)]
    }

    private var activeStorageReservationID: StorageReservationID? {
        switch phase {
        case .legacyDownloading(let attempt), .legacyRemuxing(let attempt):
            return attempt.reservationID
        case .idle, .resolving, .preparing, .playing, .paused, .seeking,
            .seekPreparedWhilePaused, .verifyingSeek, .awaitingTransferConsent,
            .failed:
            return nil
        }
    }

    private mutating func failGateAndReleaseReservation(
        gateAttemptID: PlaybackTransferGateAttemptID,
        reservationID: StorageReservationID
    ) -> [PlaybackEffect] {
        [.cancelTransferGate(gateAttemptID)]
            + releaseRejectedReservation(reservationID)
    }

    private mutating func handleLegacyRemuxSuccess(
        _ callbackAttempt: FallbackAttempt
    ) -> [PlaybackEffect] {
        guard case .legacyRemuxing(let currentAttempt) = phase,
            currentAttempt.sourceAttempt == callbackAttempt.sourceAttempt,
            currentAttempt.reservationID == callbackAttempt.reservationID,
            currentAttempt.targetSeconds.isFinite,
            currentAttempt.targetSeconds >= 0
        else {
            return []
        }

        let localAttempt = SourceAttempt(
            sessionID: currentAttempt.sourceAttempt.sessionID,
            id: .fresh(),
            source: .remuxCache
        )
        selectedSource = .remuxCache

        let requiresPhysicalSeek = latestRequestedTarget != nil
            || currentAttempt.targetSeconds > 0
        if !requiresPhysicalSeek {
            phase = .preparing(localAttempt)
            return releaseStorageReservationOnce(currentAttempt.reservationID)
                + [.startSource(localAttempt)]
        }

        let seekAttempt = SeekAttempt(
            sourceAttempt: localAttempt,
            id: .fresh(),
            targetSeconds: latestRequestedTarget ?? currentAttempt.targetSeconds
        )
        phase = .seeking(seekAttempt)
        return releaseStorageReservationOnce(currentAttempt.reservationID)
            + [.startSeek(seekAttempt)]
    }

    private mutating func handleWatchdogExpiry(
        _ expiry: PlaybackWatchdogExpiry
    ) -> [PlaybackEffect] {
        guard consumeActiveWatchdog(expiry) else { return [] }

        switch expiry.kind {
        case .resolver:
            guard let sessionID = activeSessionID else { return [] }
            if sessionBudget.consume(.resolverRetry) {
                return [.resolveDescriptor(sessionID)]
            }
            fail(category: .resolution)
            return []

        case .initialRangePrepare, .activeRangePlayback:
            guard let attempt = activeSourceAttempt else { return [] }
            if sessionBudget.consume(.rangeTransportRetry) {
                return [.retryRangeTransport(attempt)]
            }
            return beginWatchdogFallback(
                sourceAttempt: attempt,
                category: expiry.mapping.failureCategory
            )

        case .seekUpstream:
            guard case .seeking(let seekAttempt) = phase else { return [] }
            if sessionBudget.consume(.rangeTransportRetry) {
                return [.retrySeekUpstream(seekAttempt)]
            }
            return beginWatchdogFallback(
                sourceAttempt: seekAttempt.sourceAttempt,
                category: expiry.mapping.failureCategory
            )

        case .seekVerification:
            guard let attempt = activeSourceAttempt else { return [] }
            return beginWatchdogFallback(
                sourceAttempt: attempt,
                category: .seekVerification
            )

        case .legacyDownload:
            guard case .legacyDownloading(let fallback) = phase else { return [] }
            if sessionBudget.consume(expiry.mapping.counter) {
                return beginLegacyTransportRetry(fallback)
            }
            fail(category: .transport)
            return releaseRejectedReservation(fallback.reservationID)

        case .legacyRemux(let trackDurationSeconds):
            guard case .legacyRemuxing(let fallback) = phase else { return [] }
            if sessionBudget.consume(.legacyRemuxRetry) {
                return [
                    .retryLegacyRemux(
                        fallback,
                        trackDurationSeconds: trackDurationSeconds
                    )
                ]
            }
            fail(category: .remux)
            return releaseRejectedReservation(fallback.reservationID)
        }
    }

    private mutating func handleWatchdogCancellationTimeout(
        _ expiry: PlaybackWatchdogExpiry
    ) -> [PlaybackEffect] {
        guard expiry.kind.requiresCancellationAcknowledgement,
            consumeActiveWatchdog(expiry)
        else {
            return []
        }

        _ = sessionBudget.consume(expiry.mapping.counter)
        fail(category: expiry.mapping.failureCategory)
        // The timed-out operation may still own and mutate its reservation.
        // Failing closed deliberately avoids releasing or reusing that capacity.
        return []
    }

    private mutating func consumeActiveWatchdog(
        _ expiry: PlaybackWatchdogExpiry
    ) -> Bool {
        let activeWatchdog = ActivePlaybackWatchdog(
            kind: expiry.kind,
            token: expiry.token
        )
        guard accepts(kind: expiry.kind, token: expiry.token),
            let scope = watchdogScope(for: expiry.kind, token: expiry.token),
            activeWatchdogs[scope] == activeWatchdog,
            expiry.mapping == PlaybackWatchdog.terminalMapping(
                for: expiry.kind,
                networkClass: expiry.networkClass
            )
        else {
            return false
        }
        activeWatchdogs.removeValue(forKey: scope)
        return true
    }

    private mutating func beginLegacyTransportRetry(
        _ fallback: FallbackAttempt
    ) -> [PlaybackEffect] {
        guard selectedSource == .legacyDownloadRemux,
            let fingerprint = resourceGenerationFingerprint
        else {
            fail(category: .transport)
            return releaseRejectedReservation(fallback.reservationID)
        }

        // Preserve the source attempt identity across retries — the gate generates
        // a fresh PlaybackTransferGateAttemptID for uniqueness; the source attempt
        // tracks the user-visible playback action that is being retried.
        let request = FallbackRequest(
            sourceAttempt: fallback.sourceAttempt,
            targetSeconds: latestRequestedTarget ?? fallback.targetSeconds,
            intent: desiredPlaybackIntent,
            token: FailedActionToken(
                sessionID: fallback.sourceAttempt.sessionID,
                actionID: .fresh(),
                generationFingerprint: fingerprint,
                failureCategory: .transport,
                intent: .transportRetry
            )
        )
        releasedReservationIDs.insert(fallback.reservationID)
        return beginTransferGate(
            request: request,
            replacingLegacyAttempt: fallback,
            reason: .transportRetry
        )
    }

    private mutating func beginWatchdogFallback(
        sourceAttempt: SourceAttempt,
        category: PlaybackFailureCategory
    ) -> [PlaybackEffect] {
        guard selectedSource == .rangeStream,
            sourceAttempt.source == .rangeStream,
            let fingerprint = resourceGenerationFingerprint
        else {
            fail(category: category)
            return []
        }
        let token = FailedActionToken(
            sessionID: sourceAttempt.sessionID,
            actionID: .fresh(),
            generationFingerprint: fingerprint,
            failureCategory: category,
            intent: .sourceFallback
        )
        return beginLegacyGate(
            sourceAttempt: sourceAttempt,
            token: token,
            targetSeconds: latestRequestedTarget ?? lastConfirmedPosition
        )
    }

    private func accepts(
        kind: PlaybackWatchdogKind,
        token: PlaybackWatchdogToken
    ) -> Bool {
        switch kind {
        case .resolver:
            guard case .resolving(let sessionID) = phase else { return false }
            return token.sessionID == sessionID
                && token.sourceAttemptID == nil
                && token.seekRequestID == nil

        case .initialRangePrepare:
            guard case .preparing(let attempt) = phase,
                attempt.source == .rangeStream
            else {
                return false
            }
            return token.matches(attempt)
                && token.seekRequestID == nil

        case .activeRangePlayback:
            guard case .playing(let attempt) = phase,
                attempt.source == .rangeStream
            else {
                return false
            }
            return token.matches(attempt)
                && token.seekRequestID == nil

        case .seekUpstream:
            guard case .seeking(let attempt) = phase,
                attempt.sourceAttempt.source == .rangeStream
            else {
                return false
            }
            return token.matches(attempt)

        case .seekVerification:
            guard case .verifyingSeek(let attempt) = phase else { return false }
            return token.matches(attempt)

        case .legacyDownload:
            guard case .legacyDownloading(let fallback) = phase else { return false }
            return token.matches(fallback.sourceAttempt)
                && token.seekRequestID == nil

        case .legacyRemux:
            guard case .legacyRemuxing(let fallback) = phase else { return false }
            return token.matches(fallback.sourceAttempt)
                && token.seekRequestID == nil
        }
    }

    private func watchdogScope(
        for kind: PlaybackWatchdogKind,
        token: PlaybackWatchdogToken
    ) -> PlaybackWatchdogScope? {
        switch kind {
        case .resolver:
            return .resolver(token.sessionID)
        case .initialRangePrepare:
            guard let sourceAttemptID = token.sourceAttemptID else { return nil }
            return .initialRange(token.sessionID, sourceAttemptID)
        case .activeRangePlayback:
            guard let sourceAttemptID = token.sourceAttemptID else { return nil }
            return .activeRange(token.sessionID, sourceAttemptID)
        case .seekUpstream:
            guard let sourceAttemptID = token.sourceAttemptID,
                let seekRequestID = token.seekRequestID
            else {
                return nil
            }
            return .seekUpstream(token.sessionID, sourceAttemptID, seekRequestID)
        case .seekVerification:
            guard let sourceAttemptID = token.sourceAttemptID,
                let seekRequestID = token.seekRequestID
            else {
                return nil
            }
            return .seekVerification(
                token.sessionID,
                sourceAttemptID,
                seekRequestID
            )
        case .legacyDownload:
            guard let sourceAttemptID = token.sourceAttemptID else { return nil }
            return .legacyDownload(token.sessionID, sourceAttemptID)
        case .legacyRemux:
            guard let sourceAttemptID = token.sourceAttemptID else { return nil }
            return .legacyRemux(token.sessionID, sourceAttemptID)
        }
    }

    private mutating func fail(category: PlaybackFailureCategory) {
        phase = .failed(
            PlaybackFailure(
                category: category,
                isRecoverable: true,
                lastConfirmedPosition: lastConfirmedPosition
            )
        )
    }

    private func replacing(
        _ request: FallbackRequest,
        targetSeconds: TimeInterval? = nil,
        intent: DesiredPlaybackIntent? = nil
    ) -> FallbackRequest {
        FallbackRequest(
            sourceAttempt: request.sourceAttempt,
            targetSeconds: targetSeconds ?? request.targetSeconds,
            intent: intent ?? request.intent,
            token: request.token
        )
    }

    private func replacing(
        _ attempt: FallbackAttempt,
        targetSeconds: TimeInterval? = nil,
        intent: DesiredPlaybackIntent? = nil
    ) -> FallbackAttempt {
        FallbackAttempt(
            sourceAttempt: attempt.sourceAttempt,
            targetSeconds: targetSeconds ?? attempt.targetSeconds,
            intent: intent ?? attempt.intent,
            reservationID: attempt.reservationID
        )
    }

    private func pendingTransferGate(
        matching callbackAttempt: PlaybackTransferGateAttempt
    ) -> PendingPlaybackTransferGate? {
        guard let pendingGate = pendingTransferGate,
            pendingGate.attempt.id == callbackAttempt.id,
            pendingGate.attempt.networkClass == callbackAttempt.networkClass,
            pendingGate.attempt.networkClass == networkClass,
            pendingGate.attempt.networkPathVersion == callbackAttempt.networkPathVersion,
            pendingGate.attempt.networkPathVersion == networkSnapshot.pathVersion,
            pendingGate.attempt.request.token == callbackAttempt.request.token,
            pendingGate.attempt.request.sourceAttempt
                == callbackAttempt.request.sourceAttempt,
            pendingFallbackRequest == pendingGate.attempt.request
        else {
            return nil
        }
        return pendingGate
    }

    fileprivate mutating func configureInitialNetworkClass(
        _ networkClass: PlaybackNetworkClass
    ) {
        switch networkClass {
        case .wifiUnconstrained:
            configureInitialNetworkSnapshot(
                .wifi(expensive: false, constrained: false)
            )
        case .cellular:
            configureInitialNetworkSnapshot(.cellular(constrained: false))
        case .constrained:
            configureInitialNetworkSnapshot(
                NetworkSnapshot(
                    classification: .constrained,
                    isExpensive: false,
                    isConstrained: true,
                    usesWiFi: false,
                    usesCellular: false,
                    pathVersion: 0
                )
            )
        case .offline:
            configureInitialNetworkSnapshot(.offline)
        }
    }

    fileprivate mutating func configureInitialNetworkSnapshot(
        _ snapshot: NetworkSnapshot
    ) {
        networkSnapshot = snapshot
        networkClass = snapshot.classification
    }
}

@MainActor
final class PlaybackCoordinator {
    typealias EffectOperation = @MainActor (PlaybackEffect) async -> PlaybackEvent?

    private(set) var state: PlaybackSessionState
    private let effectOperation: EffectOperation
    private let monotonicClock: any PlaybackMonotonicClock
    private let watchdogScheduler: any PlaybackWatchdogScheduling
    private var effectTasks: [PlaybackEffectID: EffectTask] = [:]
    private var watchdogTasks: [PlaybackEffectID: WatchdogTask] = [:]
    private var cancellationBarriers: [PlaybackEffectID: CancellationBarrier] = [:]
    private var legacyPolicyCancellationTask: Task<Void, Never>?
    private var legacyPolicyTimeoutTask: Task<Void, Never>?
    private var pendingLegacyPolicyEffect: PlaybackEffect?
    private var legacyPolicyReservationID: StorageReservationID?
    private var legacyPolicyGateAttemptID: PlaybackTransferGateAttemptID?
    private var legacyPolicyDidTimeOut = false
    private var terminalCleanupReservations: Set<StorageReservationID> = []
    private var isShutdown = false

    private static let cancellationAcknowledgementDeadlineSeconds: TimeInterval = 5

    var activeEffectIDs: Set<PlaybackEffectID> {
        Set(effectTasks.keys)
    }

    var activeWatchdogTokens: Set<PlaybackWatchdogToken> {
        Set(watchdogTasks.values.map { $0.watchdog.token })
    }

    var activeWatchdogNetworkClasses: [PlaybackNetworkClass] {
        watchdogTasks.values.map { $0.watchdog.networkClass }
    }

    init(
        initialState: PlaybackSessionState = .idle,
        effectOperation: @escaping EffectOperation = { _ in nil },
        monotonicClock: (any PlaybackMonotonicClock)? = nil,
        watchdogScheduler: (any PlaybackWatchdogScheduling)? = nil,
        networkClass: PlaybackNetworkClass = .wifiUnconstrained,
        networkSnapshot: NetworkSnapshot? = nil
    ) {
        var configuredState = initialState
        if let networkSnapshot {
            configuredState.configureInitialNetworkSnapshot(networkSnapshot)
        } else {
            configuredState.configureInitialNetworkClass(networkClass)
        }
        state = configuredState
        self.effectOperation = effectOperation
        self.monotonicClock = monotonicClock ?? SystemPlaybackMonotonicClock()
        self.watchdogScheduler = watchdogScheduler
            ?? SystemPlaybackWatchdogScheduler()
    }

    func send(_ event: PlaybackEvent) {
        guard !isShutdown else { return }
        reduceAndStart(event)
    }

    private func reduceAndStart(_ event: PlaybackEvent) {
        let effects = state.reduce(event)
        for effect in effects {
            start(effect)
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        reduceAndStart(.stop)
    }

    deinit {
        let operation = effectOperation
        if let policyWaiter = legacyPolicyCancellationTask,
            let reservationID = legacyPolicyReservationID
        {
            Task { @MainActor in
                await policyWaiter.value
                _ = await operation(.releaseStorageReservation(reservationID))
            }
        } else if let attempt = state.activeLegacyAttemptForCleanup {
            let downloadID = PlaybackEffectID.legacyTransfer(attempt.sourceAttempt.id)
            let remuxID = PlaybackEffectID.legacyRemux(attempt.sourceAttempt.id)
            let ownedTask: Task<Void, Never>?
            if let downloadTask = effectTasks[downloadID]?.task {
                ownedTask = downloadTask
            } else {
                ownedTask = effectTasks[remuxID]?.task
            }
            ownedTask?.cancel()
            Task { @MainActor in
                if let ownedTask { await ownedTask.value }
                _ = await operation(.releaseStorageReservation(attempt.reservationID))
            }
        }
        for entry in watchdogTasks.values {
            entry.task.cancel()
        }
        for entry in effectTasks.values {
            entry.task.cancel()
        }
        for entry in cancellationBarriers.values {
            entry.acknowledgementTask.cancel()
            entry.timeoutTask.cancel()
        }
        legacyPolicyTimeoutTask?.cancel()
    }

    func receiveWatchdogSignal(
        _ signal: PlaybackWatchdogSignal,
        token: PlaybackWatchdogToken
    ) {
        guard let (effectID, entry) = watchdogTasks.first(where: {
            $0.value.watchdog.token == token
        }) else {
            return
        }
        guard let outcome = entry.watchdog.receive(signal, token: token) else {
            return
        }
        switch outcome {
        case .expired(let expiry):
            handleWatchdogExpiry(
                expiry,
                effectID: effectID,
                runID: entry.runID
            )
        case .completed:
            cancelWatchdog(effectID, runID: entry.runID)
        }
    }

    private func start(_ effect: PlaybackEffect) {
        if case .releaseReservationAndEvaluateFullResourceTransferGate(
            _,
            let attempt
        ) = effect {
            guard let oldSourceAttemptID = attempt.replacedLegacySourceAttemptID else {
                send(
                    .fullTransferGateDenied(
                        attempt,
                        denial: PlaybackTransferGateDenial(category: .transport)
                    )
                )
                return
            }
            if legacyPolicyCancellationTask != nil {
                pendingLegacyPolicyEffect = effect
                legacyPolicyGateAttemptID = attempt.id
                return
            }
            let legacyEffectID = PlaybackEffectID.legacyTransfer(
                oldSourceAttemptID
            )
            if let entry = effectTasks.removeValue(forKey: legacyEffectID) {
                cancelWatchdog(legacyEffectID, runID: entry.runID)
                entry.task.cancel()
                pendingLegacyPolicyEffect = effect
                legacyPolicyReservationID = Self.oldReservationID(from: effect)
                legacyPolicyGateAttemptID = attempt.id
                legacyPolicyDidTimeOut = false
                let timeoutInstant = monotonicClock.now
                    + Self.cancellationAcknowledgementDeadlineSeconds
                let scheduler = watchdogScheduler
                let clock = monotonicClock
                legacyPolicyCancellationTask = Task { [weak self] in
                    await entry.task.value
                    guard let self else { return }
                    self.finishLegacyPolicyCancellationBarrier()
                }
                legacyPolicyTimeoutTask = Task { [weak self] in
                    do {
                        try await scheduler.sleep(until: timeoutInstant, clock: clock)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let self else { return }
                    self.timeoutLegacyPolicyCancellationBarrier()
                }
                return
            }
        }

        switch effect {
        case .cancelAllEffects:
            cancelAllEffects()
            return
        case .cancelAllEffectsAndReleaseLegacy(let attempt):
            cancelAllEffectsAndReleaseLegacy(attempt)
            return
        case .cancelSeekEffects(let seekID):
            cancelEffect(.seekUpstream(seekID))
            cancelEffect(.seekVerification(seekID))
            return
        case .cancelActiveRangeMonitor(let sourceAttemptID):
            cancelEffect(.source(sourceAttemptID))
            return
        case .cancelTransferGate(let actionID):
            cancelEffect(.transferGate(actionID))
            return
        default:
            break
        }

        guard let effectID = effect.taskID else { return }
        cancelEffect(effectID)
        let runID = UUID()
        let operation = effectOperation
        let task = Task { [weak self] in
            let callback = await operation(effect)
            guard let self else {
                guard let reservationID = Self.gateReservationID(from: callback) else {
                    return
                }
                // This cleanup outlives the cancelled playback task and therefore
                // must start in a fresh, non-cancelled unstructured task.
                Task { @MainActor in
                    _ = await operation(.releaseStorageReservation(reservationID))
                }
                return
            }
            self.finishEffect(
                effectID,
                runID: runID,
                callback: callback,
                wasCancelled: Task.isCancelled
            )
        }
        effectTasks[effectID] = EffectTask(runID: runID, task: task)
        if let registration = watchdogRegistration(for: effect) {
            startWatchdog(
                registration,
                effectID: effectID,
                runID: runID
            )
        }
    }

    private func finishEffect(
        _ effectID: PlaybackEffectID,
        runID: UUID,
        callback: PlaybackEvent?,
        wasCancelled: Bool
    ) {
        guard effectTasks[effectID]?.runID == runID else {
            cleanUpOrphanedGateReservation(from: callback)
            return
        }

        if let watchdogEntry = watchdogTasks[effectID],
            watchdogEntry.runID == runID,
            let outcome = watchdogEntry.watchdog.receive(
                .completed,
                token: watchdogEntry.watchdog.token
            )
        {
            switch outcome {
            case .expired(let expiry):
                handleWatchdogExpiry(expiry, effectID: effectID, runID: runID)
                return
            case .completed:
                cancelWatchdog(effectID, runID: runID)
            }
        }

        effectTasks.removeValue(forKey: effectID)
        guard !wasCancelled else {
            cleanUpOrphanedGateReservation(from: callback)
            return
        }
        guard let callback else { return }
        send(callback)
    }

    private func cleanUpOrphanedGateReservation(
        from callback: PlaybackEvent?
    ) {
        guard let reservationID = Self.gateReservationID(from: callback) else {
            return
        }
        // Cleanup must still be reduced after terminal shutdown; ordinary send(_:) is
        // intentionally disabled there, while a gate-minted reservation still exists.
        reduceAndStart(.releaseOrphanedTransferReservation(reservationID))
    }

    private static func gateReservationID(
        from callback: PlaybackEvent?
    ) -> StorageReservationID? {
        guard let callback else { return nil }
        switch callback {
        case .fullTransferGateAllowed(_, let callbackReservationID),
            .transferConsentAccepted(_, let callbackReservationID):
            return callbackReservationID
        default:
            return nil
        }
    }

    private func cancelEffect(_ effectID: PlaybackEffectID) {
        cancelCancellationBarrier(effectID)
        cancelWatchdog(effectID)
        let entry = effectTasks.removeValue(forKey: effectID)
        entry?.task.cancel()
    }

    private func cancelAllEffects() {
        let watchdogs = Array(watchdogTasks.values)
        watchdogTasks.removeAll()
        let tasks = effectTasks.values.map(\.task)
        effectTasks.removeAll()
        let barriers = Array(cancellationBarriers.values)
        cancellationBarriers.removeAll()
        for entry in watchdogs {
            _ = state.reduce(
                .watchdogStopped(
                    kind: entry.watchdog.kind,
                    token: entry.watchdog.token
                )
            )
            entry.task.cancel()
        }
        for task in tasks {
            task.cancel()
        }
        for barrier in barriers {
            barrier.acknowledgementTask.cancel()
            barrier.timeoutTask.cancel()
        }
        if legacyPolicyCancellationTask != nil {
            // The old transfer may ignore cancellation. Keep only the acknowledgement
            // waiter alive so its reservation can be released after ownership ends.
            legacyPolicyDidTimeOut = true
            pendingLegacyPolicyEffect = nil
            legacyPolicyTimeoutTask?.cancel()
            legacyPolicyTimeoutTask = nil
        }
    }

    private func cancelAllEffectsAndReleaseLegacy(_ attempt: FallbackAttempt) {
        let downloadID = PlaybackEffectID.legacyTransfer(attempt.sourceAttempt.id)
        let remuxID = PlaybackEffectID.legacyRemux(attempt.sourceAttempt.id)
        let ownedTask = effectTasks[downloadID]?.task ?? effectTasks[remuxID]?.task
        cancelAllEffects()
        guard terminalCleanupReservations.insert(attempt.reservationID).inserted else {
            return
        }
        let operation = effectOperation
        Task { @MainActor in
            if let ownedTask {
                await ownedTask.value
            }
            _ = await operation(.releaseStorageReservation(attempt.reservationID))
        }
    }

    private func finishLegacyPolicyCancellationBarrier() {
        legacyPolicyCancellationTask = nil
        legacyPolicyTimeoutTask?.cancel()
        legacyPolicyTimeoutTask = nil
        if legacyPolicyDidTimeOut {
            let reservationID = legacyPolicyReservationID
            legacyPolicyReservationID = nil
            legacyPolicyGateAttemptID = nil
            pendingLegacyPolicyEffect = nil
            if let reservationID {
                start(.releaseStorageReservation(reservationID))
            }
            return
        }
        guard !isShutdown, let effect = pendingLegacyPolicyEffect else {
            pendingLegacyPolicyEffect = nil
            return
        }
        pendingLegacyPolicyEffect = nil
        guard case .releaseReservationAndEvaluateFullResourceTransferGate(
            _,
            let attempt
        ) = effect,
            state.pendingTransferGateAttempt?.id == attempt.id
        else {
            return
        }
        start(effect)
    }

    private func timeoutLegacyPolicyCancellationBarrier() {
        guard let attemptID = legacyPolicyGateAttemptID else { return }
        guard legacyPolicyCancellationTask != nil,
            !legacyPolicyDidTimeOut
        else {
            return
        }
        legacyPolicyDidTimeOut = true
        pendingLegacyPolicyEffect = nil
        legacyPolicyTimeoutTask?.cancel()
        legacyPolicyTimeoutTask = nil
        send(.legacyPolicyCancellationTimedOut(attemptID))
    }

    private static func oldReservationID(
        from effect: PlaybackEffect
    ) -> StorageReservationID? {
        guard case .releaseReservationAndEvaluateFullResourceTransferGate(
            let reservationID,
            _
        ) = effect else {
            return nil
        }
        return reservationID
    }

    private func watchdogRegistration(
        for effect: PlaybackEffect
    ) -> (kind: PlaybackWatchdogKind, token: PlaybackWatchdogToken)? {
        switch effect {
        case .resolveDescriptor(let sessionID):
            return (.resolver, .fresh(sessionID: sessionID))
        case .startSource(let attempt):
            guard attempt.source == .rangeStream else { return nil }
            return (.initialRangePrepare, .fresh(sourceAttempt: attempt))
        case .startSeek(let attempt):
            guard attempt.sourceAttempt.source == .rangeStream else { return nil }
            return (.seekUpstream, .fresh(seekAttempt: attempt))
        case .retrySeekUpstream(let attempt):
            guard attempt.sourceAttempt.source == .rangeStream else { return nil }
            return (.seekUpstream, .fresh(seekAttempt: attempt))
        case .startSeekVerification(let attempt):
            return (.seekVerification, .fresh(seekAttempt: attempt))
        case .monitorActiveRange(let attempt):
            guard attempt.source == .rangeStream else { return nil }
            return (.activeRangePlayback, .fresh(sourceAttempt: attempt))
        case .resumeSource(let attempt):
            guard attempt.source == .rangeStream else { return nil }
            return (.activeRangePlayback, .fresh(sourceAttempt: attempt))
        case .retryRangeTransport(let attempt):
            if case .preparing = state.phase {
                return (.initialRangePrepare, .fresh(sourceAttempt: attempt))
            }
            return (.activeRangePlayback, .fresh(sourceAttempt: attempt))
        case .startLegacyTransfer(let attempt):
            return (.legacyDownload, .fresh(sourceAttempt: attempt.sourceAttempt))
        case .startLegacyRemux(let attempt, let trackDurationSeconds),
            .retryLegacyRemux(let attempt, let trackDurationSeconds):
            return (
                .legacyRemux(trackDurationSeconds: trackDurationSeconds),
                .fresh(sourceAttempt: attempt.sourceAttempt)
            )
        case .cancelAllEffects, .cancelAllEffectsAndReleaseLegacy,
            .cancelSeekEffects, .cancelActiveRangeMonitor,
            .cancelTransferGate, .evaluateFullResourceTransferGate,
            .releaseReservationAndEvaluateFullResourceTransferGate,
            .presentFullTransferConsent, .releaseStorageReservation:
            return nil
        }
    }

    private func startWatchdog(
        _ registration: (kind: PlaybackWatchdogKind, token: PlaybackWatchdogToken),
        effectID: PlaybackEffectID,
        runID: UUID
    ) {
        cancelWatchdog(effectID)
        let networkSnapshot = state.networkClass
        let watchdog = PlaybackWatchdog(
            kind: registration.kind,
            networkClass: networkSnapshot,
            token: registration.token,
            clock: monotonicClock
        )
        let scheduler = watchdogScheduler
        let clock = monotonicClock
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = watchdog.nextDeadlineInstant else { return }
                do {
                    try await scheduler.sleep(until: deadline, clock: clock)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let outcome = watchdog.receive(.poll, token: watchdog.token) else {
                    continue
                }
                guard case .expired(let expiry) = outcome else { return }
                self?.handleWatchdogExpiry(
                    expiry,
                    effectID: effectID,
                    runID: runID
                )
                return
            }
        }
        watchdogTasks[effectID] = WatchdogTask(
            runID: runID,
            watchdog: watchdog,
            task: task
        )
        _ = state.reduce(
            .watchdogStarted(kind: watchdog.kind, token: registration.token)
        )
    }

    private func handleWatchdogExpiry(
        _ expiry: PlaybackWatchdogExpiry,
        effectID: PlaybackEffectID,
        runID: UUID
    ) {
        guard watchdogTasks[effectID]?.runID == runID,
            watchdogTasks[effectID]?.watchdog.token == expiry.token
        else {
            return
        }

        let watchdogTask = watchdogTasks.removeValue(forKey: effectID)?.task
        watchdogTask?.cancel()
        guard let effectTask = effectTasks.removeValue(forKey: effectID)?.task else {
            send(.watchdogExpired(expiry))
            return
        }
        effectTask.cancel()

        guard expiry.kind.requiresCancellationAcknowledgement else {
            send(.watchdogExpired(expiry))
            return
        }
        guard let reservationID = cancellationBarrierReservationID(for: expiry) else {
            send(.watchdogExpired(expiry))
            return
        }

        startCancellationBarrier(
            for: effectTask,
            effectID: effectID,
            expiry: expiry,
            reservationID: reservationID
        )
    }

    private func cancellationBarrierReservationID(
        for expiry: PlaybackWatchdogExpiry
    ) -> StorageReservationID? {
        switch (expiry.kind, state.phase) {
        case (.legacyDownload, .legacyDownloading(let attempt)):
            guard expiry.token.matches(attempt.sourceAttempt) else { return nil }
            return attempt.reservationID
        case (.legacyRemux, .legacyRemuxing(let attempt)):
            guard expiry.token.matches(attempt.sourceAttempt) else { return nil }
            return attempt.reservationID
        default:
            return nil
        }
    }

    private func startCancellationBarrier(
        for effectTask: Task<Void, Never>,
        effectID: PlaybackEffectID,
        expiry: PlaybackWatchdogExpiry,
        reservationID: StorageReservationID
    ) {
        cancelCancellationBarrier(effectID)
        let runID = UUID()
        let scheduler = watchdogScheduler
        let clock = monotonicClock
        let operation = effectOperation
        let timeoutInstant = clock.now
            + Self.cancellationAcknowledgementDeadlineSeconds

        let acknowledgementTask = Task { [weak self] in
            await effectTask.value
            guard let self else {
                Task { @MainActor in
                    _ = await operation(.releaseStorageReservation(reservationID))
                }
                return
            }
            self.finishCancellationBarrier(
                effectID,
                runID: runID,
                expiry: expiry,
                reservationID: reservationID,
                outcome: .acknowledged
            )
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await scheduler.sleep(until: timeoutInstant, clock: clock)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.finishCancellationBarrier(
                effectID,
                runID: runID,
                expiry: expiry,
                reservationID: reservationID,
                outcome: .timedOut
            )
        }
        cancellationBarriers[effectID] = CancellationBarrier(
            runID: runID,
            acknowledgementTask: acknowledgementTask,
            timeoutTask: timeoutTask,
            reservationID: reservationID,
            didTimeOut: false
        )
    }

    private func finishCancellationBarrier(
        _ effectID: PlaybackEffectID,
        runID: UUID,
        expiry: PlaybackWatchdogExpiry,
        reservationID: StorageReservationID,
        outcome: CancellationBarrierOutcome
    ) {
        guard var barrier = cancellationBarriers[effectID],
            barrier.runID == runID,
            barrier.reservationID == reservationID
        else {
            if outcome == .acknowledged {
                reduceAndStart(
                    .releaseOrphanedTransferReservation(reservationID)
                )
            }
            return
        }

        switch outcome {
        case .acknowledged:
            cancellationBarriers.removeValue(forKey: effectID)
            barrier.acknowledgementTask.cancel()
            barrier.timeoutTask.cancel()
            if barrier.didTimeOut {
                reduceAndStart(
                    .releaseOrphanedTransferReservation(reservationID)
                )
            } else {
                send(.watchdogExpired(expiry))
            }
        case .timedOut:
            guard !barrier.didTimeOut else { return }
            barrier.didTimeOut = true
            cancellationBarriers[effectID] = barrier
            barrier.timeoutTask.cancel()
            send(.watchdogCancellationTimedOut(expiry))
        }
    }

    private func cancelCancellationBarrier(_ effectID: PlaybackEffectID) {
        guard let barrier = cancellationBarriers.removeValue(forKey: effectID) else {
            return
        }
        barrier.acknowledgementTask.cancel()
        barrier.timeoutTask.cancel()
    }

    private func cancelWatchdog(_ effectID: PlaybackEffectID, runID: UUID? = nil) {
        guard let entry = watchdogTasks[effectID],
            runID.map({ $0 == entry.runID }) ?? true
        else {
            return
        }
        watchdogTasks.removeValue(forKey: effectID)
        _ = state.reduce(
            .watchdogStopped(
                kind: entry.watchdog.kind,
                token: entry.watchdog.token
            )
        )
        entry.task.cancel()
    }

    private struct EffectTask {
        let runID: UUID
        let task: Task<Void, Never>
    }

    private struct WatchdogTask {
        let runID: UUID
        let watchdog: PlaybackWatchdog
        let task: Task<Void, Never>
    }

    private struct CancellationBarrier {
        let runID: UUID
        let acknowledgementTask: Task<Void, Never>
        let timeoutTask: Task<Void, Never>
        let reservationID: StorageReservationID
        var didTimeOut: Bool
    }

    private enum CancellationBarrierOutcome: Equatable {
        case acknowledged
        case timedOut
    }
}

@MainActor
protocol PlaybackMonotonicClock: AnyObject {
    var now: TimeInterval { get }
}

@MainActor
protocol PlaybackWatchdogScheduling: AnyObject {
    func sleep(
        until deadline: TimeInterval,
        clock: any PlaybackMonotonicClock
    ) async throws
}

@MainActor
final class SystemPlaybackWatchdogScheduler: PlaybackWatchdogScheduling {
    func sleep(
        until deadline: TimeInterval,
        clock: any PlaybackMonotonicClock
    ) async throws {
        let remaining = max(0, deadline - clock.now)
        if remaining > 0 {
            try await Task.sleep(for: .seconds(remaining))
        }
        try Task.checkCancellation()
    }
}

@MainActor
final class SystemPlaybackMonotonicClock: PlaybackMonotonicClock {
    var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

struct PlaybackWatchdogID: Hashable, Sendable {
    let rawValue: UUID

    static func fresh() -> Self {
        Self(rawValue: UUID())
    }
}

struct PlaybackWatchdogToken: Hashable, Sendable {
    let id: PlaybackWatchdogID
    let sessionID: PlaybackSessionID
    let sourceAttemptID: SourceAttemptID?
    let seekRequestID: SeekRequestID?

    static func fresh(sessionID: PlaybackSessionID) -> Self {
        Self(
            id: .fresh(),
            sessionID: sessionID,
            sourceAttemptID: nil,
            seekRequestID: nil
        )
    }

    static func fresh(sourceAttempt: SourceAttempt) -> Self {
        Self(
            id: .fresh(),
            sessionID: sourceAttempt.sessionID,
            sourceAttemptID: sourceAttempt.id,
            seekRequestID: nil
        )
    }

    static func fresh(seekAttempt: SeekAttempt) -> Self {
        Self(
            id: .fresh(),
            sessionID: seekAttempt.sourceAttempt.sessionID,
            sourceAttemptID: seekAttempt.sourceAttempt.id,
            seekRequestID: seekAttempt.id
        )
    }

    func matches(_ attempt: SourceAttempt) -> Bool {
        sessionID == attempt.sessionID && sourceAttemptID == attempt.id
    }

    func matches(_ attempt: SeekAttempt) -> Bool {
        matches(attempt.sourceAttempt) && seekRequestID == attempt.id
    }
}

enum PlaybackWatchdogKind: Equatable, Sendable {
    case resolver
    case initialRangePrepare
    case activeRangePlayback
    case seekUpstream
    case seekVerification
    case legacyDownload
    case legacyRemux(trackDurationSeconds: TimeInterval)
}

struct PlaybackWatchdogDeadlines: Equatable, Sendable {
    let noProgress: TimeInterval?
    let absolute: TimeInterval?
}

enum PlaybackWatchdogCounterConsumptionTiming: Equatable, Sendable {
    case onExpiry
    case whenLegacyCommits
}

struct PlaybackWatchdogTerminalMapping: Equatable, Sendable {
    let counter: FailureCounter
    let failureCategory: PlaybackFailureCategory
    let consumptionTiming: PlaybackWatchdogCounterConsumptionTiming
}

enum PlaybackWatchdogExpiryReason: Equatable, Sendable {
    case noProgressDeadline
    case absoluteDeadline
    case upstreamError
}

struct PlaybackWatchdogExpiry: Equatable, Sendable {
    let token: PlaybackWatchdogToken
    let kind: PlaybackWatchdogKind
    let networkClass: PlaybackNetworkClass
    let mapping: PlaybackWatchdogTerminalMapping
    let reason: PlaybackWatchdogExpiryReason
}

enum PlaybackWatchdogSignal: Equatable, Sendable {
    case validatedResponseBodyBytes(totalUniqueBytes: Int64)
    case unvalidatedResponseBodyBytes(totalBytes: Int64)
    case remuxOutputBytes(totalBytes: Int64)
    case responseHeaders
    case poll
    case upstreamError
    case completed
}

enum PlaybackWatchdogOutcome: Equatable, Sendable {
    case expired(PlaybackWatchdogExpiry)
    case completed(PlaybackWatchdogToken)
}

@MainActor
final class PlaybackWatchdog {
    let kind: PlaybackWatchdogKind
    let networkClass: PlaybackNetworkClass
    let token: PlaybackWatchdogToken
    let deadlines: PlaybackWatchdogDeadlines
    private(set) var lastProgressInstant: TimeInterval
    private(set) var isHandled = false

    private let clock: any PlaybackMonotonicClock
    private let startInstant: TimeInterval
    private var validatedResponseBodyHighWater: Int64 = 0
    private var remuxOutputHighWater: Int64 = 0

    init(
        kind: PlaybackWatchdogKind,
        networkClass: PlaybackNetworkClass,
        token: PlaybackWatchdogToken,
        clock: any PlaybackMonotonicClock
    ) {
        let normalizedKind = kind.normalized
        self.kind = normalizedKind
        self.networkClass = networkClass
        self.token = token
        self.clock = clock
        deadlines = Self.deadlines(
            for: normalizedKind,
            networkClass: networkClass
        )
        let initialInstant = Self.validInstant(clock.now, fallback: 0)
        startInstant = initialInstant
        lastProgressInstant = initialInstant
    }

    func receive(
        _ signal: PlaybackWatchdogSignal,
        token callbackToken: PlaybackWatchdogToken
    ) -> PlaybackWatchdogOutcome? {
        guard !isHandled, callbackToken == token else { return nil }

        if let overdueOutcome = overdueOutcome() {
            return overdueOutcome
        }

        switch signal {
        case .validatedResponseBodyBytes(let totalUniqueBytes):
            recordValidatedResponseBodyProgress(totalUniqueBytes)
            return nil
        case .unvalidatedResponseBodyBytes, .responseHeaders:
            return nil
        case .remuxOutputBytes(let totalBytes):
            recordRemuxOutputProgress(totalBytes)
            return nil
        case .poll:
            return nil
        case .upstreamError:
            return expire(reason: .upstreamError)
        case .completed:
            isHandled = true
            return .completed(token)
        }
    }

    nonisolated static func deadlines(
        for kind: PlaybackWatchdogKind,
        networkClass: PlaybackNetworkClass
    ) -> PlaybackWatchdogDeadlines {
        switch kind.normalized {
        case .resolver:
            return PlaybackWatchdogDeadlines(
                noProgress: PlaybackPolicyParameters.resolverNoProgressDeadlineSeconds(
                    for: networkClass
                ),
                absolute: PlaybackPolicyParameters.resolverAbsoluteDeadlineSeconds(
                    for: networkClass
                )
            )
        case .initialRangePrepare, .seekUpstream:
            return PlaybackWatchdogDeadlines(
                noProgress: PlaybackPolicyParameters
                    .rangePrepareSeekNoProgressDeadlineSeconds(for: networkClass),
                absolute: PlaybackPolicyParameters
                    .rangePrepareSeekAbsoluteDeadlineSeconds(for: networkClass)
            )
        case .activeRangePlayback:
            return PlaybackWatchdogDeadlines(
                noProgress: PlaybackPolicyParameters
                    .activeRangeNoProgressDeadlineSeconds(for: networkClass),
                absolute: PlaybackPolicyParameters.activeRangeAbsoluteDeadlineSeconds(
                    for: networkClass
                )
            )
        case .seekVerification:
            return PlaybackWatchdogDeadlines(
                noProgress: nil,
                absolute: PlaybackPolicyParameters
                    .seekVerificationAbsoluteDeadlineSeconds(for: networkClass)
            )
        case .legacyDownload:
            return PlaybackWatchdogDeadlines(
                noProgress: PlaybackPolicyParameters
                    .legacyFullDownloadNoProgressDeadlineSeconds(for: networkClass),
                absolute: PlaybackPolicyParameters
                    .legacyFullDownloadAbsoluteDeadlineSeconds(for: networkClass)
            )
        case .legacyRemux(let trackDurationSeconds):
            return PlaybackWatchdogDeadlines(
                noProgress: PlaybackPolicyParameters.legacyRemuxNoProgressDeadlineSeconds,
                absolute: PlaybackPolicyParameters.legacyRemuxAbsoluteDeadlineSeconds(
                    trackDurationSeconds: trackDurationSeconds
                )
            )
        }
    }

    nonisolated static func terminalMapping(
        for kind: PlaybackWatchdogKind,
        networkClass: PlaybackNetworkClass
    ) -> PlaybackWatchdogTerminalMapping {
        switch kind {
        case .resolver:
            return PlaybackWatchdogTerminalMapping(
                counter: .resolverRetry,
                failureCategory: .resolution,
                consumptionTiming: .onExpiry
            )
        case .initialRangePrepare, .activeRangePlayback, .seekUpstream:
            return PlaybackWatchdogTerminalMapping(
                counter: .rangeTransportRetry,
                failureCategory: .transport,
                consumptionTiming: .onExpiry
            )
        case .seekVerification:
            return PlaybackWatchdogTerminalMapping(
                counter: .rangeToLegacyDowngrade,
                failureCategory: .seekVerification,
                consumptionTiming: .whenLegacyCommits
            )
        case .legacyDownload:
            let counter: FailureCounter
            switch networkClass {
            case .wifiUnconstrained:
                counter = .legacyWiFiTransportRetry
            case .cellular, .constrained, .offline:
                counter = .legacyMeteredTransportRetry
            }
            return PlaybackWatchdogTerminalMapping(
                counter: counter,
                failureCategory: .transport,
                consumptionTiming: .onExpiry
            )
        case .legacyRemux:
            return PlaybackWatchdogTerminalMapping(
                counter: .legacyRemuxRetry,
                failureCategory: .remux,
                consumptionTiming: .onExpiry
            )
        }
    }

    private func recordValidatedResponseBodyProgress(_ totalUniqueBytes: Int64) {
        guard kind.acceptsResponseBodyProgress,
            totalUniqueBytes > validatedResponseBodyHighWater
        else {
            return
        }
        validatedResponseBodyHighWater = totalUniqueBytes
        lastProgressInstant = currentInstant
    }

    private func recordRemuxOutputProgress(_ totalBytes: Int64) {
        guard case .legacyRemux = kind, totalBytes > remuxOutputHighWater else {
            return
        }
        remuxOutputHighWater = totalBytes
        lastProgressInstant = currentInstant
    }

    private func poll() -> PlaybackWatchdogOutcome? {
        overdueOutcome()
    }

    var nextDeadlineInstant: TimeInterval? {
        var candidates: [TimeInterval] = []
        if let absolute = deadlines.absolute {
            candidates.append(startInstant + absolute)
        }
        if let noProgress = deadlines.noProgress {
            candidates.append(lastProgressInstant + noProgress)
        }
        return candidates.min()
    }

    private func overdueOutcome() -> PlaybackWatchdogOutcome? {
        let now = currentInstant
        if let absolute = deadlines.absolute,
            now - startInstant >= absolute
        {
            return expire(reason: .absoluteDeadline)
        }
        if let noProgress = deadlines.noProgress,
            now - lastProgressInstant >= noProgress
        {
            return expire(reason: .noProgressDeadline)
        }
        return nil
    }

    private func expire(
        reason: PlaybackWatchdogExpiryReason
    ) -> PlaybackWatchdogOutcome {
        isHandled = true
        return .expired(
            PlaybackWatchdogExpiry(
                token: token,
                kind: kind,
                networkClass: networkClass,
                mapping: Self.terminalMapping(for: kind, networkClass: networkClass),
                reason: reason
            )
        )
    }

    private var currentInstant: TimeInterval {
        Self.validInstant(clock.now, fallback: lastProgressInstant)
    }

    private static func validInstant(
        _ instant: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard instant.isFinite, instant >= fallback else { return fallback }
        return instant
    }
}

private extension PlaybackWatchdogKind {
    var normalized: Self {
        guard case .legacyRemux(let trackDurationSeconds) = self,
            !trackDurationSeconds.isFinite || trackDurationSeconds < 0
        else {
            return self
        }
        return .legacyRemux(trackDurationSeconds: 0)
    }

    var requiresCancellationAcknowledgement: Bool {
        switch self {
        case .legacyDownload, .legacyRemux:
            return true
        case .resolver, .initialRangePrepare, .activeRangePlayback,
            .seekUpstream, .seekVerification:
            return false
        }
    }

    var acceptsResponseBodyProgress: Bool {
        switch self {
        case .initialRangePrepare, .activeRangePlayback, .seekUpstream,
            .legacyDownload:
            return true
        case .resolver, .seekVerification, .legacyRemux:
            return false
        }
    }
}
