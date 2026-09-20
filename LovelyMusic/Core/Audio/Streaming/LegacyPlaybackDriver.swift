import Foundation

struct LegacyPlaybackRequest: Equatable, Sendable {
    let descriptor: StreamDescriptor
    let validatedContentLength: Int64
    let targetSeconds: TimeInterval
    let intent: DesiredPlaybackIntent
    let reservationID: StorageReservationID
    let tokens: ActivePlaybackTokens

    init(
        descriptor: StreamDescriptor,
        validatedContentLength: Int64,
        targetSeconds: TimeInterval,
        intent: DesiredPlaybackIntent,
        reservationID: StorageReservationID,
        tokens: ActivePlaybackTokens
    ) {
        self.descriptor = descriptor
        self.validatedContentLength = validatedContentLength
        self.targetSeconds = targetSeconds
        self.intent = intent
        self.reservationID = reservationID
        self.tokens = tokens
    }
}

struct LegacyPlaybackArtifacts: Equatable, Sendable {
    let rawURL: URL
    let remuxedURL: URL
}

struct LegacyDownloadedResource: Equatable, Sendable {
    let request: LegacyPlaybackRequest
    let rawURL: URL
    let remuxedURL: URL
}

protocol LegacyMediaDownloading: Sendable {
    func download(
        _ request: LegacyPlaybackRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws
}

protocol MediaRemuxing: Sendable {
    func remux(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws
}

protocol LegacyPlaybackFileManaging: Sendable {
    func artifacts(for request: LegacyPlaybackRequest) async throws
        -> LegacyPlaybackArtifacts
    func removeIfPresent(_ url: URL) async
    func fileSize(_ url: URL) async throws -> Int64
}

protocol LegacyPlaybackMonotonicClock: Sendable {
    var now: TimeInterval { get }
}

@MainActor
protocol GuardedLegacyArtifactHosting: AnyObject, Sendable {
    var currentPosition: TimeInterval { get }
    func installArtifact(_ url: URL, song: Song, isRaw: Bool)
    func seek(to targetSeconds: TimeInterval) async -> TimeInterval?
    func play()
    func pause()
}

struct LegacyPlaybackEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case downloadCompleted(URL)
        case rawArtifactPrepared(URL)
        case remuxCompleted(URL)
        case localSeekPrepared(URL, targetSeconds: TimeInterval)
    }

    let kind: Kind
    let monotonicTimestamp: TimeInterval
}

enum LegacyPlaybackDriverError: Error, Equatable, Sendable {
    case invalidValidatedContentLength
    case remuxFailed
    case transportRequiresRegate(StorageReservationID)
    case localArtifactFailure
    case incompleteDownload(expectedBytes: Int64, actualBytes: Int64)
    case staleTokens
}

enum LegacyMediaDownloadError: Error, Equatable, Sendable {
    case unacceptableHTTPStatus(Int)
    case partialResponseNotAllowed
    case missingResponseContentLength
    case responseContentLengthMismatch(expected: Int64, actual: Int64)
    case validatedLengthExceeded
    case localWriteFailed
}

enum LegacyPlaybackProgress: Equatable, Sendable {
    case validatedResponseBodyBytes(
        tokens: ActivePlaybackTokens,
        totalUniqueBytes: Int64
    )
    case remuxOutputBytes(
        tokens: ActivePlaybackTokens,
        totalBytes: Int64
    )

    var tokens: ActivePlaybackTokens {
        switch self {
        case .validatedResponseBodyBytes(let tokens, _),
            .remuxOutputBytes(let tokens, _):
            return tokens
        }
    }

    var validatedResponseBodyBytes: Int64? {
        guard case .validatedResponseBodyBytes(_, let bytes) = self else {
            return nil
        }
        return bytes
    }

    var remuxOutputBytes: Int64? {
        guard case .remuxOutputBytes(_, let bytes) = self else { return nil }
        return bytes
    }
}

