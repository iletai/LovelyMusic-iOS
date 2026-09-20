import Foundation
import Network

struct NetworkSnapshot: Equatable, Sendable {
    let classification: PlaybackNetworkClass
    let isExpensive: Bool
    let isConstrained: Bool
    let usesWiFi: Bool
    let usesCellular: Bool
    let pathVersion: UInt64

    init(
        classification: PlaybackNetworkClass,
        isExpensive: Bool,
        isConstrained: Bool,
        usesWiFi: Bool,
        usesCellular: Bool,
        pathVersion: UInt64
    ) {
        self.classification = classification
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
        self.pathVersion = pathVersion
    }

    static func wifi(
        expensive: Bool,
        constrained: Bool,
        pathVersion: UInt64 = 0
    ) -> Self {
        Self(
            classification: constrained ? .constrained : .wifiUnconstrained,
            isExpensive: expensive,
            isConstrained: constrained,
            usesWiFi: true,
            usesCellular: false,
            pathVersion: pathVersion
        )
    }

    static func cellular(
        constrained: Bool,
        pathVersion: UInt64 = 0
    ) -> Self {
        Self(
            classification: constrained ? .constrained : .cellular,
            isExpensive: true,
            isConstrained: constrained,
            usesWiFi: false,
            usesCellular: true,
            pathVersion: pathVersion
        )
    }

    static let offline = Self(
        classification: .offline,
        isExpensive: false,
        isConstrained: false,
        usesWiFi: false,
        usesCellular: false,
        pathVersion: 0
    )

    fileprivate init(
        observation: PlaybackNetworkPathObservation,
        pathVersion: UInt64
    ) {
        let classification: PlaybackNetworkClass
        if !observation.isSatisfied {
            classification = .offline
        } else if observation.isConstrained {
            classification = .constrained
        } else if observation.usesCellular {
            classification = .cellular
        } else if observation.usesWiFi {
            classification = .wifiUnconstrained
        } else {
            classification = .constrained
        }

        self.init(
            classification: classification,
            isExpensive: observation.isExpensive,
            isConstrained: observation.isConstrained,
            usesWiFi: observation.usesWiFi,
            usesCellular: observation.usesCellular,
            pathVersion: pathVersion
        )
    }

    fileprivate func hasSamePolicyProperties(as other: Self) -> Bool {
        classification == other.classification
            && isExpensive == other.isExpensive
            && isConstrained == other.isConstrained
            && usesWiFi == other.usesWiFi
            && usesCellular == other.usesCellular
    }

    fileprivate var requiresTransferConsent: Bool {
        classification == .cellular
            || classification == .constrained
            || isExpensive
            || isConstrained
            || usesCellular
            || !usesWiFi
    }
}

struct PlaybackNetworkPathObservation: Equatable, Sendable {
    let isSatisfied: Bool
    let isExpensive: Bool
    let isConstrained: Bool
    let usesWiFi: Bool
    let usesCellular: Bool

    static func wifi(expensive: Bool, constrained: Bool) -> Self {
        Self(
            isSatisfied: true,
            isExpensive: expensive,
            isConstrained: constrained,
            usesWiFi: true,
            usesCellular: false
        )
    }

    static func cellular(constrained: Bool) -> Self {
        Self(
            isSatisfied: true,
            isExpensive: true,
            isConstrained: constrained,
            usesWiFi: false,
            usesCellular: true
        )
    }

    static let offline = Self(
        isSatisfied: false,
        isExpensive: false,
        isConstrained: false,
        usesWiFi: false,
        usesCellular: false
    )

    init(path: NWPath) {
        isSatisfied = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        usesWiFi = path.usesInterfaceType(.wifi)
        usesCellular = path.usesInterfaceType(.cellular)
    }

    private init(
        isSatisfied: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        usesWiFi: Bool,
        usesCellular: Bool
    ) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
    }
}

protocol PlaybackNetworkPathMonitorInstance: Sendable {
    func setPathUpdateHandler(
        _ updateHandler: (@Sendable (PlaybackNetworkPathObservation) -> Void)?
    )
    func start(queue: DispatchQueue)
    func cancel()
}

