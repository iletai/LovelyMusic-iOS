import AVFoundation
import Foundation
import UniformTypeIdentifiers

// MARK: - Resource-loader adapter contracts

struct ResourceLoadingDataDemand: Equatable, Sendable {
    let requestedOffset: Int64
    let currentOffset: Int64
    let requestedLength: Int
    let requestsAllDataToEndOfResource: Bool
}

struct ResourceContentInformation: Equatable, Sendable {
    let contentType: String?
    let contentLength: Int64
    let isByteRangeAccessSupported: Bool
}

protocol ResourceLoadingRequest: AnyObject, Sendable {
    var dataDemand: ResourceLoadingDataDemand? { get }

    func setContentInformation(_ information: ResourceContentInformation)
    func respond(with data: Data)
    func finish()
    func finish(with error: Error)
}

struct RangeFetchPermit: Equatable, Sendable {
    let range: Range<Int64>
    let byteCeiling: Int64
    let authorizedKillSwitchEpoch: UInt64
    let tokens: ActivePlaybackTokens
}

protocol RangeCandidateReading: Sendable {
    func locateCandidate(for key: ProvisionalResourceKey) async -> Bool

    func readCommittedBytes(
        for generation: ValidatedContentGeneration,
        permit: RangeFetchPermit
    ) async throws -> Data?

    func writeCommittedBytes(
        _ data: Data,
        for generation: ValidatedContentGeneration,
        permit: RangeFetchPermit
    ) async throws
}

enum RangeLoaderError: Error, Equatable, Sendable {
    case generationValidationFailed
    case structuralResponse
    case inconsistentEndOfResource
    case staleKillSwitchEpoch
    case killSwitchEnabled
    case stalePlaybackTokens
    case unsupportedContentType
}

enum RangeLoaderLifecycleEvent: Sendable {
    case requestTaskWillEnter(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    )
    case permitWillResolve(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    )
    case candidateReadWillAuthorize(
        tokens: ActivePlaybackTokens,
        requestID: UUID,
        range: Range<Int64>
    )
    case staleLeaseWillDetach(
        oldTokens: ActivePlaybackTokens,
        requestID: UUID
    )
    case generationConsumerAttached(
        tokens: ActivePlaybackTokens,
        requestID: UUID,
        consumerCount: Int
    )
    case generationConsumerWillDetach(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    )
    case generationRunDidReconcile(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    )
    case upstreamTaskWillStartTransport(
        tokens: ActivePlaybackTokens,
        requestID: UUID,
        range: Range<Int64>?
    )
    case fetchTerminalWillReleaseReservation(
        tokens: ActivePlaybackTokens,
        requestID: UUID,
        range: Range<Int64>
    )
    case validatedTransportChunkWillAccount(
        tokens: ActivePlaybackTokens,
        requestID: UUID,
        range: Range<Int64>,
        cumulativeResponseBodyBytes: Int64
    )
}

typealias RangeLoaderLifecycleHook = @Sendable (
    RangeLoaderLifecycleEvent
) async -> Void

enum RangeFinishPolicy {
    static func mayFinish(
        requestsAllDataToEnd: Bool,
        deliveredOffset: Int64,
        targetEnd: Int64,
        validatedEOF: Int64
    ) -> Bool {
        guard deliveredOffset >= 0,
            targetEnd >= 0,
            validatedEOF >= 0,
            targetEnd <= validatedEOF,
            deliveredOffset <= validatedEOF
        else {
            return false
        }
        if requestsAllDataToEnd {
            return targetEnd == validatedEOF
                && deliveredOffset == validatedEOF
        }
        return deliveredOffset >= targetEnd
    }
}

// MARK: - Demand policy

struct RangeDemandController: Sendable {
    static let maximumUpstreamRangeBytes: Int64 = 64 * 1024

    let bitrate: Int
    let initializationRange: Range<Int64>?
    let indexRange: Range<Int64>?
    let authorizedKillSwitchEpoch: UInt64

    init(
        bitrate: Int,
        initializationRange: Range<Int64>?,
        indexRange: Range<Int64>?,
        authorizedKillSwitchEpoch: UInt64
    ) {
        self.bitrate = bitrate
        self.initializationRange = initializationRange
        self.indexRange = indexRange
        self.authorizedKillSwitchEpoch = authorizedKillSwitchEpoch
    }

    func forwardBufferTargetSeconds(for network: NetworkSnapshot) -> Int {
        if network.isConstrained || network.classification == .constrained {
            return 5
        }
        if network.usesCellular || network.isExpensive
            || network.classification == .cellular
        {
            return 8
        }
        return network.classification == .wifiUnconstrained ? 15 : 5
    }

    func activeTrackByteBudget(
        playedSeconds: TimeInterval,
        network: NetworkSnapshot
    ) -> Int64 {
        guard bitrate > 0, playedSeconds.isFinite, playedSeconds >= 0 else {
            return 0
        }
        let targetSeconds = Double(forwardBufferTargetSeconds(for: network))
        let bytesPerSecond = Double(bitrate) / 8
        let calculatedMediaBytes = ceil(
            bytesPerSecond * (playedSeconds + targetSeconds)
        )
        let mediaBytes = calculatedMediaBytes >= Double(Int64.max)
            ? Int64.max
            : Int64(calculatedMediaBytes)
        let base = metadataRangeUnionByteCount.addingClamped(mediaBytes)
        let tenPercent = base.addingClamped(9) / 10
        return base.addingClamped(tenPercent)
    }

    func nextFetchPermit(
        demand: ResourceLoadingDataDemand,
        playedSeconds: TimeInterval,
        bufferedSeconds _: TimeInterval,
        cumulativeResponseBodyBytes: Int64,
        network: NetworkSnapshot,
        featureSnapshot: PlaybackFeatureSnapshot,
        tokens: ActivePlaybackTokens
    ) -> RangeFetchPermit? {
        guard authorizes(featureSnapshot, tokens: tokens),
            cumulativeResponseBodyBytes >= 0,
            demand.currentOffset >= demand.requestedOffset,
            demand.requestedOffset >= 0,
            demand.requestedLength >= 0
        else {
            return nil
        }

        let attemptBudget = activeTrackByteBudget(
            playedSeconds: playedSeconds,
            network: network
        )
        let remainingBudget = attemptBudget - cumulativeResponseBodyBytes
        guard remainingBudget > 0 else { return nil }

        let demandUpperBound: Int64
        if demand.requestsAllDataToEndOfResource {
            demandUpperBound = demand.currentOffset.addingClamped(
                Self.maximumUpstreamRangeBytes
            )
        } else {
            let requestedLength = Int64(demand.requestedLength)
            demandUpperBound = demand.requestedOffset.addingClamped(requestedLength)
        }
        guard demand.currentOffset < demandUpperBound else { return nil }

        let permittedLength = min(
            Self.maximumUpstreamRangeBytes,
            demandUpperBound - demand.currentOffset,
            remainingBudget
        )
        guard permittedLength > 0 else { return nil }
        return RangeFetchPermit(
            range: demand.currentOffset
                ..< demand.currentOffset.addingClamped(permittedLength),
            byteCeiling: remainingBudget,
            authorizedKillSwitchEpoch: authorizedKillSwitchEpoch,
            tokens: tokens
        )
    }

    private var metadataRangeUnionByteCount: Int64 {
        let ranges = [initializationRange, indexRange].compactMap { $0 }
            .filter { $0.lowerBound >= 0 && $0.lowerBound < $0.upperBound }
            .sorted {
                if $0.lowerBound == $1.lowerBound {
                    return $0.upperBound < $1.upperBound
                }
                return $0.lowerBound < $1.lowerBound
            }
        var union: [Range<Int64>] = []
        for range in ranges {
            guard let last = union.last, range.lowerBound <= last.upperBound else {
                union.append(range)
                continue
            }
            union[union.count - 1] = last.lowerBound..<max(
                last.upperBound,
                range.upperBound
            )
        }
        return union.reduce(0) { result, range in
            result.addingClamped(range.upperBound - range.lowerBound)
        }
    }

    private func authorizes(
        _ snapshot: PlaybackFeatureSnapshot,
        tokens: ActivePlaybackTokens
    ) -> Bool {
        snapshot.rangeStreamingV1
            && !snapshot.killSwitch
            && snapshot.killSwitchEpoch == authorizedKillSwitchEpoch
            && snapshot.hasSupportedSchema
            && (1...100).contains(snapshot.cohortPercent)
            && tokens.currentSourceAttempt.source == .rangeStream
            && tokens.currentSourceAttempt.sessionID == tokens.sessionID
    }
}

// MARK: - Driver and strong asset handle

struct RangeAssetHandle {
    let asset: AVURLAsset
    let loader: RangeResourceLoaderDelegate
    let attempt: SourceAttempt
    let delegateQueue: DispatchQueue
}