/// Performs exactly one already-authorized full-resource attempt.
///
/// Reservation release and every retry remain the coordinator's responsibility.
/// The driver owns only its temporary artifacts and neutral preparation events.
actor LegacyPlaybackDriver {
    typealias TokenValidator = @MainActor @Sendable (ActivePlaybackTokens) async -> Bool
    typealias EventSink = @Sendable (LegacyPlaybackEvent) async -> Void
    typealias ProgressSink = @Sendable (LegacyPlaybackProgress) async -> Void

    private let transport: any LegacyMediaDownloading
    private let remuxer: any MediaRemuxing
    private let fileSystem: any LegacyPlaybackFileManaging
    private let clock: any LegacyPlaybackMonotonicClock
    private let tokenValidator: TokenValidator
    private let eventSink: EventSink
    private var artifactsByAttempt: [SourceAttemptID: LegacyPlaybackArtifacts] = [:]
    private var responseHighWaterByAttempt: [SourceAttemptID: Int64] = [:]
    private var remuxHighWaterByAttempt: [SourceAttemptID: Int64] = [:]
    private var activeRemuxAttempts: Set<SourceAttemptID> = []
    private var pendingRemuxCancellation: Set<SourceAttemptID> = []

    var trackedAttemptCount: Int { artifactsByAttempt.count }

    init(
        transport: any LegacyMediaDownloading,
        remuxer: any MediaRemuxing,
        fileSystem: any LegacyPlaybackFileManaging,
        clock: any LegacyPlaybackMonotonicClock,
        tokenValidator: @escaping TokenValidator,
        eventSink: @escaping EventSink
    ) {
        self.transport = transport
        self.remuxer = remuxer
        self.fileSystem = fileSystem
        self.clock = clock
        self.tokenValidator = tokenValidator
        self.eventSink = eventSink
    }

    func download(
        _ request: LegacyPlaybackRequest,
        progressSink: ProgressSink? = nil
    ) async throws
        -> LegacyDownloadedResource
    {
        guard request.validatedContentLength > 0 else {
            throw LegacyPlaybackDriverError.invalidValidatedContentLength
        }
        guard await tokenValidator(request.tokens) else {
            throw LegacyPlaybackDriverError.staleTokens
        }

        let artifacts = try await fileSystem.artifacts(for: request)
        let attemptID = request.tokens.currentSourceAttempt.id
        artifactsByAttempt[attemptID] = artifacts
        responseHighWaterByAttempt[attemptID] = 0

        do {
            try Task.checkCancellation()
            try await transport.download(
                request,
                to: artifacts.rawURL,
                progress: { [weak self] totalUniqueBytes in
                    await self?.recordValidatedResponseProgress(
                        totalUniqueBytes,
                        request: request,
                        sink: progressSink
                    )
                }
            )
        } catch is CancellationError {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw CancellationError()
        } catch LegacyMediaDownloadError.localWriteFailed {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw LegacyPlaybackDriverError.localArtifactFailure
        } catch {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw LegacyPlaybackDriverError.transportRequiresRegate(
                request.reservationID
            )
        }

        do {
            try Task.checkCancellation()
        } catch {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw CancellationError()
        }

        let actualBytes: Int64
        do {
            actualBytes = try await fileSystem.fileSize(artifacts.rawURL)
        } catch {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw LegacyPlaybackDriverError.localArtifactFailure
        }
        let expectedBytes = request.validatedContentLength
        guard expectedBytes > 0, actualBytes == expectedBytes else {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw LegacyPlaybackDriverError.incompleteDownload(
                expectedBytes: expectedBytes,
                actualBytes: actualBytes
            )
        }
        guard await tokenValidator(request.tokens) else {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw LegacyPlaybackDriverError.staleTokens
        }

        let resource = LegacyDownloadedResource(
            request: request,
            rawURL: artifacts.rawURL,
            remuxedURL: artifacts.remuxedURL
        )
        await publish(.downloadCompleted(resource.rawURL))
        await publish(.rawArtifactPrepared(resource.rawURL))
        return resource
    }

    @discardableResult
    func remux(
        _ resource: LegacyDownloadedResource,
        progressSink: ProgressSink? = nil
    ) async throws -> URL {
        let attemptID = resource.request.tokens.currentSourceAttempt.id
        let artifacts = LegacyPlaybackArtifacts(
            rawURL: resource.rawURL,
            remuxedURL: resource.remuxedURL
        )
        activeRemuxAttempts.insert(attemptID)
        defer { clearRemuxCoordination(attemptID: attemptID) }
        remuxHighWaterByAttempt[attemptID] = 0
        let tokensAreCurrent = await tokenValidator(resource.request.tokens)
        if remuxCancellationWasRequested(attemptID: attemptID) {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw CancellationError()
        }
        guard tokensAreCurrent else {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw LegacyPlaybackDriverError.staleTokens
        }

        do {
            try Task.checkCancellation()
            try await remuxer.remux(
                source: resource.rawURL,
                destination: resource.remuxedURL,
                progress: { [weak self] totalBytes in
                    await self?.recordRemuxProgress(
                        totalBytes,
                        request: resource.request,
                        sink: progressSink
                    )
                }
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw CancellationError()
        } catch {
            if remuxCancellationWasRequested(attemptID: attemptID) {
                await cleanUp(attemptID: attemptID, artifacts: artifacts)
                throw CancellationError()
            }
            // A remux retry is local-only, so preserve the complete raw artifact.
            throw LegacyPlaybackDriverError.remuxFailed
        }

        if remuxCancellationWasRequested(attemptID: attemptID) {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw CancellationError()
        }
        let tokensRemainCurrent = await tokenValidator(resource.request.tokens)
        if remuxCancellationWasRequested(attemptID: attemptID) {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw CancellationError()
        }
        guard tokensRemainCurrent else {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw LegacyPlaybackDriverError.staleTokens
        }
        await publish(.remuxCompleted(resource.remuxedURL))
        if remuxCancellationWasRequested(attemptID: attemptID) {
            await cleanUp(attemptID: attemptID, artifacts: artifacts)
            throw CancellationError()
        }
        return resource.remuxedURL
    }

    func prepareLocalSeek(
        _ resource: LegacyDownloadedResource,
        targetSeconds: TimeInterval
    ) async throws {
        guard targetSeconds.isFinite, targetSeconds >= 0,
            await tokenValidator(resource.request.tokens)
        else {
            let artifacts = LegacyPlaybackArtifacts(
                rawURL: resource.rawURL,
                remuxedURL: resource.remuxedURL
            )
            await cleanUp(
                attemptID: resource.request.tokens.currentSourceAttempt.id,
                artifacts: artifacts
            )
            throw LegacyPlaybackDriverError.staleTokens
        }
        await publish(
            .localSeekPrepared(
                resource.remuxedURL,
                targetSeconds: targetSeconds
            )
        )
    }

    func cancel(_ request: LegacyPlaybackRequest) async {
        let attemptID = request.tokens.currentSourceAttempt.id
        if activeRemuxAttempts.contains(attemptID) {
            pendingRemuxCancellation.insert(attemptID)
            return
        }
        guard let artifacts = artifactsByAttempt[attemptID] else { return }
        await cleanUp(attemptID: attemptID, artifacts: artifacts)
    }

    /// Ends driver ownership after the host has installed or retained the artifact.
    func finish(_ resource: LegacyDownloadedResource) {
        let attemptID = resource.request.tokens.currentSourceAttempt.id
        artifactsByAttempt.removeValue(forKey: attemptID)
        responseHighWaterByAttempt.removeValue(forKey: attemptID)
        remuxHighWaterByAttempt.removeValue(forKey: attemptID)
        clearRemuxCoordination(attemptID: attemptID)
    }

    /// Disposes an artifact after ownership has been handed to the playback host.
    /// The file manager operation is intentionally idempotent.
    func dispose(_ resource: LegacyDownloadedResource) async {
        let artifacts = LegacyPlaybackArtifacts(
            rawURL: resource.rawURL,
            remuxedURL: resource.remuxedURL
        )
        await fileSystem.removeIfPresent(artifacts.rawURL)
        await fileSystem.removeIfPresent(artifacts.remuxedURL)
        let attemptID = resource.request.tokens.currentSourceAttempt.id
        artifactsByAttempt.removeValue(forKey: attemptID)
        responseHighWaterByAttempt.removeValue(forKey: attemptID)
        remuxHighWaterByAttempt.removeValue(forKey: attemptID)
        clearRemuxCoordination(attemptID: attemptID)
    }

    private func publish(_ kind: LegacyPlaybackEvent.Kind) async {
        await eventSink(
            LegacyPlaybackEvent(kind: kind, monotonicTimestamp: clock.now)
        )
    }

    private func recordValidatedResponseProgress(
        _ totalUniqueBytes: Int64,
        request: LegacyPlaybackRequest,
        sink: ProgressSink?
    ) async {
        let attemptID = request.tokens.currentSourceAttempt.id
        let previous = responseHighWaterByAttempt[attemptID] ?? 0
        guard totalUniqueBytes > 0,
            totalUniqueBytes <= request.validatedContentLength,
            totalUniqueBytes > previous
        else {
            return
        }
        responseHighWaterByAttempt[attemptID] = totalUniqueBytes
        await sink?(
            .validatedResponseBodyBytes(
                tokens: request.tokens,
                totalUniqueBytes: totalUniqueBytes
            )
        )
    }

    private func recordRemuxProgress(
        _ totalBytes: Int64,
        request: LegacyPlaybackRequest,
        sink: ProgressSink?
    ) async {
        let attemptID = request.tokens.currentSourceAttempt.id
        let previous = remuxHighWaterByAttempt[attemptID] ?? 0
        guard activeRemuxAttempts.contains(attemptID),
            !pendingRemuxCancellation.contains(attemptID),
            totalBytes > 0,
            totalBytes > previous
        else {
            return
        }
        remuxHighWaterByAttempt[attemptID] = totalBytes
        await sink?(
            .remuxOutputBytes(tokens: request.tokens, totalBytes: totalBytes)
        )
    }

    private func cleanUp(
        attemptID: SourceAttemptID,
        artifacts: LegacyPlaybackArtifacts
    ) async {
        clearRemuxCoordination(attemptID: attemptID)
        guard artifactsByAttempt.removeValue(forKey: attemptID) != nil else { return }
        responseHighWaterByAttempt.removeValue(forKey: attemptID)
        remuxHighWaterByAttempt.removeValue(forKey: attemptID)
        await fileSystem.removeIfPresent(artifacts.rawURL)
        await fileSystem.removeIfPresent(artifacts.remuxedURL)
    }

    private func remuxCancellationWasRequested(
        attemptID: SourceAttemptID
    ) -> Bool {
        Task.isCancelled || pendingRemuxCancellation.contains(attemptID)
    }

    private func clearRemuxCoordination(attemptID: SourceAttemptID) {
        activeRemuxAttempts.remove(attemptID)
        pendingRemuxCancellation.remove(attemptID)
    }
}

protocol LegacyDescriptorProbing: Sendable {
    func probe(
        descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> LegacyDescriptorProbeResult
}

struct LegacyDescriptorProbeResult: Equatable, Sendable {
    let generationScope: ContentGenerationScope
    let responseBodyBytes: Int64
}

struct QualifiedLegacyDescriptor: Equatable, Sendable {
    let descriptor: StreamDescriptor
    let validatedContentLength: Int64
    let generationScope: ContentGenerationScope
    let metadataProbeResponseBodyBytes: Int64
}

enum LegacyDescriptorQualificationError: Error, Equatable, Sendable {
    case probeByteCeilingExceeded
    case cannotEstablishValidatedGeneration
    case originContentLengthMismatch
    case generationScopeMismatch
}

struct LegacyDescriptorQualifier: Sendable {
    private let probe: any LegacyDescriptorProbing

    init(probe: any LegacyDescriptorProbing) {
        self.probe = probe
    }

    func qualify(
        descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> QualifiedLegacyDescriptor {
        let result: LegacyDescriptorProbeResult
        do {
            result = try await probe.probe(descriptor: descriptor, tokens: tokens)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LegacyDescriptorQualificationError {
            throw error
        } catch {
            throw LegacyDescriptorQualificationError.cannotEstablishValidatedGeneration
        }
        guard result.responseBodyBytes >= 0, result.responseBodyBytes <= 1 else {
            throw LegacyDescriptorQualificationError.probeByteCeilingExceeded
        }

        let totalLength: Int64
        switch result.generationScope {
        case .attemptOnly(let sessionID, let sourceAttemptID, let length):
            guard sessionID == tokens.sessionID,
                sourceAttemptID == tokens.currentSourceAttempt.id
            else {
                throw LegacyDescriptorQualificationError.generationScopeMismatch
            }
            totalLength = length
        case .persistent(let generation):
            guard generation.provisionalKey == descriptor.provisionalResourceKey else {
                throw LegacyDescriptorQualificationError.generationScopeMismatch
            }
            totalLength = generation.totalLength
        }

        guard totalLength > 0 else {
            throw LegacyDescriptorQualificationError.cannotEstablishValidatedGeneration
        }
        if let declared = descriptor.contentLength, declared != totalLength {
            throw LegacyDescriptorQualificationError.originContentLengthMismatch
        }
        return QualifiedLegacyDescriptor(
            descriptor: descriptor,
            validatedContentLength: totalLength,
            generationScope: result.generationScope,
            metadataProbeResponseBodyBytes: result.responseBodyBytes
        )
    }
}

enum GuardedLegacyRouting {
    static func isRangeEligible(
        controls: PlaybackFeatureSnapshot,
        cohortEligible: Bool,
        capabilityStatus: PlaybackCapabilityStatus
    ) -> Bool {
        controls.hasSupportedSchema
            && controls.rangeStreamingV1
            && !controls.killSwitch
            && cohortEligible
            && capabilityStatus == .supported
    }
}

protocol GuardedLegacyTransferGating: Sendable {
    func updateNetwork(_ snapshot: NetworkSnapshot) async
    func evaluate(
        _ request: FullResourceTransferRequest,
        consentGrant: FullTransferConsentGrant?
    ) async -> FullResourceTransferDecision
    func acceptConsent(
        _ challenge: FullTransferConsentChallenge
    ) async -> FullTransferConsentGrant?
    func releaseReservation(_ reservationID: StorageReservationID) async
}

enum TransferConsentUserDisposition: Equatable, Sendable {
    case accept
    case decline
    case dismissed
}

struct TransferConsentViewState: Equatable, Sendable {
    let token: FailedActionToken
    let targetSeconds: TimeInterval
    let networkUpperBoundBytes: Int64
    let temporaryStorageUpperBoundBytes: Int64
}

enum GuardedPlaybackError: Error, Equatable, Sendable {
    case policyDenied(PlaybackPolicyDenial)
    case transferConsentDeclined
    case continueOnPhone
    case descriptorQualificationFailed(LegacyDescriptorQualificationError)
    case legacyTransportFailed
    case legacyRemuxFailed
    case rangePathUnavailable

    var isRecoverable: Bool {
        switch self {
        case .policyDenied(.cannotEstablishConservativeUpperBound):
            return false
        case .policyDenied, .transferConsentDeclined, .continueOnPhone,
            .descriptorQualificationFailed, .legacyTransportFailed,
            .legacyRemuxFailed, .rangePathUnavailable:
            return true
        }
    }
}

enum GuardedLegacyHostCommand: Equatable, Sendable {
    case playRawArtifact
    case installRemuxedArtifact
    case seekLocalArtifact(targetSeconds: TimeInterval)
}

struct GuardedLegacyPlaybackConfiguration: @unchecked Sendable {
    typealias DescriptorResolver = @MainActor @Sendable (String) async throws
        -> StreamDescriptor
    typealias CurrentNetworkSnapshot = @Sendable () async -> NetworkSnapshot
    typealias RangeEligibility = @Sendable (StreamDescriptor) -> Bool
    typealias LegacyRemuxWillBegin = @MainActor @Sendable (FallbackAttempt) -> Void
    typealias HostCommandSink = @MainActor @Sendable (GuardedLegacyHostCommand) -> Void
    typealias SynchronousArtifactDisposer = @Sendable (LegacyDownloadedResource) -> Void

    let descriptorResolver: DescriptorResolver
    let descriptorQualifier: LegacyDescriptorQualifier
    let transferGate: any GuardedLegacyTransferGating
    let legacyDriver: LegacyPlaybackDriver
    let initialNetworkSnapshot: NetworkSnapshot
    let currentNetworkSnapshot: CurrentNetworkSnapshot
    let isRangeEligible: RangeEligibility
    let legacyRemuxWillBegin: LegacyRemuxWillBegin
    let artifactHost: any GuardedLegacyArtifactHosting
    let disposeCompletedArtifactSynchronously: SynchronousArtifactDisposer
    let monotonicClock: (any PlaybackMonotonicClock)?
    let watchdogScheduler: (any PlaybackWatchdogScheduling)?
    let hostCommandSink: HostCommandSink

    init(
        descriptorResolver: @escaping DescriptorResolver,
        descriptorQualifier: LegacyDescriptorQualifier,
        transferGate: any GuardedLegacyTransferGating,
        legacyDriver: LegacyPlaybackDriver,
        initialNetworkSnapshot: NetworkSnapshot,
        currentNetworkSnapshot: @escaping CurrentNetworkSnapshot,
        isRangeEligible: @escaping RangeEligibility,
        legacyRemuxWillBegin: @escaping LegacyRemuxWillBegin = { _ in },
        artifactHost: any GuardedLegacyArtifactHosting,
        disposeCompletedArtifactSynchronously: @escaping SynchronousArtifactDisposer,
        monotonicClock: (any PlaybackMonotonicClock)? = nil,
        watchdogScheduler: (any PlaybackWatchdogScheduling)? = nil,
        hostCommandSink: @escaping HostCommandSink = { _ in }
    ) {
        self.descriptorResolver = descriptorResolver
        self.descriptorQualifier = descriptorQualifier
        self.transferGate = transferGate
        self.legacyDriver = legacyDriver
        self.initialNetworkSnapshot = initialNetworkSnapshot
        self.currentNetworkSnapshot = currentNetworkSnapshot
        self.isRangeEligible = isRangeEligible
        self.legacyRemuxWillBegin = legacyRemuxWillBegin
        self.artifactHost = artifactHost
        self.disposeCompletedArtifactSynchronously = disposeCompletedArtifactSynchronously
        self.monotonicClock = monotonicClock
        self.watchdogScheduler = watchdogScheduler
        self.hostCommandSink = hostCommandSink
    }
}

struct SystemLegacyPlaybackClock: LegacyPlaybackMonotonicClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

struct URLSessionLegacyMediaDownloader: LegacyMediaDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let beforeTaskResume: @Sendable () async -> Void

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        beforeTaskResume: @escaping @Sendable () async -> Void = {}
    ) {
        self.configuration = Self.sanitizedConfiguration(configuration)
        self.beforeTaskResume = beforeTaskResume
    }

    static func sanitizedConfiguration(
        _ source: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        let configuration = source.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func download(
        _ request: LegacyPlaybackRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.descriptor.remoteURL)
        urlRequest.httpMethod = "GET"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60
        for (field, value) in request.descriptor.requestHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.setValue(nil, forHTTPHeaderField: "Range")
        urlRequest.setValue(nil, forHTTPHeaderField: "If-Range")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try await LegacyMediaDownloadOperation(
            request: urlRequest,
            destination: destination,
            validatedContentLength: request.validatedContentLength,
            progress: progress,
            beforeTaskResume: beforeTaskResume
        ).run(configuration: configuration)
    }
}

private final class LegacyMediaDownloadOperation: NSObject,
    URLSessionDataDelegate, @unchecked Sendable
{
    private let request: URLRequest
    private let destination: URL
    private let validatedContentLength: Int64
    private let progress: @Sendable (Int64) async -> Void
    private let beforeTaskResume: @Sendable () async -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var cumulativeBytes: Int64 = 0
    private var pendingError: Error?
    private var progressTail: Task<Void, Never>?
    private var isFinished = false
    private var callerCancelled = false

    init(
        request: URLRequest,
        destination: URL,
        validatedContentLength: Int64,
        progress: @escaping @Sendable (Int64) async -> Void,
        beforeTaskResume: @escaping @Sendable () async -> Void
    ) {
        self.request = request
        self.destination = destination
        self.validatedContentLength = validatedContentLength
        self.progress = progress
        self.beforeTaskResume = beforeTaskResume
    }

    func run(configuration: URLSessionConfiguration) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                delegateQueue.qualityOfService = .userInitiated
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                let task = session.dataTask(with: request)
                let shouldCancel = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return callerCancelled
                }
                Task { [weak self] in
                    guard let self else { return }
                    await self.beforeTaskResume()
                    let canResume = self.lock.withLock {
                        !self.callerCancelled && !shouldCancel
                    }
                    if canResume {
                        task.resume()
                    } else {
                        task.cancel()
                        self.finish(CancellationError())
                    }
                }
            }
        } onCancel: {
            let task = self.lock.withLock { () -> URLSessionDataTask? in
                self.callerCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            reject(LegacyMediaDownloadError.unacceptableHTTPStatus(-1))
            completionHandler(.cancel)
            return
        }
        guard response.statusCode != 206,
            response.value(forHTTPHeaderField: "Content-Range") == nil
        else {
            reject(LegacyMediaDownloadError.partialResponseNotAllowed)
            completionHandler(.cancel)
            return
        }
        guard response.statusCode == 200 else {
            reject(LegacyMediaDownloadError.unacceptableHTTPStatus(response.statusCode))
            completionHandler(.cancel)
            return
        }
        guard let rawLength = response.value(forHTTPHeaderField: "Content-Length"),
            let declaredLength = Int64(rawLength)
        else {
            reject(LegacyMediaDownloadError.missingResponseContentLength)
            completionHandler(.cancel)
            return
        }
        guard declaredLength == validatedContentLength else {
            reject(
                LegacyMediaDownloadError.responseContentLengthMismatch(
                    expected: validatedContentLength,
                    actual: declaredLength
                )
            )
            completionHandler(.cancel)
            return
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil
            ) else {
                throw LegacyMediaDownloadError.localWriteFailed
            }
            fileHandle = try FileHandle(forWritingTo: destination)
            completionHandler(.allow)
        } catch {
            reject(LegacyMediaDownloadError.localWriteFailed)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let nextTotal = cumulativeBytes + Int64(data.count)
        guard nextTotal <= validatedContentLength else {
            reject(LegacyMediaDownloadError.validatedLengthExceeded)
            dataTask.cancel()
            return
        }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            reject(LegacyMediaDownloadError.localWriteFailed)
            dataTask.cancel()
            return
        }
        cumulativeBytes = nextTotal
        let previous = progressTail
        let progress = self.progress
        progressTail = Task {
            await previous?.value
            await progress(nextTotal)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let completionState = lock.withLock { (callerCancelled, pendingError) }
        let completionError: Error?
        if completionState.0 {
            completionError = CancellationError()
        } else if let pendingError = completionState.1 {
            completionError = pendingError
        } else {
            completionError = error
        }
        let progressTail = self.progressTail
        Task { [weak self] in
            await progressTail?.value
            self?.finish(completionError)
        }
    }

    private func reject(_ error: Error) {
        lock.withLock {
            if pendingError == nil { pendingError = error }
        }
    }

    private func finish(_ error: Error?) {
        let result = lock.withLock {
            () -> (CheckedContinuation<Void, Error>?, URLSession?, FileHandle?) in
            guard !isFinished else { return (nil, nil, nil) }
            isFinished = true
            let result = (continuation, session, fileHandle)
            continuation = nil
            session = nil
            fileHandle = nil
            task = nil
            return result
        }
        try? result.2?.close()
        result.1?.finishTasksAndInvalidate()
        if let error {
            result.0?.resume(throwing: error)
        } else {
            result.0?.resume()
        }
    }
}