private final class SystemPlaybackNetworkPathMonitorInstance:
    PlaybackNetworkPathMonitorInstance,
    @unchecked Sendable
{
    private let monitor: NWPathMonitor

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    func setPathUpdateHandler(
        _ updateHandler: (@Sendable (PlaybackNetworkPathObservation) -> Void)?
    ) {
        guard let updateHandler else {
            monitor.pathUpdateHandler = nil
            return
        }
        monitor.pathUpdateHandler = { path in
            updateHandler(PlaybackNetworkPathObservation(path: path))
        }
    }

    func start(queue: DispatchQueue) {
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

private struct NativeNetworkObservation: Sendable {
    let monitorGeneration: UUID
    let observation: PlaybackNetworkPathObservation
}

actor PlaybackNetworkMonitor {
    typealias UpdateHandler = @Sendable (NetworkSnapshot) async -> Void
    typealias MonitorFactory =
        @Sendable () -> any PlaybackNetworkPathMonitorInstance

    private let monitorFactory: MonitorFactory
    private let callbackQueue: DispatchQueue
    private var updateHandler: UpdateHandler?
    private var isStarted = false
    private var activeMonitor: (any PlaybackNetworkPathMonitorInstance)?
    private var activeMonitorGeneration: UUID?
    private var nativeObservationTask: Task<Void, Never>?
    private var nativeObservationContinuation:
        AsyncStream<NativeNetworkObservation>.Continuation?
    private(set) var currentSnapshot: NetworkSnapshot = .offline

    init(
        monitorFactory: @escaping MonitorFactory = {
            SystemPlaybackNetworkPathMonitorInstance()
        },
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "com.lovelymusic.playback-network-monitor"
        )
    ) {
        self.monitorFactory = monitorFactory
        self.callbackQueue = callbackQueue
    }

    deinit {
        activeMonitor?.setPathUpdateHandler(nil)
        activeMonitor?.cancel()
        nativeObservationContinuation?.finish()
        nativeObservationTask?.cancel()
    }

    func setUpdateHandler(_ updateHandler: UpdateHandler?) {
        self.updateHandler = updateHandler
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        _ = await publish(.offline)
        ensureNativeObservationDelivery()

        let generation = UUID()
        let monitor = monitorFactory()
        activeMonitorGeneration = generation
        activeMonitor = monitor
        let continuation = nativeObservationContinuation
        monitor.setPathUpdateHandler { observation in
            continuation?.yield(
                NativeNetworkObservation(
                    monitorGeneration: generation,
                    observation: observation
                )
            )
        }
        monitor.start(queue: callbackQueue)
    }

    func stop() async {
        isStarted = false
        activeMonitorGeneration = nil
        let monitor = activeMonitor
        activeMonitor = nil
        monitor?.setPathUpdateHandler(nil)
        monitor?.cancel()
        _ = await publish(.offline)
    }

    @discardableResult
    func receive(
        _ observation: PlaybackNetworkPathObservation
    ) async -> NetworkSnapshot? {
        await publish(observation)
    }

    private func ensureNativeObservationDelivery() {
        guard nativeObservationTask == nil else { return }
        let streamPair = AsyncStream.makeStream(
            of: NativeNetworkObservation.self
        )
        nativeObservationContinuation = streamPair.continuation
        nativeObservationTask = Task { [weak self] in
            for await nativeObservation in streamPair.stream {
                guard !Task.isCancelled, let self else { return }
                _ = await self.receiveNative(nativeObservation)
            }
        }
    }

    @discardableResult
    private func receiveNative(
        _ nativeObservation: NativeNetworkObservation
    ) async -> NetworkSnapshot? {
        guard isStarted,
            activeMonitorGeneration == nativeObservation.monitorGeneration
        else {
            return nil
        }
        return await publish(nativeObservation.observation)
    }

    @discardableResult
    private func publish(
        _ observation: PlaybackNetworkPathObservation
    ) async -> NetworkSnapshot? {
        let nextVersion = currentSnapshot.pathVersion == .max
            ? UInt64.max
            : currentSnapshot.pathVersion + 1
        let candidate = NetworkSnapshot(
            observation: observation,
            pathVersion: nextVersion
        )
        guard !candidate.hasSamePolicyProperties(as: currentSnapshot) else {
            return nil
        }

        currentSnapshot = candidate
        if let updateHandler {
            await updateHandler(candidate)
        }
        return candidate
    }
}

struct StoragePeakMultiplier: Equatable, Sendable {
    let numerator: Int64
    let denominator: Int64

    init(numerator: Int64, denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    fileprivate func conservativeBytes(for contentLength: Int64) -> Int64? {
        guard contentLength > 0,
            numerator >= denominator,
            denominator > 0
        else {
            return nil
        }

        let (product, productOverflow) = contentLength.multipliedReportingOverflow(
            by: numerator
        )
        guard !productOverflow else { return nil }

        let quotient = product / denominator
        guard product % denominator != 0 else { return quotient }
        let (rounded, roundingOverflow) = quotient.addingReportingOverflow(1)
        return roundingOverflow ? nil : rounded
    }
}

struct PlaybackStorageCompatibilityProfile: Equatable, Sendable {
    let legacyPeakMultiplier: StoragePeakMultiplier?
    let legacySafetyMarginBytes: Int64?
    let minimumFreeSpaceReserveBytes: Int64?
    let storageCalibrationID: String?
    let calibratedContentLengthEnvelope: ClosedRange<Int64>?

    static let unavailable = Self(
        legacyPeakMultiplier: nil,
        legacySafetyMarginBytes: nil,
        minimumFreeSpaceReserveBytes: nil,
        storageCalibrationID: nil,
        calibratedContentLengthEnvelope: nil
    )
}

struct FullTransferEstimate: Equatable, Sendable {
    let networkUpperBoundBytes: Int64
    let temporaryStorageUpperBoundBytes: Int64
}

struct FullTransferConsentChallenge: Equatable, Sendable {
    fileprivate let id: UUID
    let token: FailedActionToken
    let networkPolicyRevision: NetworkSnapshot
}

struct FullTransferConsentGrant: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let challengeID: UUID
    let token: FailedActionToken
    let networkPolicyRevision: NetworkSnapshot
}

enum PlaybackPolicyDenial: Error, Equatable, Sendable {
    case cannotEstablishConservativeUpperBound
    case staleStorageCalibration
    case outsideMeasuredStorageEnvelope
    case storageEstimateArithmeticOverflow
    case capacityUnavailable
    case insufficientStorage
    case offline
    case consentChallengeInvalidated
}

enum FullResourceTransferDecisionCategory: Equatable, Sendable {
    case allow
    case requireConsent
    case deny
}

enum FullResourceTransferDecision: Equatable, Sendable {
    case allow(StorageReservationID)
    case requireTransferConsent(
        estimate: FullTransferEstimate,
        token: FailedActionToken,
        challenge: FullTransferConsentChallenge
    )
    case deny(PlaybackPolicyDenial)

    var category: FullResourceTransferDecisionCategory {
        switch self {
        case .allow:
            return .allow
        case .requireTransferConsent:
            return .requireConsent
        case .deny:
            return .deny
        }
    }
}

enum PlaybackStorageReservationResult: Equatable, Sendable {
    case reserved(StorageReservationID)
    case denied(PlaybackPolicyDenial)
}

struct FullResourceTransferRequest: Equatable, Sendable {
    let sessionID: PlaybackSessionID
    let actionID: FullTransferActionID
    let initialGeneration: ContentGenerationScope
    let failureCategory: PlaybackFailureCategory
    let intent: FullTransferIntent
    let validatedContentLength: Int64?
    let latestSeekTargetSeconds: TimeInterval

    static func begin(
        sessionID: PlaybackSessionID,
        initialGeneration: ContentGenerationScope,
        failureCategory: PlaybackFailureCategory,
        intent: FullTransferIntent,
        validatedContentLength: Int64?,
        latestSeekTargetSeconds: TimeInterval
    ) -> Self {
        Self(
            sessionID: sessionID,
            actionID: .fresh(),
            initialGeneration: initialGeneration,
            failureCategory: failureCategory,
            intent: intent,
            validatedContentLength: validatedContentLength,
            latestSeekTargetSeconds: Self.validSeekTarget(
                latestSeekTargetSeconds,
                fallback: 0
            )
        )
    }

    var failedActionToken: FailedActionToken {
        .makeFailedActionToken(
            sessionID: sessionID,
            actionID: actionID,
            initialGeneration: initialGeneration,
            failureCategory: failureCategory,
            intent: intent
        )
    }

    func updatingLatestSeekTarget(to targetSeconds: TimeInterval) -> Self {
        Self(
            sessionID: sessionID,
            actionID: actionID,
            initialGeneration: initialGeneration,
            failureCategory: failureCategory,
            intent: intent,
            validatedContentLength: validatedContentLength,
            latestSeekTargetSeconds: Self.validSeekTarget(
                targetSeconds,
                fallback: latestSeekTargetSeconds
            )
        )
    }

    func explicitRetry(intent: FullTransferIntent) -> Self {
        Self(
            sessionID: sessionID,
            actionID: .fresh(),
            initialGeneration: initialGeneration,
            failureCategory: failureCategory,
            intent: intent,
            validatedContentLength: validatedContentLength,
            latestSeekTargetSeconds: latestSeekTargetSeconds
        )
    }

    private static func validSeekTarget(
        _ candidate: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        candidate.isFinite && candidate >= 0 ? candidate : fallback
    }
}

extension FailedActionToken {
    static func makeFailedActionToken(
        sessionID: PlaybackSessionID,
        actionID: FullTransferActionID,
        initialGeneration: ContentGenerationScope,
        failureCategory: PlaybackFailureCategory,
        intent: FullTransferIntent
    ) -> Self {
        Self(
            sessionID: sessionID,
            actionID: actionID,
            generationFingerprint: initialGeneration.localFingerprint,
            failureCategory: failureCategory,
            intent: intent
        )
    }
}

protocol PlaybackCapacityProviding: Sendable {
    func volumeAvailableCapacityForImportantUsage() async throws -> Int64
}

struct VolumeImportantUsageCapacityProvider: PlaybackCapacityProviding {
    let volumeURL: URL

    func volumeAvailableCapacityForImportantUsage() async throws -> Int64 {
        let values = try volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw PlaybackPolicyDenial.capacityUnavailable
        }
        return capacity
    }
}