private final class WeakRangeResourceLoader: @unchecked Sendable {
    weak var value: RangeResourceLoaderDelegate?

    init(_ value: RangeResourceLoaderDelegate) {
        self.value = value
    }
}

private final class RangeDelegateQueueContext: @unchecked Sendable {
    let queue: DispatchQueue

    private let key = DispatchSpecificKey<UUID>()
    private let value = UUID()

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: key, value: value)
    }

    func sync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: key) == value {
            return operation()
        }
        return queue.sync(execute: operation)
    }
}

final class RangePlaybackDriver: @unchecked Sendable {
    private enum AttemptContextResolution {
        case ready(tokens: ActivePlaybackTokens, context: RangeAttemptContext)
        case staleAttempt
        case descriptorMismatch
    }

    typealias ResourceLoaderDelegateInstaller = @Sendable (
        AVAssetResourceLoader,
        RangeResourceLoaderDelegate,
        DispatchQueue
    ) -> Void
    typealias RequestHook = @Sendable (ActivePlaybackTokens, UUID) async -> Void

    private let lock = NSLock()
    private let transport: any MediaByteTransport
    private let candidateReader: any RangeCandidateReading
    private let authorizedKillSwitchEpoch: UInt64
    private let featureSnapshot: @Sendable () -> PlaybackFeatureSnapshot
    private let networkSnapshot: @Sendable () -> NetworkSnapshot
    private let resourceLoaderDelegateInstaller: ResourceLoaderDelegateInstaller
    private let validatedChunkWillRespond: RequestHook
    private let validatedChunkDidAttemptRespond: RequestHook
    private let requestDidExit: RequestHook
    private let lifecycleHook: RangeLoaderLifecycleHook
    private var activeTokens: ActivePlaybackTokens
    private var attemptContext: RangeAttemptContext?
    private var loaders: [WeakRangeResourceLoader] = []

    init(
        transport: any MediaByteTransport,
        candidateReader: any RangeCandidateReading,
        tokens: ActivePlaybackTokens,
        authorizedKillSwitchEpoch: UInt64,
        featureSnapshot: @escaping @Sendable () -> PlaybackFeatureSnapshot,
        networkSnapshot: @escaping @Sendable () -> NetworkSnapshot,
        resourceLoaderDelegateInstaller: @escaping ResourceLoaderDelegateInstaller = {
            resourceLoader,
            delegate,
            queue in
            resourceLoader.setDelegate(delegate, queue: queue)
        },
        validatedChunkWillRespond: @escaping RequestHook = { _, _ in },
        validatedChunkDidAttemptRespond: @escaping RequestHook = { _, _ in },
        requestDidExit: @escaping RequestHook = { _, _ in },
        lifecycleHook: @escaping RangeLoaderLifecycleHook = { _ in }
    ) {
        self.transport = transport
        self.candidateReader = candidateReader
        activeTokens = tokens
        self.authorizedKillSwitchEpoch = authorizedKillSwitchEpoch
        self.featureSnapshot = featureSnapshot
        self.networkSnapshot = networkSnapshot
        self.resourceLoaderDelegateInstaller = resourceLoaderDelegateInstaller
        self.validatedChunkWillRespond = validatedChunkWillRespond
        self.validatedChunkDidAttemptRespond = validatedChunkDidAttemptRespond
        self.requestDidExit = requestDidExit
        self.lifecycleHook = lifecycleHook
    }

    func makeRangeAsset(
        descriptor: StreamDescriptor,
        attempt: SourceAttempt
    ) throws -> RangeAssetHandle {
        guard !descriptor.provisionalResourceKey.digest.isEmpty,
            let url = URL(
                string: "lovely-range-v1://\(descriptor.provisionalResourceKey.digest)/media"
            )
        else {
            throw RangeLoaderError.stalePlaybackTokens
        }

        let resolution = lock.withLock { () -> AttemptContextResolution in
            let tokens = activeTokens
            guard tokens.currentSourceAttempt == attempt,
                attempt.sessionID == tokens.sessionID,
                attempt.source == .rangeStream
            else {
                return .staleAttempt
            }
            if let attemptContext {
                guard attemptContext.attempt == attempt else {
                    return .staleAttempt
                }
                guard attemptContext.descriptor == descriptor else {
                    return .descriptorMismatch
                }
                return .ready(tokens: tokens, context: attemptContext)
            }
            let context = RangeAttemptContext(
                descriptor: descriptor,
                attempt: attempt,
                tokens: tokens,
                transport: transport,
                candidateReader: candidateReader,
                authorizedKillSwitchEpoch: authorizedKillSwitchEpoch,
                featureSnapshot: featureSnapshot,
                lifecycleHook: lifecycleHook
            )
            attemptContext = context
            return .ready(tokens: tokens, context: context)
        }
        let tokens: ActivePlaybackTokens
        let context: RangeAttemptContext
        switch resolution {
        case .ready(let resolvedTokens, let resolvedContext):
            tokens = resolvedTokens
            context = resolvedContext
        case .staleAttempt:
            throw RangeLoaderError.stalePlaybackTokens
        case .descriptorMismatch:
            throw RangeLoaderError.structuralResponse
        }

        let queue = DispatchQueue(
            label: "com.lovelymusic.range-resource-loader.\(UUID().uuidString)"
        )
        let queueContext = RangeDelegateQueueContext(queue: queue)
        let loader = RangeResourceLoaderDelegate(
            context: context,
            candidateReader: candidateReader,
            featureSnapshot: featureSnapshot,
            networkSnapshot: networkSnapshot,
            delegateQueueContext: queueContext,
            validatedChunkWillRespond: validatedChunkWillRespond,
            validatedChunkDidAttemptRespond: validatedChunkDidAttemptRespond,
            requestDidExit: requestDidExit,
            lifecycleHook: lifecycleHook
        )
        let asset = AVURLAsset(url: url)
        resourceLoaderDelegateInstaller(asset.resourceLoader, loader, queue)
        let retained = lock.withLock { () -> Bool in
            guard activeTokens == tokens, attemptContext === context else {
                return false
            }
            loaders.removeAll { $0.value == nil }
            loaders.append(WeakRangeResourceLoader(loader))
            return true
        }
        guard retained else {
            throw RangeLoaderError.stalePlaybackTokens
        }
        return RangeAssetHandle(
            asset: asset,
            loader: loader,
            attempt: attempt,
            delegateQueue: queue
        )
    }

    func activate(tokens: ActivePlaybackTokens) -> Bool {
        var deferredDetaches: [@Sendable () -> Void] = []
        let accepted = lock.withLock { () -> Bool in
            guard tokens.sessionID == activeTokens.sessionID,
                tokens.currentSourceAttempt == activeTokens.currentSourceAttempt,
                tokens.currentSourceAttempt.source == .rangeStream
            else {
                return false
            }
            loaders.removeAll { $0.value == nil }
            let currentLoaders = loaders.compactMap(\.value)
            if let attemptContext {
                attemptContext.authorization.activate(tokens) {
                    deferredDetaches = currentLoaders.compactMap {
                        $0.revokeStaleLeases(for: tokens)
                    }
                }
            }
            activeTokens = tokens
            return true
        }
        deferredDetaches.forEach { $0() }
        return accepted
    }

    func updatePlaybackProgress(
        tokens: ActivePlaybackTokens,
        playedSeconds: TimeInterval,
        bufferedSeconds: TimeInterval
    ) -> Bool {
        let currentLoaders: [RangeResourceLoaderDelegate]? = lock.withLock {
            guard tokens == activeTokens,
                playedSeconds.isFinite,
                playedSeconds >= 0,
                bufferedSeconds.isFinite,
                bufferedSeconds >= 0
            else {
                return nil
            }
            loaders.removeAll { $0.value == nil }
            return loaders.compactMap(\.value)
        }
        guard let currentLoaders else { return false }
        currentLoaders.forEach {
            $0.updatePlaybackProgress(
                tokens: tokens,
                playedSeconds: playedSeconds,
                bufferedSeconds: bufferedSeconds
            )
        }
        return true
    }
}

// MARK: - Generation and lease identity

private final class RangeGenerationCancellationLatch: @unchecked Sendable {
    private enum State: Equatable {
        case pending
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state: State = .pending

    var isCancelled: Bool {
        lock.withLock { state == .cancelled }
    }

    func cancel() {
        lock.withLock {
            guard state == .pending else { return }
            state = .cancelled
        }
    }