struct FileManagerLegacyPlaybackFiles: LegacyPlaybackFileManaging {
    private let root: URL

    init(
        root: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LovelyMusic/GuardedLegacy", isDirectory: true)
    ) {
        self.root = root
    }

    func artifacts(for request: LegacyPlaybackRequest) async throws
        -> LegacyPlaybackArtifacts
    {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let identity = request.tokens.currentSourceAttempt.id.rawValue.uuidString
        return LegacyPlaybackArtifacts(
            rawURL: root.appendingPathComponent("\(identity)-raw.m4a"),
            remuxedURL: root.appendingPathComponent("\(identity)-remuxed.m4a")
        )
    }

    func removeIfPresent(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    func disposeCompletedArtifactSynchronously(
        _ resource: LegacyDownloadedResource
    ) {
        try? FileManager.default.removeItem(at: resource.rawURL)
        try? FileManager.default.removeItem(at: resource.remuxedURL)
    }

    func fileSize(_ url: URL) async throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(size)
    }
}

struct AudioEngineLegacyMediaRemuxer: MediaRemuxing {
    func remux(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        guard await AudioEngine.remuxToStandardMP4(
            source: source,
            destination: destination
        ) else {
            throw LegacyPlaybackDriverError.remuxFailed
        }
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        await progress(Int64(values.fileSize ?? 0))
    }
}