private enum StorageCapacityAssessment: Equatable, Sendable {
    case fits
    case unavailable
    case insufficient
}

actor PlaybackStorageReservationLedger {
    private let capacityProvider: any PlaybackCapacityProviding
    private var reservations: [StorageReservationID: Int64] = [:]
    private var totalReservedBytes: Int64 = 0

    init(capacityProvider: any PlaybackCapacityProviding) {
        self.capacityProvider = capacityProvider
    }

    var reservedBytes: Int64 {
        totalReservedBytes
    }

    var reservationCount: Int {
        reservations.count
    }

    func reserve(
        bytes: Int64,
        minimumFreeSpaceReserveBytes: Int64
    ) async -> PlaybackStorageReservationResult {
        switch await capacityAssessment(
            bytes: bytes,
            minimumFreeSpaceReserveBytes: minimumFreeSpaceReserveBytes
        ) {
        case .fits:
            break
        case .unavailable:
            return .denied(.capacityUnavailable)
        case .insufficient:
            return .denied(.insufficientStorage)
        }

        let (newTotal, overflow) = totalReservedBytes.addingReportingOverflow(bytes)
        guard !overflow else { return .denied(.insufficientStorage) }
        let reservationID = StorageReservationID(rawValue: UUID())
        reservations[reservationID] = bytes
        totalReservedBytes = newTotal
        return .reserved(reservationID)
    }

    func release(_ reservationID: StorageReservationID) {
        guard let bytes = reservations.removeValue(forKey: reservationID) else {
            return
        }
        totalReservedBytes -= bytes
    }

    fileprivate func assess(
        bytes: Int64,
        minimumFreeSpaceReserveBytes: Int64
    ) async -> StorageCapacityAssessment {
        await capacityAssessment(
            bytes: bytes,
            minimumFreeSpaceReserveBytes: minimumFreeSpaceReserveBytes
        )
    }

    private func capacityAssessment(
        bytes: Int64,
        minimumFreeSpaceReserveBytes: Int64
    ) async -> StorageCapacityAssessment {
        guard bytes > 0, minimumFreeSpaceReserveBytes >= 0 else {
            return .unavailable
        }
        guard let availableCapacity = try? await capacityProvider
            .volumeAvailableCapacityForImportantUsage(),
            availableCapacity >= 0
        else {
            return .unavailable
        }

        let (afterReservation, reservationOverflow) = totalReservedBytes
            .addingReportingOverflow(bytes)
        guard !reservationOverflow else { return .insufficient }
        let (requiredCapacity, reserveOverflow) = afterReservation
            .addingReportingOverflow(minimumFreeSpaceReserveBytes)
        guard !reserveOverflow else { return .insufficient }
        return availableCapacity >= requiredCapacity ? .fits : .insufficient
    }
}