    func claimCompletion() -> Bool {
        lock.withLock {
            guard state == .pending else { return false }
            state = .completed
            return true
        }
    }
}

private enum RangeGenerationRunResult: Sendable {
    case success(ContentGenerationScope)
    case failure(RangeLoaderError)
}

private actor RangeGenerationCoordinator {
    private struct Consumer {
        let id: UUID
        let tokens: ActivePlaybackTokens
        let requestID: UUID
        let registrationOrder: UInt64
        let cancellation: RangeGenerationCancellationLatch
        let continuation: CheckedContinuation<ContentGenerationScope, Error>
        var runID: UUID?
    }

    private struct ActiveRun {
        let id: UUID
        let tokens: ActivePlaybackTokens
        let originRequestID: UUID
        var consumerIDs: Set<UUID>
        let task: Task<Void, Never>
    }

    private let transport: any MediaByteTransport
    private let descriptor: StreamDescriptor
    private let authorizer: @Sendable (ActivePlaybackTokens) -> RangeLoaderError?
    private let lifecycleHook: RangeLoaderLifecycleHook
    private var sourceAttemptID: SourceAttemptID?
    private var cachedScope: ContentGenerationScope?
    private var consumers: [UUID: Consumer] = [:]
    private var cancellationClaims: Set<UUID> = []
    private var activeRun: ActiveRun?
    private var nextRegistrationOrder: UInt64 = 0

    init(
        transport: any MediaByteTransport,
        descriptor: StreamDescriptor,
        authorizer: @escaping @Sendable (
            ActivePlaybackTokens
        ) -> RangeLoaderError?,
        lifecycleHook: @escaping RangeLoaderLifecycleHook
    ) {
        self.transport = transport
        self.descriptor = descriptor
        self.authorizer = authorizer
        self.lifecycleHook = lifecycleHook
    }

    func scope(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    ) async throws -> ContentGenerationScope {
        guard tokens.currentSourceAttempt.source == .rangeStream,
            tokens.currentSourceAttempt.sessionID == tokens.sessionID
        else {
            throw RangeLoaderError.stalePlaybackTokens
        }
        if let sourceAttemptID,
            sourceAttemptID != tokens.currentSourceAttempt.id
        {
            throw RangeLoaderError.stalePlaybackTokens
        }
        sourceAttemptID = tokens.currentSourceAttempt.id
        let consumerID = UUID()
        let cancellation = RangeGenerationCancellationLatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var consumer = Consumer(
                    id: consumerID,
                    tokens: tokens,
                    requestID: requestID,
                    registrationOrder: nextRegistrationOrder,
                    cancellation: cancellation,
                    continuation: continuation,
                    runID: nil
                )
                if var run = activeRun, run.tokens == tokens {
                    consumer.runID = run.id
                    run.consumerIDs.insert(consumerID)
                    activeRun = run
                }
                consumers[consumerID] = consumer
                nextRegistrationOrder &+= 1
                let consumerCount = consumers.count
                Task { [weak self] in
                    await self?.consumerDidRegister(
                        consumerID,
                        consumerCount: consumerCount
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelConsumer(consumerID) }
        }
    }

    private func consumerDidRegister(
        _ consumerID: UUID,
        consumerCount: Int
    ) async {
        guard let consumer = consumers[consumerID] else { return }
        await lifecycleHook(
            .generationConsumerAttached(
                tokens: consumer.tokens,
                requestID: consumer.requestID,
                consumerCount: consumerCount
            )
        )
        guard let current = consumers[consumerID] else { return }
        if current.cancellation.isCancelled {
            await cancelConsumer(consumerID)
            return
        }
        if let denial = authorizer(current.tokens) {
            completeConsumer(consumerID, result: .failure(denial))
            return
        }
        if let cachedScope {
            let result: Result<ContentGenerationScope, Error> = validates(
                cachedScope,
                tokens: current.tokens
            )
                ? .success(cachedScope)
                : .failure(RangeLoaderError.generationValidationFailed)
            completeConsumer(consumerID, result: result)
            return
        }
        if current.runID != nil { return }
        if var run = activeRun, run.tokens == current.tokens {
            var attached = current
            attached.runID = run.id
            consumers[consumerID] = attached
            run.consumerIDs.insert(consumerID)
            activeRun = run
            return
        }
        startNextPendingRun(preferredConsumerID: consumerID)
    }

    private func startNextPendingRun(
        preferredConsumerID: UUID? = nil
    ) {
        guard activeRun == nil, cachedScope == nil else { return }
        let pending = consumers.values
            .filter { $0.runID == nil && !$0.cancellation.isCancelled }
            .sorted { $0.registrationOrder < $1.registrationOrder }
        var eligible: [Consumer] = []
        for consumer in pending {
            if let denial = authorizer(consumer.tokens) {
                completeConsumer(
                    consumer.id,
                    result: .failure(denial),
                    startsNextRun: false
                )
            } else if let current = consumers[consumer.id],
                current.runID == nil,
                !current.cancellation.isCancelled
            {
                eligible.append(current)
            }
        }
        let preferred = preferredConsumerID.flatMap { preferredID in
            eligible.first { $0.id == preferredID }
        }
        guard let origin = preferred ?? eligible.first else { return }
        let cohort = eligible.filter { $0.tokens == origin.tokens }
        let runID = UUID()
        let cohortIDs = Set(cohort.map(\.id))
        for consumerID in cohortIDs {
            guard var consumer = consumers[consumerID] else { continue }
            consumer.runID = runID
            consumers[consumerID] = consumer
        }
        let transport = transport
        let descriptor = descriptor
        let tokens = origin.tokens
        let originRequestID = origin.requestID
        let lifecycleHook = lifecycleHook
        let task = Task<Void, Never> { [weak self] in
            await lifecycleHook(
                .upstreamTaskWillStartTransport(
                    tokens: tokens,
                    requestID: originRequestID,
                    range: nil
                )
            )
            let result: RangeGenerationRunResult
            do {
                try Task.checkCancellation()
                guard let self else { return }
                try await self.preflightRun(runID, tokens: tokens)
                try Task.checkCancellation()
                result = .success(
                    try await transport.validateGeneration(
                        for: descriptor,
                        tokens: tokens
                    )
                )
            } catch let error as RangeLoaderError {
                result = .failure(error)
            } catch {
                result = .failure(mapGenerationValidationError(error))
            }
            await self?.completeRun(runID, result: result)
        }
        activeRun = ActiveRun(
            id: runID,
            tokens: tokens,
            originRequestID: originRequestID,
            consumerIDs: cohortIDs,
            task: task
        )
    }

    private func preflightRun(
        _ runID: UUID,
        tokens: ActivePlaybackTokens
    ) throws {
        guard let run = activeRun,
            run.id == runID,
            run.tokens == tokens,
            run.consumerIDs.contains(where: { consumerID in
                guard let consumer = consumers[consumerID] else {
                    return false
                }
                return consumer.runID == runID
                    && consumer.tokens == tokens
                    && !consumer.cancellation.isCancelled
            })
        else {
            throw CancellationError()
        }
        if let denial = authorizer(tokens) {
            throw denial
        }
    }

    private func completeRun(
        _ runID: UUID,
        result: RangeGenerationRunResult
    ) async {
        guard let run = activeRun, run.id == runID else { return }
        activeRun = nil
        var mayCacheScope: ContentGenerationScope?
        let runAuthorizationError = authorizer(run.tokens)
        for consumerID in run.consumerIDs {
            guard let consumer = consumers[consumerID],
                consumer.runID == runID,
                consumer.tokens == run.tokens
            else {
                continue
            }
            guard !consumer.cancellation.isCancelled else {
                continue
            }
            let consumerResult: Result<ContentGenerationScope, Error>
            if let denial = runAuthorizationError ?? authorizer(consumer.tokens) {
                consumerResult = .failure(denial)
            } else {
                switch result {
                case .success(let scope) where validates(
                    scope,
                    tokens: consumer.tokens
                ):
                    consumerResult = .success(scope)
                case .success:
                    consumerResult = .failure(
                        RangeLoaderError.generationValidationFailed
                    )
                case .failure(let error):
                    consumerResult = .failure(error)
                }
            }
            guard consumer.cancellation.claimCompletion() else { continue }
            if case .success(let scope) = consumerResult {
                mayCacheScope = scope
            }
            consumers.removeValue(forKey: consumerID)
            consumer.continuation.resume(with: consumerResult)
        }
        if let mayCacheScope {
            cachedScope = mayCacheScope
        }
        await lifecycleHook(
            .generationRunDidReconcile(
                tokens: run.tokens,
                requestID: run.originRequestID
            )
        )
        startNextPendingRun()
    }

    private func cancelConsumer(_ consumerID: UUID) async {
        guard let consumer = consumers[consumerID],
            consumer.cancellation.isCancelled,
            cancellationClaims.insert(consumerID).inserted
        else {
            return
        }
        await lifecycleHook(
            .generationConsumerWillDetach(
                tokens: consumer.tokens,
                requestID: consumer.requestID
            )
        )
        cancellationClaims.remove(consumerID)
        guard let removed = consumers.removeValue(forKey: consumerID) else {
            return
        }
        removed.continuation.resume(throwing: CancellationError())
        retireRunConsumerIfNeeded(removed)
        startNextPendingRun()
    }

    private func completeConsumer(
        _ consumerID: UUID,
        result: Result<ContentGenerationScope, Error>,
        startsNextRun: Bool = true
    ) {
        guard let consumer = consumers[consumerID],
            consumer.cancellation.claimCompletion()
        else {
            return
        }
        consumers.removeValue(forKey: consumerID)
        consumer.continuation.resume(with: result)
        retireRunConsumerIfNeeded(consumer)
        if startsNextRun {
            startNextPendingRun()
        }
    }

    private func retireRunConsumerIfNeeded(_ consumer: Consumer) {
        guard let runID = consumer.runID,
            var run = activeRun,
            run.id == runID
        else {
            return
        }
        run.consumerIDs.remove(consumer.id)
        guard run.consumerIDs.isEmpty else {
            activeRun = run
            return
        }
        activeRun = nil
        run.task.cancel()
    }

    private func validates(
        _ scope: ContentGenerationScope,
        tokens: ActivePlaybackTokens
    ) -> Bool {
        switch scope {
        case .persistent(let generation):
            return generation.provisionalKey == descriptor.provisionalResourceKey
                && generation.totalLength > 0
                && !generation.strongValidator.isEmpty
        case .attemptOnly(let sessionID, let sourceAttemptID, let totalLength):
            return sessionID == tokens.sessionID
                && sourceAttemptID == tokens.currentSourceAttempt.id
                && totalLength > 0
        }
    }
}

private func mapGenerationValidationError(_ error: Error) -> RangeLoaderError {
    guard let transportError = error as? MediaTransportError else {
        return .generationValidationFailed
    }
    switch transportError.reason {
    case .killSwitchEnabled:
        return .killSwitchEnabled
    case .staleKillSwitchEpoch:
        return .staleKillSwitchEpoch
    case .stalePlaybackTokens:
        return .stalePlaybackTokens
    case .invalidRequest, .invalidResponse, .rangeIgnored, .invalidContentRange,
        .transformedContentEncoding, .endOfResource, .generationChanged,
        .byteCeilingExceeded, .backpressureExceeded, .unapprovedRedirect,
        .unsupportedStatus, .transportFailure, .cancelled:
        return .generationValidationFailed
    }
}

private struct RangeLeaseKey: Hashable, Sendable {
    let sessionID: PlaybackSessionID
    let sourceAttemptID: SourceAttemptID
    let requestID: UUID
}

private final class RangeLeaseControl: @unchecked Sendable {
    private struct PulseWaiter {
        let version: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    let key: RangeLeaseKey
    let tokens: ActivePlaybackTokens
    let request: any ResourceLoadingRequest

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var staleLease = false
    private var detachClaimed = false
    private var pulseVersion: UInt64 = 0
    private var pulseWaiters: [PulseWaiter] = []