struct HeaderOnlyLegacyDescriptorProbe: LegacyDescriptorProbing, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let beforeTaskResume: @Sendable () async -> Void

    init(
        session: URLSession = .shared,
        beforeTaskResume: @escaping @Sendable () async -> Void = {}
    ) {
        configuration = URLSessionLegacyMediaDownloader.sanitizedConfiguration(
            session.configuration
        )
        self.beforeTaskResume = beforeTaskResume
    }

    func probe(
        descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> LegacyDescriptorProbeResult {
        try Task.checkCancellation()
        var request = URLRequest(url: descriptor.remoteURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        for (field, value) in descriptor.requestHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue(nil, forHTTPHeaderField: "If-Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await LegacyDescriptorProbeOperation(
            request: request,
            tokens: tokens,
            beforeTaskResume: beforeTaskResume
        ).run(configuration: configuration)
    }
}

private final class LegacyDescriptorProbeOperation: NSObject,
    URLSessionDataDelegate, @unchecked Sendable
{
    private let request: URLRequest
    private let tokens: ActivePlaybackTokens
    private let beforeTaskResume: @Sendable () async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LegacyDescriptorProbeResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var validatedTotalLength: Int64?
    private var responseBodyBytes: Int64 = 0
    private var pendingError: Error?
    private var isFinished = false
    private var callerCancelled = false

    init(
        request: URLRequest,
        tokens: ActivePlaybackTokens,
        beforeTaskResume: @escaping @Sendable () async -> Void
    ) {
        self.request = request
        self.tokens = tokens
        self.beforeTaskResume = beforeTaskResume
    }

    func run(configuration: URLSessionConfiguration) async throws
        -> LegacyDescriptorProbeResult
    {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                let task = session.dataTask(with: request)
                let shouldCancel = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return callerCancelled
                }
                Task { [weak self] in
                    guard let self else { return }
                    await self.beforeTaskResume()
                    let canResume = self.lock.withLock {
                        !self.callerCancelled && !shouldCancel
                    }
                    if canResume {
                        task.resume()
                    } else {
                        task.cancel()
                        self.finish(.failure(CancellationError()))
                    }
                }
            }
        } onCancel: {
            let task = self.lock.withLock { () -> URLSessionDataTask? in
                self.callerCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
            response.statusCode == 206,
            response.value(forHTTPHeaderField: "Content-Length") == "1",
            let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
            let totalLength = Self.validatedTotalLength(from: contentRange)
        else {
            reject(.cannotEstablishValidatedGeneration)
            completionHandler(.cancel)
            return
        }
        validatedTotalLength = totalLength
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let nextTotal = responseBodyBytes + Int64(data.count)
        guard nextTotal <= 1 else {
            reject(.probeByteCeilingExceeded)
            dataTask.cancel()
            return
        }
        responseBodyBytes = nextTotal
        if responseBodyBytes == 1 {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let completionState = lock.withLock { (callerCancelled, pendingError) }
        let result: Result<LegacyDescriptorProbeResult, Error>
        if completionState.0 {
            result = .failure(CancellationError())
        } else if let pendingError = completionState.1 {
            result = .failure(pendingError)
        } else if let validatedTotalLength, responseBodyBytes == 1 {
            result = .success(
                LegacyDescriptorProbeResult(
                    generationScope: .attemptOnly(
                        sessionID: tokens.sessionID,
                        sourceAttemptID: tokens.currentSourceAttempt.id,
                        totalLength: validatedTotalLength
                    ),
                    responseBodyBytes: responseBodyBytes
                )
            )
        } else {
            result = .failure(
                error
                    ?? LegacyDescriptorQualificationError
                        .cannotEstablishValidatedGeneration
            )
        }
        finish(result)
    }

    private func reject(_ error: LegacyDescriptorQualificationError) {
        lock.withLock {
            if pendingError == nil { pendingError = error }
        }
    }

    private func finish(_ result: Result<LegacyDescriptorProbeResult, Error>) {
        let completion = lock.withLock {
            () -> (CheckedContinuation<LegacyDescriptorProbeResult, Error>?, URLSession?) in
            guard !isFinished else { return (nil, nil) }
            isFinished = true
            let result = (continuation, session)
            continuation = nil
            session = nil
            task = nil
            return result
        }
        completion.1?.finishTasksAndInvalidate()
        switch result {
        case .success(let value):
            completion.0?.resume(returning: value)
        case .failure(let error):
            completion.0?.resume(throwing: error)
        }
    }

    private static func validatedTotalLength(from contentRange: String) -> Int64? {
        let components = contentRange.split(separator: " ", maxSplits: 1)
        guard components.count == 2, components[0].lowercased() == "bytes" else {
            return nil
        }
        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2,
            rangeAndTotal[0] == "0-0",
            let total = Int64(rangeAndTotal[1]),
            total > 0
        else {
            return nil
        }
        return total
    }
}

actor PlaybackFullResourceTransferGateAdapter: GuardedLegacyTransferGating {
    private let gate: PlaybackFullResourceTransferGate
    private let storagePolicy: PlaybackStoragePolicy

    init(
        initialNetwork: NetworkSnapshot,
        storagePolicy: PlaybackStoragePolicy
    ) {
        gate = PlaybackFullResourceTransferGate(
            network: initialNetwork,
            storagePolicy: storagePolicy
        )
        self.storagePolicy = storagePolicy
    }

    func updateNetwork(_ snapshot: NetworkSnapshot) async {
        await gate.updateNetwork(snapshot)
    }

    func evaluate(
        _ request: FullResourceTransferRequest,
        consentGrant: FullTransferConsentGrant?
    ) async -> FullResourceTransferDecision {
        await gate.evaluate(request, consentGrant: consentGrant)
    }

    func acceptConsent(
        _ challenge: FullTransferConsentChallenge
    ) async -> FullTransferConsentGrant? {
        await gate.acceptConsent(challenge)
    }

    func releaseReservation(_ reservationID: StorageReservationID) async {
        await storagePolicy.release(reservationID)
    }
}