private struct PlaybackStorageApproval: Equatable, Sendable {
    let estimate: FullTransferEstimate
    let minimumFreeSpaceReserveBytes: Int64
}

private enum PlaybackStorageAssessment: Equatable, Sendable {
    case approved(PlaybackStorageApproval)
    case denied(PlaybackPolicyDenial)
}

struct PlaybackStoragePolicy: Sendable {
    let compatibilityProfile: PlaybackStorageCompatibilityProfile
    let requiredCalibrationID: String?
    let reservationLedger: PlaybackStorageReservationLedger

    fileprivate func assess(
        _ request: FullResourceTransferRequest
    ) async -> PlaybackStorageAssessment {
        guard let contentLength = request.validatedContentLength,
            contentLength > 0,
            let peakMultiplier = compatibilityProfile.legacyPeakMultiplier,
            let safetyMarginBytes = compatibilityProfile.legacySafetyMarginBytes,
            let minimumFreeSpaceReserveBytes =
                compatibilityProfile.minimumFreeSpaceReserveBytes,
            let calibrationID = compatibilityProfile.storageCalibrationID,
            !calibrationID.isEmpty,
            let requiredCalibrationID,
            !requiredCalibrationID.isEmpty,
            let calibratedEnvelope =
                compatibilityProfile.calibratedContentLengthEnvelope,
            calibratedEnvelope.lowerBound > 0,
            safetyMarginBytes >= 0,
            minimumFreeSpaceReserveBytes >= 0
        else {
            return .denied(.cannotEstablishConservativeUpperBound)
        }
        guard calibrationID == requiredCalibrationID else {
            return .denied(.staleStorageCalibration)
        }
        guard calibratedEnvelope.contains(contentLength) else {
            return .denied(.outsideMeasuredStorageEnvelope)
        }
        guard let multipliedBytes = peakMultiplier.conservativeBytes(
            for: contentLength
        ) else {
            return .denied(.storageEstimateArithmeticOverflow)
        }
        let (temporaryBytes, marginOverflow) = multipliedBytes
            .addingReportingOverflow(safetyMarginBytes)
        guard !marginOverflow, temporaryBytes > 0 else {
            return .denied(.storageEstimateArithmeticOverflow)
        }

        let estimate = FullTransferEstimate(
            networkUpperBoundBytes: contentLength,
            temporaryStorageUpperBoundBytes: temporaryBytes
        )
        switch await reservationLedger.assess(
            bytes: temporaryBytes,
            minimumFreeSpaceReserveBytes: minimumFreeSpaceReserveBytes
        ) {
        case .fits:
            return .approved(
                PlaybackStorageApproval(
                    estimate: estimate,
                    minimumFreeSpaceReserveBytes: minimumFreeSpaceReserveBytes
                )
            )
        case .unavailable:
            return .denied(.capacityUnavailable)
        case .insufficient:
            return .denied(.insufficientStorage)
        }
    }