    init(
        key: RangeLeaseKey,
        tokens: ActivePlaybackTokens,
        request: any ResourceLoadingRequest
    ) {
        self.key = key
        self.tokens = tokens
        self.request = request
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let result = lock.withLock { () -> (Task<Void, Never>?, [PulseWaiter]) in
            guard !cancelled else { return (task, []) }
            cancelled = true
            pulseVersion &+= 1
            let waiters = pulseWaiters
            pulseWaiters.removeAll()
            return (task, waiters)
        }
        result.0?.cancel()
        result.1.forEach { $0.continuation.resume() }
    }

    func markStaleLease() {
        lock.withLock { staleLease = true }
    }

    func claimDetach() -> Bool {
        lock.withLock {
            guard !detachClaimed else { return false }
            detachClaimed = true
            return true
        }
    }

    var requiresStaleDetachEvent: Bool {
        lock.withLock { staleLease }
    }

    func pulse() {
        let waiters = lock.withLock { () -> [PulseWaiter] in
            pulseVersion &+= 1
            let waiters = pulseWaiters
            pulseWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.continuation.resume() }
    }

    func currentPulseVersion() -> UInt64 {
        lock.withLock { pulseVersion }
    }

    func waitForPulse(after version: UInt64) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if cancelled || pulseVersion != version {
                    return true
                }
                pulseWaiters.append(
                    PulseWaiter(version: version, continuation: continuation)
                )
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    @discardableResult
    func whileActive(_ operation: () -> Void) -> Bool {
        guard lock.withLock({ !cancelled }) else { return false }
        operation()
        return lock.withLock { !cancelled }
    }
}

private final class RangeLoaderTestState: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let key: RangeLeaseKey
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var suspended: Set<RangeLeaseKey> = []
    private var waiters: [Waiter] = []

    func markSuspended(_ key: RangeLeaseKey) {
        let ready = lock.withLock { () -> [Waiter] in
            suspended.insert(key)
            let ready = waiters.filter { $0.key == key }
            waiters.removeAll { $0.key == key }
            return ready
        }
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    func clear(_ key: RangeLeaseKey) {
        _ = lock.withLock { suspended.remove(key) }
    }

    func waitUntilSuspended(
        _ key: RangeLeaseKey,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        if lock.withLock({ suspended.contains(key) }) { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if suspended.contains(key) { return true }
                waiters.append(
                    Waiter(id: waiterID, key: key, continuation: continuation)
                )
                return false
            }
            if shouldResume {
                continuation.resume(returning: true)
                return
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds))
            ) { [weak self] in
                self?.expire(waiterID)
            }
        }
    }

    private func expire(_ waiterID: UUID) {
        let waiter = lock.withLock { () -> Waiter? in
            guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
                return nil
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: false)
    }
}

// MARK: - Shared fetch/cache core

private enum RangeFetchDisposition {
    case active
    case budgetSuspended
    case retryCachedData
}