    fileprivate func reserve(
        _ approval: PlaybackStorageApproval
    ) async -> PlaybackStorageReservationResult {
        await reservationLedger.reserve(
            bytes: approval.estimate.temporaryStorageUpperBoundBytes,
            minimumFreeSpaceReserveBytes: approval.minimumFreeSpaceReserveBytes
        )
    }

    func release(_ reservationID: StorageReservationID) async {
        await reservationLedger.release(reservationID)
    }
}

private enum PlaybackTransferConsentState: Equatable, Sendable {
    case challenged(FullTransferConsentChallenge)
    case granted(FullTransferConsentGrant)
    case closed
}

actor PlaybackFullResourceTransferGate {
    private var network: NetworkSnapshot
    private let storagePolicy: PlaybackStoragePolicy
    private var consentStates: [
        FailedActionToken: PlaybackTransferConsentState
    ] = [:]

    init(network: NetworkSnapshot, storagePolicy: PlaybackStoragePolicy) {
        self.network = network
        self.storagePolicy = storagePolicy
    }

    func updateNetwork(_ network: NetworkSnapshot) {
        guard network.pathVersion > self.network.pathVersion else { return }
        self.network = network
    }

    func acceptConsent(
        _ challenge: FullTransferConsentChallenge
    ) -> FullTransferConsentGrant? {
        guard case .challenged(let pendingChallenge)? =
            consentStates[challenge.token],
            pendingChallenge == challenge
        else {
            return nil
        }
        guard network == challenge.networkPolicyRevision else {
            consentStates[challenge.token] = .closed
            return nil
        }

        let grant = FullTransferConsentGrant(
            id: UUID(),
            challengeID: challenge.id,
            token: challenge.token,
            networkPolicyRevision: challenge.networkPolicyRevision
        )
        consentStates[challenge.token] = .granted(grant)
        return grant
    }

    func evaluate(
        _ request: FullResourceTransferRequest,
        consentGrant: FullTransferConsentGrant? = nil
    ) async -> FullResourceTransferDecision {
        while true {
            let storageAssessment = await storagePolicy.assess(request)
            guard case .approved(let storageApproval) = storageAssessment else {
                guard case .denied(let denial) = storageAssessment else {
                    return .deny(.cannotEstablishConservativeUpperBound)
                }
                return .deny(denial)
            }

            let networkSnapshot = network
            let token = request.failedActionToken
            guard networkSnapshot.classification != .offline else {
                if consentStates[token] != nil {
                    consentStates[token] = .closed
                }
                return .deny(.offline)
            }

            if networkSnapshot.requiresTransferConsent {
                if let consentGrant {
                    guard consentGrant.token == token,
                        consentGrant.networkPolicyRevision == networkSnapshot,
                        case .granted(let issuedGrant)? = consentStates[token],
                        issuedGrant == consentGrant
                    else {
                        closeRejectedGrant(
                            consentGrant,
                            requestToken: token
                        )
                        return .deny(.consentChallengeInvalidated)
                    }
                    consentStates[token] = .closed
                } else {
                    switch consentStates[token] {
                    case nil:
                        let challenge = FullTransferConsentChallenge(
                            id: UUID(),
                            token: token,
                            networkPolicyRevision: networkSnapshot
                        )
                        consentStates[token] = .challenged(challenge)
                        return .requireTransferConsent(
                            estimate: storageApproval.estimate,
                            token: token,
                            challenge: challenge
                        )
                    case .challenged(let challenge):
                        guard challenge.networkPolicyRevision == networkSnapshot else {
                            consentStates[token] = .closed
                            return .deny(.consentChallengeInvalidated)
                        }
                        return .requireTransferConsent(
                            estimate: storageApproval.estimate,
                            token: token,
                            challenge: challenge
                        )
                    case .granted, .closed:
                        return .deny(.consentChallengeInvalidated)
                    }
                }
            } else if consentStates[token] != nil {
                consentStates[token] = .closed
            }

            let reservationResult = await storagePolicy.reserve(storageApproval)
            guard case .reserved(let reservationID) = reservationResult else {
                guard case .denied(let denial) = reservationResult else {
                    return .deny(.capacityUnavailable)
                }
                return .deny(denial)
            }
            guard network == networkSnapshot else {
                await storagePolicy.release(reservationID)
                continue
            }
            return .allow(reservationID)
        }
    }

    func releaseReservationAndReevaluate(
        _ request: FullResourceTransferRequest,
        activeReservationID: StorageReservationID
    ) async -> FullResourceTransferDecision {
        await storagePolicy.release(activeReservationID)
        return await evaluate(request)
    }

    func release(_ reservationID: StorageReservationID) async {
        await storagePolicy.release(reservationID)
    }

    private func closeRejectedGrant(
        _ grant: FullTransferConsentGrant,
        requestToken: FailedActionToken
    ) {
        if case .granted(let issuedGrant)? = consentStates[grant.token],
            issuedGrant == grant
        {
            consentStates[grant.token] = .closed
        }
        if consentStates[requestToken] != nil {
            consentStates[requestToken] = .closed
        }
    }
}

struct FullTransferConsentLifecycle: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case presented
        case accepted
        case declined
    }

    private var statuses: [FailedActionToken: Status] = [:]

    mutating func present(_ token: FailedActionToken) -> Bool {
        guard statuses[token] == nil else { return false }
        statuses[token] = .presented
        return true
    }

    mutating func accept(_ token: FailedActionToken) -> Bool {
        guard statuses[token] == .presented else { return false }
        statuses[token] = .accepted
        return true
    }

    mutating func decline(_ token: FailedActionToken) -> Bool {
        guard statuses[token] == .presented else { return false }
        statuses[token] = .declined
        return true
    }

    func status(for token: FailedActionToken) -> Status? {
        statuses[token]
    }
}