private actor RangeResourceLoaderCore {
    private struct SharedFetch {
        let id: UUID
        let originRequestID: UUID
        let range: Range<Int64>
        let permit: RangeFetchPermit
        let scope: ContentGenerationScope
        var consumers: [RangeLeaseKey: RangeLeaseControl]
        var reservationRemaining: Int64
        var task: Task<Void, Never>?
    }

    private struct SharedCountWaiter {
        let id: UUID
        let sessionID: PlaybackSessionID
        let sourceAttemptID: SourceAttemptID
        let range: Range<Int64>
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let descriptor: StreamDescriptor
    private let transport: any MediaByteTransport
    private let candidateReader: any RangeCandidateReading
    private let authorizer: @Sendable (ActivePlaybackTokens) -> RangeLoaderError?
    private let lifecycleHook: RangeLoaderLifecycleHook
    private var generationScope: ContentGenerationScope?
    private var cachedBytes: [Int64: UInt8] = [:]
    private var cumulativeResponseBodyBytes: Int64 = 0
    private var fetches: [UUID: SharedFetch] = [:]
    private var errorsByConsumer: [RangeLeaseKey: RangeLoaderError] = [:]
    private var budgetWaiters: [RangeLeaseKey: RangeLeaseControl] = [:]
    private var sharedCountWaiters: [SharedCountWaiter] = []

    init(
        descriptor: StreamDescriptor,
        transport: any MediaByteTransport,
        candidateReader: any RangeCandidateReading,
        authorizer: @escaping @Sendable (
            ActivePlaybackTokens
        ) -> RangeLoaderError?,
        lifecycleHook: @escaping RangeLoaderLifecycleHook
    ) {
        self.descriptor = descriptor
        self.transport = transport
        self.candidateReader = candidateReader
        self.authorizer = authorizer
        self.lifecycleHook = lifecycleHook
    }

    func noteValidatedGeneration(_ scope: ContentGenerationScope) throws {
        if let generationScope, generationScope != scope {
            throw RangeLoaderError.structuralResponse
        }
        generationScope = scope
        // The production generation probe is exactly bytes=0-0 and accounts
        // one response-body byte before any media permit is issued.
        cumulativeResponseBodyBytes = max(cumulativeResponseBodyBytes, 1)
    }

    func cumulativeBytes() -> Int64 {
        cumulativeResponseBodyBytes
    }

    func registerBudgetWaiter(_ control: RangeLeaseControl) {
        budgetWaiters[control.key] = control
    }

    func attachToOverlappingFetch(
        control: RangeLeaseControl,
        cursor: Int64,
        targetEnd: Int64
    ) {
        guard cursor < targetEnd else { return }
        let demandRange = cursor..<targetEnd
        guard let id = fetches.first(where: { _, fetch in
            fetch.range.overlaps(demandRange)
                && fetch.permit.tokens == control.tokens
        })?.key else {
            return
        }
        guard fetches[id]?.consumers[control.key] == nil else { return }
        fetches[id]?.consumers[control.key] = control
        notifySharedCountWaiters()
    }

    func cachedData(from cursor: Int64, through targetEnd: Int64) -> Data? {
        guard cursor >= 0, cursor < targetEnd, cachedBytes[cursor] != nil else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(min(targetEnd - cursor, 64 * 1024)))
        var offset = cursor
        while offset < targetEnd, let byte = cachedBytes[offset] {
            bytes.append(byte)
            offset += 1
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    func storeCandidate(
        _ data: Data,
        permit: RangeFetchPermit,
        scope: ContentGenerationScope
    ) throws {
        if let denial = authorizer(permit.tokens) { throw denial }
        guard scope == generationScope,
            data.count == Int(permit.range.upperBound - permit.range.lowerBound)
        else {
            throw RangeLoaderError.structuralResponse
        }
        store(data, at: permit.range)
    }

    func consumeError(for key: RangeLeaseKey) -> RangeLoaderError? {
        errorsByConsumer.removeValue(forKey: key)
    }

    func hasActiveFetch(for key: RangeLeaseKey) -> Bool {
        fetches.values.contains { $0.consumers[key] != nil }
    }

    func ensureFetch(
        permit: RangeFetchPermit,
        attemptBudget: Int64,
        scope: ContentGenerationScope,
        control: RangeLeaseControl
    ) throws -> RangeFetchDisposition {
        if let denial = authorizer(permit.tokens) { throw denial }
        guard permit.range.lowerBound >= 0,
            permit.range.lowerBound < permit.range.upperBound,
            permit.range.upperBound - permit.range.lowerBound <= permit.byteCeiling,
            attemptBudget >= 0,
            scope == generationScope
        else {
            throw RangeLoaderError.structuralResponse
        }
        budgetWaiters.removeValue(forKey: control.key)

        if let id = fetches.first(where: { _, fetch in
            fetch.range.overlaps(permit.range)
                && fetch.permit.tokens == permit.tokens
        })?.key {
            fetches[id]?.consumers[control.key] = control
            notifySharedCountWaiters()
            return .active
        }
        if hasActiveFetch(for: control.key) { return .active }

        if cachedBytes[permit.range.lowerBound] != nil {
            return .retryCachedData
        }
        var missingUpperBound = permit.range.upperBound
        var offset = permit.range.lowerBound + 1
        while offset < permit.range.upperBound {
            if cachedBytes[offset] != nil {
                missingUpperBound = offset
                break
            }
            offset += 1
        }

        let reservedBytes = fetches.values.reduce(Int64(0)) { total, fetch in
            total.addingClamped(fetch.reservationRemaining)
        }
        let effectiveUsed = cumulativeResponseBodyBytes.addingClamped(
            reservedBytes
        )
        let available = attemptBudget - effectiveUsed
        guard available > 0 else {
            budgetWaiters[control.key] = control
            return .budgetSuspended
        }
        let requestedLength = missingUpperBound - permit.range.lowerBound
        let actualLength = min(requestedLength, available)
        guard actualLength > 0 else {
            budgetWaiters[control.key] = control
            return .budgetSuspended
        }
        let actualPermit = RangeFetchPermit(
            range: permit.range.lowerBound..<(permit.range.lowerBound + actualLength),
            byteCeiling: available,
            authorizedKillSwitchEpoch: permit.authorizedKillSwitchEpoch,
            tokens: permit.tokens
        )

        let fetchID = UUID()
        fetches[fetchID] = SharedFetch(
            id: fetchID,
            originRequestID: control.key.requestID,
            range: actualPermit.range,
            permit: actualPermit,
            scope: scope,
            consumers: [control.key: control],
            reservationRemaining: actualLength,
            task: nil
        )
        let lifecycleHook = lifecycleHook
        let originRequestID = control.key.requestID
        let range = actualPermit.range
        let tokens = actualPermit.tokens
        let task = Task<Void, Never> { [weak self] in
            await lifecycleHook(
                .upstreamTaskWillStartTransport(
                    tokens: tokens,
                    requestID: originRequestID,
                    range: range
                )
            )
            guard let self else { return }
            await self.runFetch(fetchID)
        }
        fetches[fetchID]?.task = task
        notifySharedCountWaiters()
        return .active
    }

    func detach(_ control: RangeLeaseControl) {
        errorsByConsumer.removeValue(forKey: control.key)
        budgetWaiters.removeValue(forKey: control.key)
        for id in Array(fetches.keys) {
            guard fetches[id]?.consumers.removeValue(forKey: control.key) != nil else {
                continue
            }
            if fetches[id]?.consumers.isEmpty == true {
                fetches[id]?.task?.cancel()
            }
        }
        notifySharedCountWaiters()
        control.pulse()
    }

    func waitUntilSharedConsumerCount(
        sessionID: PlaybackSessionID,
        sourceAttemptID: SourceAttemptID,
        range: Range<Int64>,
        count: Int,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        if sharedConsumerCount(
            sessionID: sessionID,
            sourceAttemptID: sourceAttemptID,
            range: range
        ) == count {
            return true
        }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            sharedCountWaiters.append(
                SharedCountWaiter(
                    id: waiterID,
                    sessionID: sessionID,
                    sourceAttemptID: sourceAttemptID,
                    range: range,
                    count: count,
                    continuation: continuation
                )
            )
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds))
            ) { [weak self] in
                Task { await self?.expireSharedCountWaiter(waiterID) }
            }
        }
    }

    private func runFetch(_ fetchID: UUID) async {
        guard let fetch = fetches[fetchID] else { return }
        let terminalError: RangeLoaderError?
        do {
            try Task.checkCancellation()
            guard fetch.consumers.values.contains(where: {
                !$0.isCancelled
            }) else {
                throw CancellationError()
            }
            if let denial = authorizer(fetch.permit.tokens) {
                throw denial
            }
            try Task.checkCancellation()
            let request = MediaByteRequest(
                descriptor: descriptor,
                range: fetch.range,
                ifRangeValidator: fetch.scope.persistentGeneration?.strongValidator,
                purpose: .media,
                byteCeiling: fetch.permit.byteCeiling,
                tokens: fetch.permit.tokens
            )
            for try await chunk in transport.bytes(for: request) {
                await lifecycleHook(
                    .validatedTransportChunkWillAccount(
                        tokens: fetch.permit.tokens,
                        requestID: fetch.originRequestID,
                        range: chunk.absoluteRange,
                        cumulativeResponseBodyBytes:
                            chunk.cumulativeResponseBodyBytes
                    )
                )
                try await receive(chunk, fetchID: fetchID)
            }
            terminalError = nil
        } catch is CancellationError {
            terminalError = nil
        } catch let error as RangeLoaderError {
            terminalError = error
        } catch let error as MediaTransportError {
            if error.cumulativeResponseBodyBytes >= 0 {
                cumulativeResponseBodyBytes = max(
                    cumulativeResponseBodyBytes,
                    error.cumulativeResponseBodyBytes
                )
                terminalError = mapTransportError(error)
            } else {
                terminalError = .structuralResponse
            }
        } catch {
            terminalError = .structuralResponse
        }
        await lifecycleHook(
            .fetchTerminalWillReleaseReservation(
                tokens: fetch.permit.tokens,
                requestID: fetch.originRequestID,
                range: fetch.range
            )
        )
        finishFetch(fetchID, error: terminalError)
    }

    private func receive(
        _ chunk: ValidatedMediaChunk,
        fetchID: UUID
    ) async throws {
        guard let fetch = fetches[fetchID] else { throw CancellationError() }
        guard chunk.generationScope == fetch.scope,
            !chunk.absoluteRange.isEmpty,
            chunk.absoluteRange.lowerBound >= fetch.range.lowerBound,
            chunk.absoluteRange.upperBound <= fetch.range.upperBound,
            chunk.absoluteRange.upperBound - chunk.absoluteRange.lowerBound
                == Int64(chunk.payload.count),
            chunk.cumulativeResponseBodyBytes >= 0,
            Int64(chunk.payload.count) <= fetch.reservationRemaining
        else {
            throw RangeLoaderError.structuralResponse
        }

        cumulativeResponseBodyBytes = max(
            cumulativeResponseBodyBytes,
            chunk.cumulativeResponseBodyBytes
        )
        fetches[fetchID]?.reservationRemaining -= Int64(chunk.payload.count)
        pulseBudgetWaiters()
        try Task.checkCancellation()
        if let denial = authorizer(fetch.permit.tokens) { throw denial }
        store(chunk.payload, at: chunk.absoluteRange)
        if case .persistent(let generation) = fetch.scope {
            let candidatePermit = RangeFetchPermit(
                range: chunk.absoluteRange,
                byteCeiling: fetch.permit.byteCeiling,
                authorizedKillSwitchEpoch: fetch.permit.authorizedKillSwitchEpoch,
                tokens: fetch.permit.tokens
            )
            try await candidateReader.writeCommittedBytes(
                chunk.payload,
                for: generation,
                permit: candidatePermit
            )
        }
        fetches[fetchID]?.consumers.values.forEach { $0.pulse() }
    }

    private func finishFetch(_ fetchID: UUID, error: RangeLoaderError?) {
        guard let fetch = fetches.removeValue(forKey: fetchID) else { return }
        if let error {
            for key in fetch.consumers.keys {
                errorsByConsumer[key] = error
            }
        }
        fetch.consumers.values.forEach { $0.pulse() }
        pulseBudgetWaiters()
        notifySharedCountWaiters()
    }

    private func pulseBudgetWaiters() {
        let waiters = Array(budgetWaiters.values)
        budgetWaiters.removeAll()
        waiters.forEach { $0.pulse() }
    }

    private func store(_ data: Data, at range: Range<Int64>) {
        guard range.upperBound - range.lowerBound == Int64(data.count) else { return }
        for (index, byte) in data.enumerated() {
            cachedBytes[range.lowerBound + Int64(index)] = byte
        }
    }

    private func sharedConsumerCount(
        sessionID: PlaybackSessionID,
        sourceAttemptID: SourceAttemptID,
        range: Range<Int64>
    ) -> Int {
        fetches.values.first(where: { fetch in
            fetch.range == range
                && fetch.permit.tokens.sessionID == sessionID
                && fetch.permit.tokens.currentSourceAttempt.id == sourceAttemptID
        })?.consumers.count ?? 0
    }

    private func notifySharedCountWaiters() {
        let ready = sharedCountWaiters.filter { waiter in
            sharedConsumerCount(
                sessionID: waiter.sessionID,
                sourceAttemptID: waiter.sourceAttemptID,
                range: waiter.range
            ) == waiter.count
        }
        let readyIDs = Set(ready.map(\.id))
        sharedCountWaiters.removeAll { readyIDs.contains($0.id) }
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    private func expireSharedCountWaiter(_ waiterID: UUID) {
        guard let index = sharedCountWaiters.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }
        let waiter = sharedCountWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

// MARK: - Resource-loader delegate

private final class RangeAuthorizationBox: @unchecked Sendable {
    private let lock = NSLock()
    private let authorizedEpoch: UInt64
    private let featureSnapshot: @Sendable () -> PlaybackFeatureSnapshot
    private var tokens: ActivePlaybackTokens

    init(
        tokens: ActivePlaybackTokens,
        authorizedEpoch: UInt64,
        featureSnapshot: @escaping @Sendable () -> PlaybackFeatureSnapshot
    ) {
        self.tokens = tokens
        self.authorizedEpoch = authorizedEpoch
        self.featureSnapshot = featureSnapshot
    }

    func snapshotTokens() -> ActivePlaybackTokens {
        lock.withLock { tokens }
    }

    func activate(
        _ tokens: ActivePlaybackTokens,
        revokingPreviousLeases: () -> Void
    ) {
        lock.lock()
        revokingPreviousLeases()
        self.tokens = tokens
        lock.unlock()
    }

    func error(for candidate: ActivePlaybackTokens) -> RangeLoaderError? {
        let isCurrent = lock.withLock { tokens == candidate }
        return rangeAuthorizationError(
            snapshot: featureSnapshot(),
            authorizedEpoch: authorizedEpoch,
            tokensAreCurrent: isCurrent
        )
    }
}

private final class RangeAttemptContext: @unchecked Sendable {
    let descriptor: StreamDescriptor
    let attempt: SourceAttempt
    let authorization: RangeAuthorizationBox
    let generationCoordinator: RangeGenerationCoordinator
    let core: RangeResourceLoaderCore
    let authorizedKillSwitchEpoch: UInt64

    init(
        descriptor: StreamDescriptor,
        attempt: SourceAttempt,
        tokens: ActivePlaybackTokens,
        transport: any MediaByteTransport,
        candidateReader: any RangeCandidateReading,
        authorizedKillSwitchEpoch: UInt64,
        featureSnapshot: @escaping @Sendable () -> PlaybackFeatureSnapshot,
        lifecycleHook: @escaping RangeLoaderLifecycleHook
    ) {
        self.descriptor = descriptor
        self.attempt = attempt
        self.authorizedKillSwitchEpoch = authorizedKillSwitchEpoch
        let authorization = RangeAuthorizationBox(
            tokens: tokens,
            authorizedEpoch: authorizedKillSwitchEpoch,
            featureSnapshot: featureSnapshot
        )
        self.authorization = authorization
        let authorizer: @Sendable (
            ActivePlaybackTokens
        ) -> RangeLoaderError? = { [authorization] tokens in
            authorization.error(for: tokens)
        }
        generationCoordinator = RangeGenerationCoordinator(
            transport: transport,
            descriptor: descriptor,
            authorizer: authorizer,
            lifecycleHook: lifecycleHook
        )
        core = RangeResourceLoaderCore(
            descriptor: descriptor,
            transport: transport,
            candidateReader: candidateReader,
            authorizer: authorizer,
            lifecycleHook: lifecycleHook
        )
    }
}

final class RangeResourceLoaderDelegate: NSObject, @unchecked Sendable {
    private struct PlaybackProgress {
        var playedSeconds: TimeInterval = 0
        var bufferedSeconds: TimeInterval = 0
    }

    private let descriptor: StreamDescriptor
    private let candidateReader: any RangeCandidateReading
    private let featureSnapshot: @Sendable () -> PlaybackFeatureSnapshot
    private let networkSnapshot: @Sendable () -> NetworkSnapshot
    private let generationCoordinator: RangeGenerationCoordinator
    private let delegateQueueContext: RangeDelegateQueueContext
    private let authorization: RangeAuthorizationBox
    private let core: RangeResourceLoaderCore
    private let demandController: RangeDemandController
    private let validatedChunkWillRespond: RangePlaybackDriver.RequestHook
    private let validatedChunkDidAttemptRespond: RangePlaybackDriver.RequestHook
    private let requestDidExit: RangePlaybackDriver.RequestHook
    private let lifecycleHook: RangeLoaderLifecycleHook
    private let testState = RangeLoaderTestState()
    private let lock = NSLock()
    private var leases: [RangeLeaseKey: RangeLeaseControl] = [:]
    private var progress = PlaybackProgress()
    private var avRequestKeys: [ObjectIdentifier: RangeLeaseKey] = [:]

    fileprivate init(
        context: RangeAttemptContext,
        candidateReader: any RangeCandidateReading,
        featureSnapshot: @escaping @Sendable () -> PlaybackFeatureSnapshot,
        networkSnapshot: @escaping @Sendable () -> NetworkSnapshot,
        delegateQueueContext: RangeDelegateQueueContext,
        validatedChunkWillRespond: @escaping RangePlaybackDriver.RequestHook,
        validatedChunkDidAttemptRespond: @escaping RangePlaybackDriver.RequestHook,
        requestDidExit: @escaping RangePlaybackDriver.RequestHook,
        lifecycleHook: @escaping RangeLoaderLifecycleHook
    ) {
        descriptor = context.descriptor
        self.candidateReader = candidateReader
        self.featureSnapshot = featureSnapshot
        self.networkSnapshot = networkSnapshot
        generationCoordinator = context.generationCoordinator
        self.delegateQueueContext = delegateQueueContext
        authorization = context.authorization
        core = context.core
        demandController = RangeDemandController(
            bitrate: context.descriptor.bitrate,
            initializationRange: context.descriptor.initializationRange,
            indexRange: context.descriptor.indexRange,
            authorizedKillSwitchEpoch: context.authorizedKillSwitchEpoch
        )
        self.validatedChunkWillRespond = validatedChunkWillRespond
        self.validatedChunkDidAttemptRespond = validatedChunkDidAttemptRespond
        self.requestDidExit = requestDidExit
        self.lifecycleHook = lifecycleHook
        super.init()
    }

    var activeRequestCount: Int {
        lock.withLock { leases.count }
    }

    func startLoading(
        _ request: any ResourceLoadingRequest,
        requestID: UUID
    ) {
        _ = startLoading(
            request,
            requestID: requestID,
            tokens: authorization.snapshotTokens()
        )
    }

    @discardableResult
    private func startLoading(
        _ request: any ResourceLoadingRequest,
        requestID: UUID,
        tokens: ActivePlaybackTokens
    ) -> Bool {
        let key = RangeLeaseKey(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        let control = RangeLeaseControl(
            key: key,
            tokens: tokens,
            request: request
        )
        let inserted = lock.withLock { () -> Bool in
            guard leases[key] == nil else { return false }
            leases[key] = control
            return true
        }
        guard inserted else {
            _ = mutateRequest(control) {
                request.finish(with: RangeLoaderError.structuralResponse)
            }
            return false
        }
        let lifecycleHook = lifecycleHook
        let task = Task<Void, Never> { [weak self] in
            await lifecycleHook(
                .requestTaskWillEnter(
                    tokens: control.tokens,
                    requestID: control.key.requestID
                )
            )
            guard let self else { return }
            await self.run(control)
        }
        control.install(task: task)
        return true
    }

    func didCancel(
        sessionID: PlaybackSessionID,
        sourceAttemptID: SourceAttemptID,
        requestID: UUID
    ) {
        let key = RangeLeaseKey(
            sessionID: sessionID,
            sourceAttemptID: sourceAttemptID,
            requestID: requestID
        )
        guard let control = lock.withLock({ leases.removeValue(forKey: key) })
        else {
            return
        }
        lock.withLock {
            avRequestKeys = avRequestKeys.filter { $0.value != key }
        }
        testState.clear(key)
        control.cancel()
        Task { [self] in await detachOnce(control) }
    }

    func hasActiveLease(
        sessionID: PlaybackSessionID,
        sourceAttemptID: SourceAttemptID,
        requestID: UUID
    ) -> Bool {
        let key = RangeLeaseKey(
            sessionID: sessionID,
            sourceAttemptID: sourceAttemptID,
            requestID: requestID
        )
        return lock.withLock { leases[key] != nil }
    }

    func hasActiveLease(
        tokens: ActivePlaybackTokens,
        requestID: UUID
    ) -> Bool {
        let key = RangeLeaseKey(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        return lock.withLock { leases[key]?.tokens == tokens }
    }

    func waitUntilDemandSuspended(
        sessionID: PlaybackSessionID,
        sourceAttemptID: SourceAttemptID,
        requestID: UUID,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await testState.waitUntilSuspended(
            RangeLeaseKey(
                sessionID: sessionID,
                sourceAttemptID: sourceAttemptID,
                requestID: requestID
            ),
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func waitUntilSharedConsumerCount(
        sessionID: PlaybackSessionID,
        sourceAttemptID: SourceAttemptID,
        upstreamRange: Range<Int64>,
        count: Int,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await core.waitUntilSharedConsumerCount(
            sessionID: sessionID,
            sourceAttemptID: sourceAttemptID,
            range: upstreamRange,
            count: count,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    fileprivate func revokeStaleLeases(
        for tokens: ActivePlaybackTokens
    ) -> (@Sendable () -> Void)? {
        let stale = lock.withLock { () -> [RangeLeaseControl] in
            let stale = leases.values.filter { $0.tokens != tokens }
            let staleKeys = Set(stale.map(\.key))
            leases = leases.filter { !staleKeys.contains($0.key) }
            avRequestKeys = avRequestKeys.filter {
                !staleKeys.contains($0.value)
            }
            return stale
        }
        guard !stale.isEmpty else { return nil }
        for control in stale {
            control.markStaleLease()
            testState.clear(control.key)
            control.cancel()
        }
        return { [weak self] in
            guard let self else { return }
            for control in stale {
                Task { [self] in await self.detachOnce(control) }
            }
        }
    }

    func updatePlaybackProgress(
        tokens: ActivePlaybackTokens,
        playedSeconds: TimeInterval,
        bufferedSeconds: TimeInterval
    ) {
        guard authorization.error(for: tokens) == nil else { return }
        let controls = lock.withLock { () -> [RangeLeaseControl] in
            progress.playedSeconds = playedSeconds
            progress.bufferedSeconds = bufferedSeconds
            return Array(leases.values)
        }
        controls.forEach { $0.pulse() }
    }

    private func run(_ control: RangeLeaseControl) async {
        await perform(control)
        await detachOnce(control)
        testState.clear(control.key)
        lock.withLock {
            if leases[control.key] === control {
                leases.removeValue(forKey: control.key)
            }
            avRequestKeys = avRequestKeys.filter { $0.value != control.key }
        }
        await requestDidExit(control.tokens, control.key.requestID)
    }

    private func detachOnce(_ control: RangeLeaseControl) async {
        guard control.claimDetach() else { return }
        if control.requiresStaleDetachEvent {
            await lifecycleHook(
                .staleLeaseWillDetach(
                    oldTokens: control.tokens,
                    requestID: control.key.requestID
                )
            )
        }
        await core.detach(control)
    }

    private func perform(_ control: RangeLeaseControl) async {
        do {
            try throwIfUnavailable(control)
            let candidateLocated = await candidateReader.locateCandidate(
                for: descriptor.provisionalResourceKey
            )
            try throwIfUnavailable(control)
            let scope = try await generationCoordinator.scope(
                tokens: control.tokens,
                requestID: control.key.requestID
            )
            try throwIfUnavailable(control)
            try await core.noteValidatedGeneration(scope)
            try throwIfUnavailable(control)

            let totalLength = scope.totalLength
            guard totalLength >= 0 else { throw RangeLoaderError.structuralResponse }
            guard let contentType = (
                UTType(mimeType: descriptor.mimeType)
                    ?? UTType(filenameExtension: "m4a")
            )?.identifier, !contentType.isEmpty else {
                throw RangeLoaderError.unsupportedContentType
            }
            let information = ResourceContentInformation(
                contentType: contentType,
                contentLength: totalLength,
                isByteRangeAccessSupported: true
            )
            guard mutateRequest(control, {
                control.request.setContentInformation(information)
            }) else {
                throw CancellationError()
            }
            guard let demand = control.request.dataDemand else {
                try throwIfUnavailable(control)
                guard mutateRequest(control, { control.request.finish() }) else {
                    throw CancellationError()
                }
                return
            }

            let finiteEnd = demand.requestedOffset.addingClamped(
                Int64(demand.requestedLength)
            )
            let targetEnd = demand.requestsAllDataToEndOfResource
                ? totalLength
                : min(totalLength, finiteEnd)
            var cursor = demand.currentOffset
            guard cursor >= demand.requestedOffset, cursor >= 0 else {
                throw RangeLoaderError.structuralResponse
            }
            if cursor >= targetEnd {
                try throwIfUnavailable(control)
                try enforceFinishPolicy(
                    demand: demand,
                    deliveredOffset: cursor,
                    targetEnd: targetEnd,
                    validatedEOF: totalLength
                )
                guard mutateRequest(control, { control.request.finish() }) else {
                    throw CancellationError()
                }
                return
            }

            var candidateRangesAttempted: Set<Range<Int64>> = []
            while cursor < targetEnd {
                try throwIfUnavailable(control)
                await core.attachToOverlappingFetch(
                    control: control,
                    cursor: cursor,
                    targetEnd: targetEnd
                )

                if let error = await core.consumeError(for: control.key) {
                    throw error
                }
                if let cached = await core.cachedData(
                    from: cursor,
                    through: targetEnd
                ) {
                    let delivered = try await deliver(
                        cached,
                        control: control
                    )
                    guard delivered else { return }
                    cursor += Int64(cached.count)
                    continue
                }

                let activeFetchVersion = control.currentPulseVersion()
                if await core.hasActiveFetch(for: control.key) {
                    await control.waitForPulse(after: activeFetchVersion)
                    continue
                }

                let demandVersion = control.currentPulseVersion()
                let progress = lock.withLock { self.progress }
                let cumulativeBytes = await core.cumulativeBytes()
                let currentDemand = ResourceLoadingDataDemand(
                    requestedOffset: demand.requestedOffset,
                    currentOffset: cursor,
                    requestedLength: demand.requestedLength,
                    requestsAllDataToEndOfResource:
                        demand.requestsAllDataToEndOfResource
                )
                await lifecycleHook(
                    .permitWillResolve(
                        tokens: control.tokens,
                        requestID: control.key.requestID
                    )
                )
                try throwIfUnavailable(control)
                let network = networkSnapshot()
                let feature = currentFeatureSnapshot()
                let attemptBudget = demandController.activeTrackByteBudget(
                    playedSeconds: progress.playedSeconds,
                    network: network
                )
                guard var permit = demandController.nextFetchPermit(
                    demand: currentDemand,
                    playedSeconds: progress.playedSeconds,
                    bufferedSeconds: progress.bufferedSeconds,
                    cumulativeResponseBodyBytes: cumulativeBytes,
                    network: network,
                    featureSnapshot: feature,
                    tokens: control.tokens
                ) else {
                    try throwIfUnavailable(control)
                    await core.registerBudgetWaiter(control)
                    testState.markSuspended(control.key)
                    await control.waitForPulse(after: demandVersion)
                    testState.clear(control.key)
                    continue
                }
                let clampedUpper = min(permit.range.upperBound, targetEnd)
                guard permit.range.lowerBound < clampedUpper else {
                    throw RangeLoaderError.structuralResponse
                }
                permit = RangeFetchPermit(
                    range: permit.range.lowerBound..<clampedUpper,
                    byteCeiling: permit.byteCeiling,
                    authorizedKillSwitchEpoch: permit.authorizedKillSwitchEpoch,
                    tokens: permit.tokens
                )

                if candidateLocated,
                    case .persistent(let generation) = scope,
                    candidateRangesAttempted.insert(permit.range).inserted
                {
                    await lifecycleHook(
                        .candidateReadWillAuthorize(
                            tokens: control.tokens,
                            requestID: control.key.requestID,
                            range: permit.range
                        )
                    )
                    try throwIfUnavailable(control)
                    if let candidate = try await candidateReader.readCommittedBytes(
                        for: generation,
                        permit: permit
                    )
                    {
                        try throwIfUnavailable(control)
                        try await core.storeCandidate(
                            candidate,
                            permit: permit,
                            scope: scope
                        )
                        continue
                    }
                }

                try throwIfUnavailable(control)
                let version = control.currentPulseVersion()
                let disposition = try await core.ensureFetch(
                    permit: permit,
                    attemptBudget: attemptBudget,
                    scope: scope,
                    control: control
                )
                switch disposition {
                case .active:
                    await control.waitForPulse(after: version)
                case .budgetSuspended:
                    testState.markSuspended(control.key)
                    await control.waitForPulse(after: version)
                    testState.clear(control.key)
                case .retryCachedData:
                    continue
                }
            }

            try throwIfUnavailable(control)
            try enforceFinishPolicy(
                demand: demand,
                deliveredOffset: cursor,
                targetEnd: targetEnd,
                validatedEOF: totalLength
            )
            guard mutateRequest(control, { control.request.finish() }) else {
                throw CancellationError()
            }
        } catch is CancellationError {
            return
        } catch let error as RangeLoaderError {
            _ = mutateRequest(control) { control.request.finish(with: error) }
        } catch {
            _ = mutateRequest(control) {
                control.request.finish(with: RangeLoaderError.structuralResponse)
            }
        }
    }

    private func deliver(
        _ data: Data,
        control: RangeLeaseControl
    ) async throws -> Bool {
        await validatedChunkWillRespond(control.tokens, control.key.requestID)
        if control.isCancelled {
            await validatedChunkDidAttemptRespond(
                control.tokens,
                control.key.requestID
            )
            return false
        }
        if let denial = authorization.error(for: control.tokens) {
            await validatedChunkDidAttemptRespond(
                control.tokens,
                control.key.requestID
            )
            throw denial
        }
        let responded = mutateRequest(control) {
            control.request.respond(with: data)
        }
        await validatedChunkDidAttemptRespond(control.tokens, control.key.requestID)
        return responded
    }

    private func throwIfUnavailable(_ control: RangeLeaseControl) throws {
        if control.isCancelled { throw CancellationError() }
        if let denial = authorization.error(for: control.tokens) { throw denial }
    }

    private func enforceFinishPolicy(
        demand: ResourceLoadingDataDemand,
        deliveredOffset: Int64,
        targetEnd: Int64,
        validatedEOF: Int64
    ) throws {
        let mayFinish = RangeFinishPolicy.mayFinish(
            requestsAllDataToEnd: demand.requestsAllDataToEndOfResource,
            deliveredOffset: deliveredOffset,
            targetEnd: targetEnd,
            validatedEOF: validatedEOF
        )
        #if DEBUG
        if demand.requestsAllDataToEndOfResource {
            assert(mayFinish, "Invalid all-data range finish")
        }
        #endif
        guard mayFinish else { throw RangeLoaderError.structuralResponse }
    }

    private func mutateRequest(
        _ control: RangeLeaseControl,
        _ mutation: () -> Void
    ) -> Bool {
        if control.request is AVRangeResourceLoadingRequestAdapter {
            return delegateQueueContext.sync {
                control.whileActive(mutation)
            }
        }
        return control.whileActive(mutation)
    }

    private func currentFeatureSnapshot() -> PlaybackFeatureSnapshot {
        featureSnapshot()
    }
}

// MARK: - AVFoundation bridge

private final class AVRangeResourceLoadingRequestAdapter: ResourceLoadingRequest,
    @unchecked Sendable
{
    let dataDemand: ResourceLoadingDataDemand?

    private let loadingRequest: AVAssetResourceLoadingRequest
    private let queueContext: RangeDelegateQueueContext

    init(
        loadingRequest: AVAssetResourceLoadingRequest,
        queueContext: RangeDelegateQueueContext
    ) {
        self.loadingRequest = loadingRequest
        self.queueContext = queueContext
        dataDemand = queueContext.sync {
            guard let dataRequest = loadingRequest.dataRequest else { return nil }
            return ResourceLoadingDataDemand(
                requestedOffset: dataRequest.requestedOffset,
                currentOffset: dataRequest.currentOffset,
                requestedLength: dataRequest.requestedLength,
                requestsAllDataToEndOfResource:
                    dataRequest.requestsAllDataToEndOfResource
            )
        }
    }

    func setContentInformation(_ information: ResourceContentInformation) {
        queueContext.sync {
            guard let request = loadingRequest.contentInformationRequest else {
                return
            }
            request.contentType = information.contentType
            request.contentLength = information.contentLength
            request.isByteRangeAccessSupported = information.isByteRangeAccessSupported
        }
    }

    func respond(with data: Data) {
        queueContext.sync {
            loadingRequest.dataRequest?.respond(with: data)
        }
    }

    func finish() {
        queueContext.sync {
            loadingRequest.finishLoading()
        }
    }

    func finish(with error: Error) {
        queueContext.sync {
            loadingRequest.finishLoading(with: error)
        }
    }
}

extension RangeResourceLoaderDelegate: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest:
            AVAssetResourceLoadingRequest
    ) -> Bool {
        let tokens = authorization.snapshotTokens()
        let requestID = UUID()
        let key = RangeLeaseKey(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            requestID: requestID
        )
        let identity = ObjectIdentifier(loadingRequest)
        lock.withLock { avRequestKeys[identity] = key }
        let adapter = AVRangeResourceLoadingRequestAdapter(
            loadingRequest: loadingRequest,
            queueContext: delegateQueueContext
        )
        let accepted = startLoading(
            adapter,
            requestID: requestID,
            tokens: tokens
        )
        if !accepted {
            _ = lock.withLock { avRequestKeys.removeValue(forKey: identity) }
        }
        return accepted
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identity = ObjectIdentifier(loadingRequest)
        guard let key = lock.withLock({ avRequestKeys.removeValue(forKey: identity) })
        else {
            return
        }
        didCancel(
            sessionID: key.sessionID,
            sourceAttemptID: key.sourceAttemptID,
            requestID: key.requestID
        )
    }
}

// MARK: - Fail-closed mapping and arithmetic

private func rangeAuthorizationError(
    snapshot: PlaybackFeatureSnapshot,
    authorizedEpoch: UInt64,
    tokensAreCurrent: Bool
) -> RangeLoaderError? {
    guard tokensAreCurrent else { return .stalePlaybackTokens }
    if snapshot.killSwitch { return .killSwitchEnabled }
    guard snapshot.killSwitchEpoch == authorizedEpoch else {
        return .staleKillSwitchEpoch
    }
    guard snapshot.rangeStreamingV1,
        snapshot.hasSupportedSchema,
        (1...100).contains(snapshot.cohortPercent)
    else {
        return .structuralResponse
    }
    return nil
}

private func mapTransportError(_ error: MediaTransportError) -> RangeLoaderError {
    switch error.reason {
    case .staleKillSwitchEpoch:
        return .staleKillSwitchEpoch
    case .killSwitchEnabled:
        return .killSwitchEnabled
    case .stalePlaybackTokens:
        return .stalePlaybackTokens
    case .endOfResource:
        return .inconsistentEndOfResource
    case .generationChanged:
        return .generationValidationFailed
    case .invalidRequest, .invalidResponse, .rangeIgnored, .invalidContentRange,
        .transformedContentEncoding, .byteCeilingExceeded, .backpressureExceeded,
        .unapprovedRedirect, .unsupportedStatus, .transportFailure, .cancelled:
        return .structuralResponse
    }
}

private extension ContentGenerationScope {
    var totalLength: Int64 {
        switch self {
        case .persistent(let generation):
            return generation.totalLength
        case .attemptOnly(_, _, let totalLength):
            return totalLength
        }
    }

    var persistentGeneration: ValidatedContentGeneration? {
        guard case .persistent(let generation) = self else { return nil }
        return generation
    }
}

private extension Int64 {
    func addingClamped(_ other: Int64) -> Int64 {
        let result = addingReportingOverflow(other)
        guard result.overflow else { return result.partialValue }
        return other >= 0 ? .max : .min
    }
}
