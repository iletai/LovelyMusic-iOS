#if DEBUG
import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum DeterministicFMP4Fixture {
    typealias Manifest = DeterministicFixtureManifest
    typealias TimeoutWaiter = @Sendable (Duration) async -> Void
    typealias LifecycleHook = @Sendable (LifecycleEvent) async -> Void
    typealias SegmentPayloadTransform = @Sendable (
        SegmentKind,
        Int,
        Data
    ) throws -> Data
    typealias SegmentWorkerCloseObserver = @Sendable (
        SegmentWorkerCloseSnapshot
    ) -> Void
    typealias FinishWritingStarter = (
        AVAssetWriter,
        @escaping @Sendable () -> Void
    ) -> Void

    struct EncodingProfile: Equatable, Sendable {
        enum Codec: Equatable, Sendable {
            case aac
        }

        enum BitrateMode: Equatable, Sendable {
            case constant
        }

        let codec: Codec
        let sampleRate: Double
        let channelCount: Int
        let nominalBitrateBitsPerSecond: Int
        let bitrateMode: BitrateMode

        fileprivate var manifestCodec: String {
            switch codec {
            case .aac: "aac"
            }
        }

        fileprivate var manifestProfile: String {
            switch codec {
            case .aac: "aac-lc"
            }
        }

        fileprivate var mimeType: String {
            switch codec {
            case .aac: "audio/mp4"
            }
        }

        fileprivate var qualityLabel: String {
            switch codec {
            case .aac:
                "aac-\(nominalBitrateBitsPerSecond / 1_000)kbps"
            }
        }
    }

    static let encodingProfile = EncodingProfile(
        codec: .aac,
        sampleRate: 48_000,
        channelCount: 1,
        nominalBitrateBitsPerSecond: 128_000,
        bitrateMode: .constant
    )

    enum Configuration: Equatable, Sendable {
        case twentySeconds
        case sixtySeconds

        fileprivate var durationSeconds: Double {
            switch self {
            case .twentySeconds: 20
            case .sixtySeconds: 60
            }
        }

        fileprivate var toneRegions: [ToneRegion] {
            switch self {
            case .twentySeconds:
                [
                    ToneRegion(startSeconds: 0, endSeconds: 2.5, frequencyHz: 440),
                    ToneRegion(startSeconds: 2.5, endSeconds: 7.5, frequencyHz: 660),
                    ToneRegion(startSeconds: 7.5, endSeconds: 12.5, frequencyHz: 880),
                    ToneRegion(startSeconds: 12.5, endSeconds: 20, frequencyHz: 1_100),
                ]
            case .sixtySeconds:
                [ToneRegion(startSeconds: 0, endSeconds: 60, frequencyHz: 440)]
            }
        }
    }

    struct GeneratedFixture: Equatable, Sendable {
        let url: URL
        let manifest: Manifest
    }

    enum GenerationError: Error, Equatable, Sendable {
        case cancelled
        case timedOut
        case invalidOutputRoot
        case writerFailed
    }

    enum TerminalOutcome: Equatable, Sendable {
        case completed
        case cancelled
        case timedOut
        case failed
    }

    enum LifecycleEvent: Sendable {
        case writerDidStart
        case timeoutCancellationRequested
        case finishWritingDidStart
        case writerCancellationRequested
        case writerDidFinish
        case segmentCallbackDidStart(SegmentCallbackObservation)
        case segmentWorkerCloseRequested(SegmentWorkerCloseSnapshot)
        case segmentAssemblySealDidClaim
        case outputDidCommitBeforeTerminalClaim
        case terminal(TerminalOutcome)
    }

    enum SegmentWorkerCloseReason: Equatable, Sendable {
        case parentCancelled
        case timedOut
        case validationFailed
    }

    struct SegmentWorkerCloseSnapshot: Equatable, Sendable {
        let reason: SegmentWorkerCloseReason
        let preprocessingAdmissionCount: Int
        let activePreprocessingCount: Int
        let activeCallbackCount: Int
    }

    struct CapabilityDescriptor: Equatable, Sendable {
        let mimeType: String
        let codec: String
        let profile: String
        let containerLayout: String
        let nominalBitrateBitsPerSecond: Int
        let measuredBitrateBitsPerSecond: Double
        let sampleRate: Double
        let channelCount: Int
        let qualityLabel: String
        let fragmentCadenceSeconds: Double

        init(
            mimeType: String,
            codec: String,
            profile: String,
            containerLayout: String,
            nominalBitrateBitsPerSecond: Int,
            measuredBitrateBitsPerSecond: Double,
            sampleRate: Double,
            channelCount: Int,
            qualityLabel: String,
            fragmentCadenceSeconds: Double
        ) {
            self.mimeType = mimeType
            self.codec = codec
            self.profile = profile
            self.containerLayout = containerLayout
            self.nominalBitrateBitsPerSecond = nominalBitrateBitsPerSecond
            self.measuredBitrateBitsPerSecond = measuredBitrateBitsPerSecond
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.qualityLabel = qualityLabel
            self.fragmentCadenceSeconds = fragmentCadenceSeconds
        }
    }

    enum CompatibilityMismatch: Equatable, Sendable {
        case mimeType
        case codec
        case profile
        case containerLayout
        case nominalBitrate
        case measuredBitrate
        case sampleRate
        case channelCount
        case quality
        case fragmentCadence
    }

    enum IntegrityMismatch: Equatable, Hashable, Sendable {
        case payloadSHA256
        case contentLength
        case containerLayout
        case measuredBitrate
    }

    enum SegmentKind: Equatable, Sendable {
        case initialization
        case media
    }

    struct SegmentCallbackObservation: Equatable, Sendable {
        let kind: SegmentKind
        let ordinal: Int
        let rawStartFrame: Int64
        let rawEndFrame: Int64
        let coveredPresentationStartFrame: Int64
        let coveredPresentationEndFrame: Int64
        let presentationMediaStartFrame: Int64

        init(
            kind: SegmentKind,
            ordinal: Int,
            rawStartFrame: Int64,
            rawEndFrame: Int64,
            presentationMediaStartFrame: Int64 = 0,
            coveredPresentationStartFrame: Int64,
            coveredPresentationEndFrame: Int64
        ) {
            self.kind = kind
            self.ordinal = ordinal
            self.rawStartFrame = rawStartFrame
            self.rawEndFrame = rawEndFrame
            self.coveredPresentationStartFrame = coveredPresentationStartFrame
            self.coveredPresentationEndFrame = coveredPresentationEndFrame
            self.presentationMediaStartFrame = presentationMediaStartFrame
        }
    }

    struct SegmentDeliveryToken: Equatable, Hashable, Sendable {
        fileprivate let gateID: UUID
        fileprivate let deliveryID: UUID
    }

    struct GenerationLeaseToken: Equatable, Hashable, Sendable {
        fileprivate let gateID: UUID
        fileprivate let leaseID: UUID
    }

    struct SegmentAssemblyEntry: Equatable, Sendable {
        let observation: SegmentCallbackObservation
        let payload: Data
    }

    struct SegmentAssemblySnapshot: Equatable, Sendable {
        let writerFinished: Bool
        let contiguousCoveredPresentationEndFrame: Int64
        let orderedEntries: [SegmentAssemblyEntry]
    }

    enum SegmentAssemblyError: Error, Equatable, Sendable {
        case generationLeaseUnavailable
        case staleDeliveryToken
        case deliveryAlreadyCompleted
        case deliveryAfterAssemblyClaim
        case mediaSegmentCountExceeded(maximum: Int)
        case payloadByteLimitExceeded(maximum: Int)
        case emptyPayload
        case mediaBeforeInitialization
        case duplicateInitialization
        case duplicateSegmentOrdinal(ordinal: Int)
        case initializationAfterMedia
        case nonpositiveSegmentRange
        case rawTailExceedsPacketTolerance
        case coveredPresentationOutsideRawRange
        case coveredPresentationOutsideTarget
        case coveredPresentationOverlap
        case coveredPresentationRegression
        case terminalPaddingStartMismatch
        case terminalPaddingBeforeCompleteCoverage
        case duplicateTerminalPadding
        case invalidPresentationMediaStart
        case presentationMappingOverflow
        case coveredPresentationMappingMismatch
        case presentationMediaStartMismatch
        case assemblyNotReady
        case assemblyAlreadyClaimed
        case gateInvalid
    }

    final class SegmentAssemblyGate: @unchecked Sendable {
        let targetPresentationEndFrame: Int64
        let nominalFragmentFrameCount: Int64
        let packetFrameTolerance: Int64
        let maximumCollectedByteCount = 4 * 1_024 * 1_024
        let maximumMediaSegmentCount: Int

        private struct PendingDelivery {
            let token: SegmentDeliveryToken
            let entry: SegmentAssemblyEntry
        }

        private let lock = NSLock()
        private let gateID = UUID()
        private var activeLease: GenerationLeaseToken?
        private var leaseAcquisitionCount = 0
        private var active: [UUID: PendingDelivery] = [:]
        private var completedDeliveryIDs: Set<UUID> = []
        private var completedEntries: [SegmentAssemblyEntry] = []
        private var reservedOrdinals: Set<Int> = []
        private var initializationReserved = false
        private var mediaHasBegun = false
        private var terminalPaddingReserved = false
        private var boundPresentationMediaStartFrame: Int64?
        private var mediaReservationCount = 0
        private var retainedBytes = 0
        private var claimedBytes = 0
        private var contiguousCoverageEnd: Int64 = 0
        private var didFinishWriter = false
        private var cancellationRequested = false
        private var invalid = false
        private var sealClaimCount = 0
        private var snapshot: SegmentAssemblySnapshot?

        init(
            targetPresentationEndFrame: Int64,
            nominalFragmentFrameCount: Int64,
            packetFrameTolerance: Int64
        ) {
            self.targetPresentationEndFrame = targetPresentationEndFrame
            self.nominalFragmentFrameCount = nominalFragmentFrameCount
            self.packetFrameTolerance = packetFrameTolerance
            if targetPresentationEndFrame > 0, nominalFragmentFrameCount > 0 {
                let quotient = targetPresentationEndFrame / nominalFragmentFrameCount
                let remainder = targetPresentationEndFrame % nominalFragmentFrameCount
                let roundedUp = quotient + (remainder == 0 ? 0 : 1)
                maximumMediaSegmentCount = roundedUp >= Int64(Int.max - 1)
                    ? Int.max
                    : Int(roundedUp) + 1
            } else {
                maximumMediaSegmentCount = 0
            }
        }

        var writerFinished: Bool { withLock { didFinishWriter } }
        var activeDeliveryCount: Int { withLock { active.count } }
        var contiguousCoveredPresentationEndFrame: Int64 {
            withLock { contiguousCoverageEnd }
        }
        var writerCancellationRequested: Bool {
            withLock { cancellationRequested }
        }
        var successfulSealClaimCount: Int { withLock { sealClaimCount } }
        var retainedPayloadByteCount: Int { withLock { retainedBytes } }
        var claimedPayloadByteCount: Int { withLock { claimedBytes } }
        var claimedSnapshot: SegmentAssemblySnapshot? { withLock { snapshot } }
        var presentationMediaStartFrame: Int64 {
            withLock { boundPresentationMediaStartFrame ?? 0 }
        }
        var isInvalid: Bool { withLock { invalid } }
        var hasActiveGenerationLease: Bool { withLock { activeLease != nil } }
        var generationLeaseAcquisitionCount: Int {
            withLock { leaseAcquisitionCount }
        }
        var isReadyForAssembly: Bool { withLock { readinessLocked } }

        func acquireGenerationLease() throws -> GenerationLeaseToken {
            try withLock {
                guard activeLease == nil,
                    leaseAcquisitionCount == 0,
                    pristineLocked
                else {
                    throw SegmentAssemblyError.generationLeaseUnavailable
                }
                let token = GenerationLeaseToken(gateID: gateID, leaseID: UUID())
                activeLease = token
                leaseAcquisitionCount = 1
                return token
            }
        }

        func releaseGenerationLease(_ token: GenerationLeaseToken) throws {
            try withLock {
                guard token.gateID == gateID, activeLease == token else {
                    throw SegmentAssemblyError.generationLeaseUnavailable
                }
                activeLease = nil
            }
        }

        func beginDelivery(
            _ observation: SegmentCallbackObservation,
            ownedPayload: Data
        ) throws -> SegmentDeliveryToken {
            try withLock {
                if snapshot != nil {
                    invalidateLocked()
                    throw SegmentAssemblyError.deliveryAfterAssemblyClaim
                }
                guard !invalid else { throw SegmentAssemblyError.gateInvalid }
                guard !ownedPayload.isEmpty else {
                    invalidateLocked()
                    throw SegmentAssemblyError.emptyPayload
                }
                guard ownedPayload.count <= maximumCollectedByteCount - retainedBytes else {
                    invalidateLocked()
                    throw SegmentAssemblyError.payloadByteLimitExceeded(
                        maximum: maximumCollectedByteCount
                    )
                }

                switch observation.kind {
                case .initialization:
                    if mediaHasBegun {
                        invalidateLocked()
                        throw SegmentAssemblyError.initializationAfterMedia
                    }
                    guard !initializationReserved else {
                        invalidateLocked()
                        throw SegmentAssemblyError.duplicateInitialization
                    }
                    guard observation.ordinal == 0,
                        observation.rawStartFrame == 0,
                        observation.rawEndFrame == 0,
                        observation.coveredPresentationStartFrame == 0,
                        observation.coveredPresentationEndFrame == 0
                    else {
                        invalidateLocked()
                        throw SegmentAssemblyError.nonpositiveSegmentRange
                    }
                    try bindPresentationMappingLocked(
                        observation.presentationMediaStartFrame
                    )

                case .media:
                    guard initializationReserved else {
                        invalidateLocked()
                        throw SegmentAssemblyError.mediaBeforeInitialization
                    }
                    guard mediaReservationCount < maximumMediaSegmentCount else {
                        invalidateLocked()
                        throw SegmentAssemblyError.mediaSegmentCountExceeded(
                            maximum: maximumMediaSegmentCount
                        )
                    }
                    guard !reservedOrdinals.contains(observation.ordinal) else {
                        invalidateLocked()
                        throw SegmentAssemblyError.duplicateSegmentOrdinal(
                            ordinal: observation.ordinal
                        )
                    }
                    guard observation.presentationMediaStartFrame
                        == boundPresentationMediaStartFrame
                    else {
                        invalidateLocked()
                        throw SegmentAssemblyError.presentationMediaStartMismatch
                    }
                    if isTerminalPaddingObservation(observation) {
                        try validateTerminalPaddingLocked(observation)
                    } else {
                        try validateMediaObservationLocked(observation)
                    }
                }

                let token = SegmentDeliveryToken(gateID: gateID, deliveryID: UUID())
                let entry = SegmentAssemblyEntry(
                    observation: observation,
                    payload: ownedPayload
                )
                active[token.deliveryID] = PendingDelivery(token: token, entry: entry)
                retainedBytes += ownedPayload.count
                reservedOrdinals.insert(observation.ordinal)
                switch observation.kind {
                case .initialization:
                    initializationReserved = true
                case .media:
                    mediaHasBegun = true
                    mediaReservationCount += 1
                    if isTerminalPaddingObservation(observation) {
                        terminalPaddingReserved = true
                    }
                }
                return token
            }
        }

        func completeDelivery(_ token: SegmentDeliveryToken) throws {
            try withLock {
                guard token.gateID == gateID else {
                    throw SegmentAssemblyError.staleDeliveryToken
                }
                if completedDeliveryIDs.contains(token.deliveryID) {
                    throw SegmentAssemblyError.deliveryAlreadyCompleted
                }
                guard let pending = active.removeValue(forKey: token.deliveryID) else {
                    throw SegmentAssemblyError.staleDeliveryToken
                }
                completedDeliveryIDs.insert(token.deliveryID)
                completedEntries.append(pending.entry)
                recomputeContiguousCoverageLocked()
            }
        }

        fileprivate func completeSegmentWorkerDelivery(
            _ token: SegmentDeliveryToken
        ) throws {
            try withLock {
                guard token.gateID == gateID else {
                    throw SegmentAssemblyError.staleDeliveryToken
                }
                if completedDeliveryIDs.contains(token.deliveryID) {
                    throw SegmentAssemblyError.deliveryAlreadyCompleted
                }
                guard let pending = active.removeValue(
                    forKey: token.deliveryID
                ) else {
                    throw SegmentAssemblyError.staleDeliveryToken
                }
                guard !invalid else {
                    retainedBytes -= pending.entry.payload.count
                    throw SegmentAssemblyError.gateInvalid
                }
                completedDeliveryIDs.insert(token.deliveryID)
                completedEntries.append(pending.entry)
                recomputeContiguousCoverageLocked()
            }
        }

        fileprivate func abortDelivery(_ token: SegmentDeliveryToken) throws {
            try withLock {
                guard token.gateID == gateID else {
                    throw SegmentAssemblyError.staleDeliveryToken
                }
                if completedDeliveryIDs.contains(token.deliveryID) {
                    throw SegmentAssemblyError.deliveryAlreadyCompleted
                }
                guard let pending = active.removeValue(
                    forKey: token.deliveryID
                ) else {
                    throw SegmentAssemblyError.staleDeliveryToken
                }
                retainedBytes -= pending.entry.payload.count
            }
        }

        fileprivate func invalidateForSegmentWorkerClose() {
            withLock { invalidateLocked() }
        }

        fileprivate func discardPayloadOwnershipAfterSegmentWorkerFailure() {
            withLock {
                active.removeAll(keepingCapacity: false)
                completedEntries.removeAll(keepingCapacity: false)
                completedDeliveryIDs.removeAll(keepingCapacity: false)
                reservedOrdinals.removeAll(keepingCapacity: false)
                initializationReserved = false
                mediaHasBegun = false
                terminalPaddingReserved = false
                boundPresentationMediaStartFrame = nil
                mediaReservationCount = 0
                retainedBytes = 0
                claimedBytes = 0
                contiguousCoverageEnd = 0
                snapshot = nil
            }
        }

        func markWriterFinished() {
            withLock { didFinishWriter = true }
        }

        func claimAssembly() throws -> SegmentAssemblySnapshot {
            try withLock {
                if snapshot != nil {
                    throw SegmentAssemblyError.assemblyAlreadyClaimed
                }
                guard !invalid else { throw SegmentAssemblyError.gateInvalid }
                guard readinessLocked else {
                    throw SegmentAssemblyError.assemblyNotReady
                }
                let ordered = completedEntries.sorted(by: temporalEntryOrder)
                let frozen = SegmentAssemblySnapshot(
                    writerFinished: didFinishWriter,
                    contiguousCoveredPresentationEndFrame: contiguousCoverageEnd,
                    orderedEntries: ordered
                )
                snapshot = frozen
                sealClaimCount = 1
                claimedBytes = ordered.reduce(0) { $0 + $1.payload.count }
                return frozen
            }
        }

        fileprivate func matchesGenerationConfiguration(
            targetPresentationEndFrame: Int64,
            nominalFragmentFrameCount: Int64,
            packetFrameTolerance: Int64
        ) -> Bool {
            withLock {
                self.targetPresentationEndFrame == targetPresentationEndFrame
                    && self.nominalFragmentFrameCount == nominalFragmentFrameCount
                    && self.packetFrameTolerance == packetFrameTolerance
            }
        }

        fileprivate func claimRemainsPublishable(
            _ expected: SegmentAssemblySnapshot
        ) -> Bool {
            withLock {
                !invalid
                    && !cancellationRequested
                    && snapshot == expected
                    && sealClaimCount == 1
            }
        }

        private var pristineLocked: Bool {
            !invalid
                && !cancellationRequested
                && !didFinishWriter
                && snapshot == nil
                && !initializationReserved
                && !mediaHasBegun
                && !terminalPaddingReserved
                && boundPresentationMediaStartFrame == nil
                && mediaReservationCount == 0
                && active.isEmpty
                && completedEntries.isEmpty
                && completedDeliveryIDs.isEmpty
                && reservedOrdinals.isEmpty
                && retainedBytes == 0
                && claimedBytes == 0
                && sealClaimCount == 0
        }

        private var readinessLocked: Bool {
            !invalid
                && !cancellationRequested
                && snapshot == nil
                && didFinishWriter
                && active.isEmpty
                && initializationReserved
                && mediaHasBegun
                && contiguousCoverageEnd >= targetPresentationEndFrame
        }

        private func bindPresentationMappingLocked(
            _ mediaStartFrame: Int64
        ) throws {
            guard mediaStartFrame >= 0 else {
                invalidateLocked()
                throw SegmentAssemblyError.invalidPresentationMediaStart
            }
            let (rawPresentationEnd, endOverflow) = mediaStartFrame
                .addingReportingOverflow(targetPresentationEndFrame)
            let (_, toleranceOverflow) = rawPresentationEnd
                .addingReportingOverflow(packetFrameTolerance)
            guard !endOverflow, !toleranceOverflow else {
                invalidateLocked()
                throw SegmentAssemblyError.presentationMappingOverflow
            }
            if let existing = boundPresentationMediaStartFrame {
                guard existing == mediaStartFrame else {
                    invalidateLocked()
                    throw SegmentAssemblyError.presentationMediaStartMismatch
                }
            } else {
                boundPresentationMediaStartFrame = mediaStartFrame
            }
        }

        private func projectRawFrameLocked(_ rawFrame: Int64) -> Int64 {
            let origin = boundPresentationMediaStartFrame ?? 0
            if rawFrame <= origin { return 0 }
            return min(targetPresentationEndFrame, rawFrame - origin)
        }

        private func expectedRawPresentationEndLocked() throws -> Int64 {
            let origin = boundPresentationMediaStartFrame ?? 0
            let (value, overflow) = origin.addingReportingOverflow(
                targetPresentationEndFrame
            )
            guard !overflow else {
                invalidateLocked()
                throw SegmentAssemblyError.presentationMappingOverflow
            }
            return value
        }

        private func isTerminalPaddingObservation(
            _ observation: SegmentCallbackObservation
        ) -> Bool {
            observation.kind == .media
                && observation.coveredPresentationStartFrame
                    == targetPresentationEndFrame
                && observation.coveredPresentationEndFrame
                    == targetPresentationEndFrame
        }

        private func validateTerminalPaddingLocked(
            _ observation: SegmentCallbackObservation
        ) throws {
            let rawPresentationEnd = try expectedRawPresentationEndLocked()
            guard observation.rawStartFrame == rawPresentationEnd else {
                invalidateLocked()
                throw SegmentAssemblyError.terminalPaddingStartMismatch
            }
            guard observation.rawEndFrame > observation.rawStartFrame else {
                invalidateLocked()
                throw SegmentAssemblyError.nonpositiveSegmentRange
            }
            let (maximumRawEnd, overflow) = rawPresentationEnd
                .addingReportingOverflow(packetFrameTolerance)
            guard !overflow, observation.rawEndFrame <= maximumRawEnd else {
                invalidateLocked()
                throw SegmentAssemblyError.rawTailExceedsPacketTolerance
            }
            guard reservedContiguousCoverageEndLocked()
                >= targetPresentationEndFrame
            else {
                invalidateLocked()
                throw SegmentAssemblyError.terminalPaddingBeforeCompleteCoverage
            }
            let existingMedia = active.values.map(\.entry.observation)
                + completedEntries.map(\.observation)
            guard !existingMedia.contains(where: { existing in
                existing.kind == .media
                    && existing.coveredPresentationEndFrame
                        == targetPresentationEndFrame
                    && existing.rawEndFrame > rawPresentationEnd
            }) else {
                invalidateLocked()
                throw SegmentAssemblyError.duplicateTerminalPadding
            }
            guard !terminalPaddingReserved else {
                invalidateLocked()
                throw SegmentAssemblyError.duplicateTerminalPadding
            }
        }

        private func reservedContiguousCoverageEndLocked() -> Int64 {
            let media = (
                active.values.map(\.entry) + completedEntries
            )
            .filter {
                $0.observation.kind == .media
                    && $0.observation.coveredPresentationEndFrame
                        > $0.observation.coveredPresentationStartFrame
            }
            .sorted(by: temporalEntryOrder)
            var cursor: Int64 = 0
            for entry in media {
                let observation = entry.observation
                if observation.coveredPresentationStartFrame > cursor { break }
                cursor = max(cursor, observation.coveredPresentationEndFrame)
            }
            return cursor
        }

        private func validateMediaObservationLocked(
            _ observation: SegmentCallbackObservation
        ) throws {
            guard observation.rawStartFrame >= 0,
                observation.rawEndFrame > observation.rawStartFrame,
                observation.coveredPresentationStartFrame >= 0,
                observation.coveredPresentationEndFrame
                    > observation.coveredPresentationStartFrame
            else {
                invalidateLocked()
                throw SegmentAssemblyError.nonpositiveSegmentRange
            }
            guard observation.coveredPresentationEndFrame
                <= targetPresentationEndFrame
            else {
                invalidateLocked()
                throw SegmentAssemblyError.coveredPresentationOutsideTarget
            }
            let origin = boundPresentationMediaStartFrame ?? 0
            if origin == 0,
                (observation.rawStartFrame
                    > observation.coveredPresentationStartFrame
                    || observation.rawEndFrame
                        < observation.coveredPresentationEndFrame)
            {
                    invalidateLocked()
                    throw SegmentAssemblyError.coveredPresentationOutsideRawRange
            }
            let projectedStart = projectRawFrameLocked(
                observation.rawStartFrame
            )
            let projectedEnd = projectRawFrameLocked(observation.rawEndFrame)
            guard observation.coveredPresentationStartFrame == projectedStart,
                observation.coveredPresentationEndFrame == projectedEnd
            else {
                invalidateLocked()
                throw SegmentAssemblyError.coveredPresentationMappingMismatch
            }
            if observation.coveredPresentationEndFrame
                == targetPresentationEndFrame
            {
                let rawPresentationEnd = try expectedRawPresentationEndLocked()
                let (maximumRawEnd, overflow) = rawPresentationEnd
                    .addingReportingOverflow(packetFrameTolerance)
                guard !overflow, observation.rawEndFrame <= maximumRawEnd else {
                    invalidateLocked()
                    throw SegmentAssemblyError.rawTailExceedsPacketTolerance
                }
            }

            let existing = active.values.map(\.entry.observation)
                + completedEntries.map(\.observation)
            let newRange = observation.coveredPresentationStartFrame
                ..< observation.coveredPresentationEndFrame
            for other in existing where other.kind == .media {
                let otherRange = other.coveredPresentationStartFrame
                    ..< other.coveredPresentationEndFrame
                guard newRange.overlaps(otherRange) else { continue }
                invalidateLocked()
                if observation.coveredPresentationEndFrame <= contiguousCoverageEnd {
                    throw SegmentAssemblyError.coveredPresentationRegression
                }
                throw SegmentAssemblyError.coveredPresentationOverlap
            }
        }

        private func recomputeContiguousCoverageLocked() {
            let media = completedEntries
                .filter { $0.observation.kind == .media }
                .sorted(by: temporalEntryOrder)
            var cursor: Int64 = 0
            for entry in media {
                let observation = entry.observation
                if observation.coveredPresentationStartFrame > cursor { break }
                cursor = max(cursor, observation.coveredPresentationEndFrame)
            }
            contiguousCoverageEnd = cursor
        }

        private func temporalEntryOrder(
            _ lhs: SegmentAssemblyEntry,
            _ rhs: SegmentAssemblyEntry
        ) -> Bool {
            if lhs.observation.kind != rhs.observation.kind {
                return lhs.observation.kind == .initialization
            }
            if lhs.observation.coveredPresentationStartFrame
                != rhs.observation.coveredPresentationStartFrame
            {
                return lhs.observation.coveredPresentationStartFrame
                    < rhs.observation.coveredPresentationStartFrame
            }
            return lhs.observation.ordinal < rhs.observation.ordinal
        }

        private func invalidateLocked() {
            invalid = true
            cancellationRequested = true
        }

        @discardableResult
        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    static func generate(
        configuration: Configuration,
        outputURL: URL,
        timeout: Duration,
        timeoutWaiter: @escaping TimeoutWaiter = { duration in
            try? await ContinuousClock().sleep(for: duration)
        },
        finishWritingStarter: @escaping FinishWritingStarter = {
            writer,
            completion in
            writer.finishWriting(completionHandler: completion)
        },
        segmentPayloadTransform: SegmentPayloadTransform? = nil,
        segmentWorkerCloseObserver: SegmentWorkerCloseObserver? = nil,
        segmentAssemblyGate: SegmentAssemblyGate? = nil,
        lifecycleHook: LifecycleHook? = nil
    ) async throws -> GeneratedFixture {
        let state = GenerationState()
        let targetEndFrame = Int64(configuration.durationSeconds * 48_000)
        let assemblyGate = segmentAssemblyGate ?? SegmentAssemblyGate(
            targetPresentationEndFrame: targetEndFrame,
            nominalFragmentFrameCount: 48_000,
            packetFrameTolerance: 1_024
        )
        return try await withTaskCancellationHandler {
            try await generateControlled(
                configuration: configuration,
                outputURL: outputURL,
                timeout: timeout,
                timeoutWaiter: timeoutWaiter,
                finishWritingStarter: finishWritingStarter,
                segmentPayloadTransform: segmentPayloadTransform,
                segmentWorkerCloseObserver: segmentWorkerCloseObserver,
                assemblyGate: assemblyGate,
                lifecycleHook: lifecycleHook,
                state: state
            )
        } onCancel: {
            state.requestCancellation()
        }
    }

    private static func generateControlled(
        configuration: Configuration,
        outputURL: URL,
        timeout: Duration,
        timeoutWaiter: @escaping TimeoutWaiter,
        finishWritingStarter: @escaping FinishWritingStarter,
        segmentPayloadTransform: SegmentPayloadTransform?,
        segmentWorkerCloseObserver: SegmentWorkerCloseObserver?,
        assemblyGate: SegmentAssemblyGate,
        lifecycleHook: LifecycleHook?,
        state: GenerationState
    ) async throws -> GeneratedFixture {
        let fileManager = FileManager.default
        var writer: AVAssetWriter?
        var partialURL: URL?
        var committedOutput = false
        var timeoutTask: Task<Void, Never>?
        var generationLease: GenerationLeaseToken?
        var segmentCollector: FragmentedMP4SegmentCollector?

        do {
            let targetEndFrame = Int64(configuration.durationSeconds * 48_000)
            guard assemblyGate.matchesGenerationConfiguration(
                targetPresentationEndFrame: targetEndFrame,
                nominalFragmentFrameCount: 48_000,
                packetFrameTolerance: 1_024
            ) else {
                throw GenerationError.writerFailed
            }
            generationLease = try assemblyGate.acquireGenerationLease()
            try validateOutputRoot(outputURL, fileManager: fileManager)
            try state.throwIfAborted()

            if timeout <= .zero {
                if state.requestTimeout() {
                    await lifecycleHook?(.timeoutCancellationRequested)
                }
                throw GenerationError.timedOut
            }

            timeoutTask = Task {
                await timeoutWaiter(timeout)
                guard !Task.isCancelled else { return }
                if state.requestTimeout() {
                    await lifecycleHook?(.timeoutCancellationRequested)
                }
            }

            let temporaryURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(outputURL.lastPathComponent).\(UUID().uuidString).partial.mp4"
                )
            partialURL = temporaryURL
            let collector = FragmentedMP4SegmentCollector(
                assemblyGate: assemblyGate,
                targetPresentationEndFrame: targetEndFrame,
                payloadTransform: segmentPayloadTransform,
                workerCloseObserver: segmentWorkerCloseObserver,
                state: state,
                lifecycleHook: lifecycleHook
            )
            segmentCollector = collector
            let assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
            writer = assetWriter
            configure(assetWriter, segmentCollector: collector)

            let sourceFormat = try makePCMFormatDescription()
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: aacOutputSettings(),
                sourceFormatHint: sourceFormat
            )
            input.expectsMediaDataInRealTime = false
            guard assetWriter.canAdd(input) else {
                throw GenerationError.writerFailed
            }
            assetWriter.add(input)
            guard assetWriter.startWriting() else {
                throw GenerationError.writerFailed
            }
            assetWriter.startSession(atSourceTime: .zero)

            await lifecycleHook?(.writerDidStart)
            try state.throwIfAborted()

            let appender = PCMAssetWriterAppender(
                input: input,
                formatDescription: sourceFormat,
                configuration: configuration,
                state: state
            )
            try await appender.appendAllSamples()
            try state.throwIfAborted()
            await lifecycleHook?(.finishWritingDidStart)
            try await finishWriting(
                assetWriter,
                state: state,
                starter: finishWritingStarter
            )
            try state.throwIfAborted()
            guard assetWriter.status == .completed else {
                throw GenerationError.writerFailed
            }
            await lifecycleHook?(.writerDidFinish)
            try await collector.drainDeliveries()
            assemblyGate.markWriterFinished()
            let assemblySnapshot = try assemblyGate.claimAssembly()
            await lifecycleHook?(.segmentAssemblySealDidClaim)
            guard assemblyGate.claimRemainsPublishable(assemblySnapshot) else {
                throw GenerationError.writerFailed
            }
            let assembledBytes = assemblySnapshot.orderedEntries.reduce(into: Data()) {
                output,
                entry in
                output.append(entry.payload)
            }
            try assembledBytes.write(to: temporaryURL, options: [])
            let bytes = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
            let container = try FragmentedMP4Inspection.inspect(bytes)
            let profile = encodingProfile
            let manifest = Manifest(
                payloadSHA256: sha256Hex(bytes),
                codec: profile.manifestCodec,
                profile: profile.manifestProfile,
                qualityLabel: profile.qualityLabel,
                mimeType: profile.mimeType,
                containerLayout: container.layoutProfile,
                measuredBitrateBitsPerSecond: Double(container.mediaPayloadBytes * 8)
                    / configuration.durationSeconds,
                nominalBitrateBitsPerSecond:
                    profile.nominalBitrateBitsPerSecond,
                sampleRate: profile.sampleRate,
                channelCount: profile.channelCount,
                fragmentCadenceSeconds: 1,
                durationSeconds: configuration.durationSeconds,
                contentLength: Int64(bytes.count),
                toneScheduleSHA256: toneScheduleSHA256(configuration.toneRegions)
            )

            try state.throwIfAborted()
            guard assemblyGate.claimRemainsPublishable(assemblySnapshot) else {
                throw GenerationError.writerFailed
            }
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
            committedOutput = true
            removeTemporaryArtifactFamily(
                for: temporaryURL,
                fileManager: fileManager
            )
            try state.throwIfAborted()
            await lifecycleHook?(.outputDidCommitBeforeTerminalClaim)
            guard assemblyGate.claimRemainsPublishable(assemblySnapshot) else {
                throw GenerationError.writerFailed
            }
            if let task = timeoutTask {
                task.cancel()
                await task.value
                timeoutTask = nil
            }
            guard assemblyGate.claimRemainsPublishable(assemblySnapshot) else {
                throw GenerationError.writerFailed
            }
            try state.claimCompletedTerminal()
            if let generationLease {
                try? assemblyGate.releaseGenerationLease(generationLease)
            }
            await lifecycleHook?(.terminal(.completed))
            return GeneratedFixture(url: outputURL, manifest: manifest)
        } catch {
            let generationError = normalizedError(error, state: state)
            if generationError == .timedOut {
                if let task = timeoutTask {
                    await task.value
                    timeoutTask = nil
                }
            } else {
                timeoutTask?.cancel()
            }
            if let writer {
                await lifecycleHook?(.writerCancellationRequested)
                writer.cancelWriting()
            }
            if let segmentCollector {
                await segmentCollector.closeAndDrain(
                    for: generationError
                )
            }
            if let partialURL {
                removeTemporaryArtifactFamily(
                    for: partialURL,
                    fileManager: fileManager
                )
            }
            if committedOutput {
                try? fileManager.removeItem(at: outputURL)
            }
            if generationError != .timedOut, let task = timeoutTask {
                await task.value
                timeoutTask = nil
            }
            if let generationLease {
                try? assemblyGate.releaseGenerationLease(generationLease)
            }
            if state.claimTerminal() {
                await lifecycleHook?(.terminal(terminalOutcome(for: generationError)))
            }
            throw generationError
        }
    }

    private static func validateOutputRoot(
        _ outputURL: URL,
        fileManager: FileManager
    ) throws {
        guard outputURL.isFileURL, !outputURL.lastPathComponent.isEmpty else {
            throw GenerationError.invalidOutputRoot
        }
        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            !fileManager.fileExists(atPath: outputURL.path)
        else {
            throw GenerationError.invalidOutputRoot
        }
    }

    private static func configure(
        _ writer: AVAssetWriter,
        segmentCollector: FragmentedMP4SegmentCollector
    ) {
        writer.outputFileTypeProfile = .mpeg4CMAFCompliant
        writer.preferredOutputSegmentInterval = CMTime(
            value: 48_000,
            timescale: 48_000
        )
        writer.initialSegmentStartTime = .zero
        writer.movieTimeScale = 48_000
        writer.delegate = segmentCollector
    }

    private static func aacOutputSettings() -> [String: Any] {
        let profile = encodingProfile
        let formatID: AudioFormatID
        switch profile.codec {
        case .aac:
            formatID = kAudioFormatMPEG4AAC
        }
        let bitrateStrategy: String
        switch profile.bitrateMode {
        case .constant:
            bitrateStrategy = AVAudioBitRateStrategy_Constant
        }
        return [
            AVFormatIDKey: formatID,
            AVSampleRateKey: profile.sampleRate,
            AVNumberOfChannelsKey: profile.channelCount,
            AVEncoderBitRateKey: profile.nominalBitrateBitsPerSecond,
            AVEncoderBitRateStrategyKey: bitrateStrategy,
        ]
    }

    private static func makePCMFormatDescription() throws -> CMAudioFormatDescription {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw GenerationError.writerFailed
        }
        return description
    }

    private static func finishWriting(
        _ writer: AVAssetWriter,
        state: GenerationState,
        starter: @escaping FinishWritingStarter
    ) async throws {
        let coordinator = FinishWritingCoordinator()
        let resolver = FinishWritingResolver(coordinator: coordinator)
        try await withCheckedThrowingContinuation { continuation in
            coordinator.install(continuation)
            state.registerAbortHandler { error in
                resolver.resolveAbort(error)
            }
            guard coordinator.claimStarterInvocation() else { return }
            starter(writer) {
                resolver.resolveNormalCompletion()
            }
        }
    }

    private static func normalizedError(
        _ error: Error,
        state: GenerationState
    ) -> GenerationError {
        if let abort = state.abortError() {
            return abort
        }
        if let generationError = error as? GenerationError {
            return generationError
        }
        return Task.isCancelled ? .cancelled : .writerFailed
    }

    private static func terminalOutcome(for error: GenerationError) -> TerminalOutcome {
        switch error {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .invalidOutputRoot, .writerFailed: .failed
        }
    }

    private static func removeTemporaryArtifactFamily(
        for partialURL: URL,
        fileManager: FileManager
    ) {
        let parent = partialURL.deletingLastPathComponent()
        let basename = partialURL.lastPathComponent
        guard let children = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard name == basename || name.hasPrefix(basename + ".sb-") else {
                continue
            }
            try? fileManager.removeItem(at: child)
        }
    }
}

struct DeterministicFixtureManifest: Equatable, Sendable {
    let payloadSHA256: String
    let codec: String
    let profile: String
    let qualityLabel: String
    let mimeType: String
    let containerLayout: String
    let measuredBitrateBitsPerSecond: Double
    let nominalBitrateBitsPerSecond: Int
    let sampleRate: Double
    let channelCount: Int
    let fragmentCadenceSeconds: Double
    let durationSeconds: Double
    let contentLength: Int64
    let toneScheduleSHA256: String

    fileprivate init(
        payloadSHA256: String,
        codec: String,
        profile: String,
        qualityLabel: String,
        mimeType: String,
        containerLayout: String,
        measuredBitrateBitsPerSecond: Double,
        nominalBitrateBitsPerSecond: Int,
        sampleRate: Double,
        channelCount: Int,
        fragmentCadenceSeconds: Double,
        durationSeconds: Double,
        contentLength: Int64,
        toneScheduleSHA256: String
    ) {
        self.payloadSHA256 = payloadSHA256
        self.codec = codec
        self.profile = profile
        self.qualityLabel = qualityLabel
        self.mimeType = mimeType
        self.containerLayout = containerLayout
        self.measuredBitrateBitsPerSecond = measuredBitrateBitsPerSecond
        self.nominalBitrateBitsPerSecond = nominalBitrateBitsPerSecond
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.fragmentCadenceSeconds = fragmentCadenceSeconds
        self.durationSeconds = durationSeconds
        self.contentLength = contentLength
        self.toneScheduleSHA256 = toneScheduleSHA256
    }

    func validateCompatibility(
        with candidate: DeterministicFMP4Fixture.CapabilityDescriptor
    ) -> [DeterministicFMP4Fixture.CompatibilityMismatch] {
        var mismatches: [DeterministicFMP4Fixture.CompatibilityMismatch] = []
        if candidate.mimeType != mimeType { mismatches.append(.mimeType) }
        if candidate.codec != codec { mismatches.append(.codec) }
        if candidate.profile != profile { mismatches.append(.profile) }
        if candidate.containerLayout != containerLayout {
            mismatches.append(.containerLayout)
        }
        if candidate.nominalBitrateBitsPerSecond != nominalBitrateBitsPerSecond {
            mismatches.append(.nominalBitrate)
        }
        let measuredTolerance = max(1, measuredBitrateBitsPerSecond * 0.10)
        if !candidate.measuredBitrateBitsPerSecond.isFinite
            || abs(
                candidate.measuredBitrateBitsPerSecond
                    - measuredBitrateBitsPerSecond
            ) > measuredTolerance
        {
            mismatches.append(.measuredBitrate)
        }
        if !candidate.sampleRate.isFinite
            || abs(candidate.sampleRate - sampleRate) > 0.5
        {
            mismatches.append(.sampleRate)
        }
        if candidate.channelCount != channelCount { mismatches.append(.channelCount) }
        if candidate.qualityLabel != qualityLabel { mismatches.append(.quality) }
        if !candidate.fragmentCadenceSeconds.isFinite
            || abs(candidate.fragmentCadenceSeconds - fragmentCadenceSeconds) > 0.000_001
        {
            mismatches.append(.fragmentCadence)
        }
        return mismatches
    }

    func validateIntegrityAndReinspect(
        at url: URL
    ) async throws -> [DeterministicFMP4Fixture.IntegrityMismatch] {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        var mismatches: [DeterministicFMP4Fixture.IntegrityMismatch] = []
        if sha256Hex(bytes) != payloadSHA256 {
            mismatches.append(.payloadSHA256)
        }
        if Int64(bytes.count) != contentLength {
            mismatches.append(.contentLength)
        }
        do {
            let container = try FragmentedMP4Inspection.inspect(bytes)
            if container.layoutProfile != containerLayout {
                mismatches.append(.containerLayout)
            }
            let measured = Double(container.mediaPayloadBytes * 8) / durationSeconds
            if abs(measured - measuredBitrateBitsPerSecond)
                > max(1, measuredBitrateBitsPerSecond * 0.01)
            {
                mismatches.append(.measuredBitrate)
            }
        } catch {
            mismatches.append(.containerLayout)
        }
        return Array(Set(mismatches)).sorted { String(describing: $0) < String(describing: $1) }
    }
}

private struct ToneRegion: Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let frequencyHz: Double
}

private final class FragmentedMP4SegmentCollector:
    NSObject,
    AVAssetWriterDelegate,
    @unchecked Sendable
{
    private let targetPresentationEndFrame: Int64
    private let payloadTransform: DeterministicFMP4Fixture.SegmentPayloadTransform?
    private let worker: SegmentCallbackWorker
    private let preprocessingLock = NSLock()
    private let timingLock = NSLock()
    private enum ReportTimeDomain {
        case raw
        case presentation
    }
    private var defaultSampleDuration: UInt32?
    private var presentationMediaStartFrame: Int64?
    private var reportTimeDomain: ReportTimeDomain?

    init(
        assemblyGate: DeterministicFMP4Fixture.SegmentAssemblyGate,
        targetPresentationEndFrame: Int64,
        payloadTransform: DeterministicFMP4Fixture.SegmentPayloadTransform?,
        workerCloseObserver: DeterministicFMP4Fixture.SegmentWorkerCloseObserver?,
        state: GenerationState,
        lifecycleHook: DeterministicFMP4Fixture.LifecycleHook?
    ) {
        self.targetPresentationEndFrame = targetPresentationEndFrame
        self.payloadTransform = payloadTransform
        worker = SegmentCallbackWorker(
            assemblyGate: assemblyGate,
            targetPresentationEndFrame: targetPresentationEndFrame,
            state: state,
            closeObserver: workerCloseObserver,
            lifecycleHook: lifecycleHook
        )
        super.init()
        worker.startMonitoringAbortState()
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        receive(
            segmentData: segmentData,
            segmentType: segmentType,
            segmentReport: segmentReport
        )
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType
    ) {
        receive(
            segmentData: segmentData,
            segmentType: segmentType,
            segmentReport: nil
        )
    }

    func drainDeliveries() async throws {
        try await worker.drain()
    }

    func closeAndDrain(
        for error: DeterministicFMP4Fixture.GenerationError
    ) async {
        await worker.closeAndDrain(for: error)
    }

    private func receive(
        segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        let callback = worker.beginCallback()
        defer { worker.finishCallback(callback.id) }
        guard callback.shouldProcess else { return }

        let kind: DeterministicFMP4Fixture.SegmentKind
        switch segmentType {
        case .initialization:
            kind = .initialization
        case .separable:
            kind = .media
        @unknown default:
            worker.rejectUnsupportedSegment()
            return
        }
        preprocessingLock.lock()
        defer { preprocessingLock.unlock() }
        guard let admission = worker.beginPreprocessing(kind: kind) else {
            return
        }

        do {
            let ownedPayload = Data(segmentData)
            let transformedPayload = try payloadTransform?(
                admission.kind,
                admission.ordinal,
                ownedPayload
            ) ?? ownedPayload
            let observation: DeterministicFMP4Fixture.SegmentCallbackObservation
            switch admission.kind {
            case .initialization:
                let metadata = try SegmentTimingParser.parseInitialization(
                    transformedPayload
                )
                timingLock.lock()
                defaultSampleDuration = metadata.defaultSampleDuration
                presentationMediaStartFrame = metadata.presentationMediaStartFrame
                timingLock.unlock()
                observation = .init(
                    kind: .initialization,
                    ordinal: admission.ordinal,
                    rawStartFrame: 0,
                    rawEndFrame: 0,
                    presentationMediaStartFrame:
                        metadata.presentationMediaStartFrame,
                    coveredPresentationStartFrame: 0,
                    coveredPresentationEndFrame: 0
                )

            case .media:
                timingLock.lock()
                let fallbackDuration = defaultSampleDuration
                let mediaStartFrame = presentationMediaStartFrame
                timingLock.unlock()
                guard let mediaStartFrame else {
                    throw DeterministicFMP4Fixture.GenerationError.writerFailed
                }
                let timing = try SegmentTimingParser.parse(
                    transformedPayload,
                    fallbackDefaultSampleDuration: fallbackDuration
                )
                try validateReport(
                    segmentReport,
                    against: timing,
                    mediaStartFrame: mediaStartFrame
                )
                observation = .init(
                    kind: .media,
                    ordinal: admission.ordinal,
                    rawStartFrame: timing.startFrame,
                    rawEndFrame: timing.endFrame,
                    presentationMediaStartFrame: mediaStartFrame,
                    coveredPresentationStartFrame: projectPresentationFrame(
                        timing.startFrame,
                        mediaStartFrame: mediaStartFrame
                    ),
                    coveredPresentationEndFrame: projectPresentationFrame(
                        timing.endFrame,
                        mediaStartFrame: mediaStartFrame
                    )
                )
            }
            worker.finishPreprocessing(
                admission,
                observation,
                ownedPayload: transformedPayload
            )
        } catch {
            worker.failPreprocessing(admission)
        }
    }

    private func validateReport(
        _ report: AVAssetSegmentReport?,
        against timing: SegmentTiming,
        mediaStartFrame: Int64
    ) throws {
        guard let report else { return }
        guard let track = report.trackReports.first(where: {
            $0.mediaType == .audio
        }) else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let reportStart = try frameValue(
            track.earliestPresentationTimeStamp,
            allowsZero: true
        )
        let reportDuration = try frameValue(
            track.duration,
            allowsZero: false
        )
        let (reportEnd, overflow) = reportStart.addingReportingOverflow(
            reportDuration
        )
        guard !overflow, reportEnd > reportStart else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let rawMatches = absoluteDifference(
            reportStart,
            timing.startFrame
        ) <= 1_024 && absoluteDifference(
            reportEnd,
            timing.endFrame
        ) <= 1_024
        let mappedStart = projectPresentationFrame(
            timing.startFrame,
            mediaStartFrame: mediaStartFrame
        )
        let mappedEnd = projectPresentationFrame(
            timing.endFrame,
            mediaStartFrame: mediaStartFrame
        )
        let presentationMatches = absoluteDifference(
            reportStart,
            mappedStart
        ) <= 1_024 && absoluteDifference(
            reportEnd,
            mappedEnd
        ) <= 1_024

        timingLock.lock()
        defer { timingLock.unlock() }
        switch reportTimeDomain {
        case .raw:
            guard rawMatches else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
        case .presentation:
            guard presentationMatches else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
        case nil:
            if rawMatches {
                reportTimeDomain = .raw
            } else if presentationMatches {
                reportTimeDomain = .presentation
            } else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
        }
    }

    private func projectPresentationFrame(
        _ rawFrame: Int64,
        mediaStartFrame: Int64
    ) -> Int64 {
        guard rawFrame > mediaStartFrame else { return 0 }
        return min(
            targetPresentationEndFrame,
            rawFrame - mediaStartFrame
        )
    }

    private func frameValue(
        _ time: CMTime,
        allowsZero: Bool
    ) throws -> Int64 {
        guard time.isValid,
            time.isNumeric,
            time.timescale > 0,
            time.value >= 0,
            allowsZero || time.value > 0
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let (_, multiplicationOverflow) = time.value.multipliedReportingOverflow(
            by: 48_000
        )
        guard !multiplicationOverflow else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let converted = CMTimeConvertScale(
            time,
            timescale: 48_000,
            method: .default
        )
        guard converted.isValid,
            converted.isNumeric,
            converted.timescale == 48_000,
            converted.value >= 0,
            allowsZero || converted.value > 0
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        return converted.value
    }

    private func absoluteDifference(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        guard lhs >= 0, rhs >= 0 else { return .max }
        let left = UInt64(lhs)
        let right = UInt64(rhs)
        return left >= right ? left - right : right - left
    }
}

private struct SegmentPreprocessingAdmission: Equatable, Hashable, Sendable {
    let id: UUID
    let kind: DeterministicFMP4Fixture.SegmentKind
    let ordinal: Int
    let countsAsMediaPreprocessing: Bool
}

private struct SegmentCallbackIngress: Equatable, Hashable, Sendable {
    let id: UUID
    let shouldProcess: Bool
}

private final class SegmentCallbackWorker: @unchecked Sendable {
    private enum DrainResult {
        case success
        case failure(DeterministicFMP4Fixture.GenerationError)
    }

    private let lock = NSLock()
    private let assemblyGate: DeterministicFMP4Fixture.SegmentAssemblyGate
    private let targetPresentationEndFrame: Int64
    private let state: GenerationState
    private let closeObserver: DeterministicFMP4Fixture.SegmentWorkerCloseObserver?
    private let lifecycleHook: DeterministicFMP4Fixture.LifecycleHook?

    private var acceptingPreprocessing = true
    private var nextMediaOrdinal = 1
    private var preprocessingAdmissionCount = 0
    private var activeCallbacks: Set<UUID> = []
    private var activePreprocessing: Set<UUID> = []
    private var activePreprocessingWork: Set<UUID> = []
    private var pendingDeliveries: Set<
        DeterministicFMP4Fixture.SegmentDeliveryToken
    > = []
    private var tail: Task<Void, Never>?
    private var closeNotificationTask: Task<Void, Never>?
    private var closeNotificationFinished = true
    private var closeTransitionFinished = true
    private var closeSnapshot: DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot?
    private var firstError: DeterministicFMP4Fixture.GenerationError?
    private var drainContinuation: CheckedContinuation<Void, Error>?
    private var terminalDrainResult: DrainResult?

    init(
        assemblyGate: DeterministicFMP4Fixture.SegmentAssemblyGate,
        targetPresentationEndFrame: Int64,
        state: GenerationState,
        closeObserver: DeterministicFMP4Fixture.SegmentWorkerCloseObserver?,
        lifecycleHook: DeterministicFMP4Fixture.LifecycleHook?
    ) {
        self.assemblyGate = assemblyGate
        self.targetPresentationEndFrame = targetPresentationEndFrame
        self.state = state
        self.closeObserver = closeObserver
        self.lifecycleHook = lifecycleHook
    }

    func startMonitoringAbortState() {
        state.registerAbortHandler { [weak self] error in
            self?.requestClose(for: error)
        }
    }

    func beginCallback() -> SegmentCallbackIngress {
        let id = UUID()
        var postSuccessCloseSnapshot:
            DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot?
        lock.lock()
        activeCallbacks.insert(id)
        if case .success? = terminalDrainResult {
            terminalDrainResult = nil
            acceptingPreprocessing = false
            if firstError == nil { firstError = .writerFailed }
            let snapshot = DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot(
                reason: .validationFailed,
                preprocessingAdmissionCount: preprocessingAdmissionCount,
                activePreprocessingCount: activePreprocessing.count,
                activeCallbackCount: activeCallbacks.count
            )
            closeSnapshot = snapshot
            closeNotificationFinished = lifecycleHook == nil
            closeTransitionFinished = false
            assemblyGate.invalidateForSegmentWorkerClose()
            postSuccessCloseSnapshot = snapshot
        }
        let shouldProcess = acceptingPreprocessing
            && terminalDrainResult == nil
            && closeSnapshot == nil
        lock.unlock()

        if let postSuccessCloseSnapshot {
            publishCloseAfterGatePoison(postSuccessCloseSnapshot)
            _ = state.requestWriterFailure()
        }
        return SegmentCallbackIngress(
            id: id,
            shouldProcess: shouldProcess
        )
    }

    func finishCallback(_ id: UUID) {
        lock.lock()
        activeCallbacks.remove(id)
        lock.unlock()
        signalProgress()
    }

    func beginPreprocessing(
        kind: DeterministicFMP4Fixture.SegmentKind
    ) -> SegmentPreprocessingAdmission? {
        lock.lock()
        guard acceptingPreprocessing, terminalDrainResult == nil else {
            lock.unlock()
            return nil
        }
        let ordinal: Int
        let countsAsMediaPreprocessing: Bool
        switch kind {
        case .initialization:
            ordinal = 0
            countsAsMediaPreprocessing = false
        case .media:
            ordinal = nextMediaOrdinal
            nextMediaOrdinal += 1
            preprocessingAdmissionCount += 1
            countsAsMediaPreprocessing = true
        }
        let admission = SegmentPreprocessingAdmission(
            id: UUID(),
            kind: kind,
            ordinal: ordinal,
            countsAsMediaPreprocessing: countsAsMediaPreprocessing
        )
        activePreprocessingWork.insert(admission.id)
        if countsAsMediaPreprocessing {
            activePreprocessing.insert(admission.id)
        }
        lock.unlock()
        return admission
    }

    func finishPreprocessing(
        _ admission: SegmentPreprocessingAdmission,
        _ observation: DeterministicFMP4Fixture.SegmentCallbackObservation,
        ownedPayload: Data
    ) {
        var beginError: Error?
        lock.lock()
        guard retirePreprocessingLocked(admission) else {
            lock.unlock()
            return
        }
        guard acceptingPreprocessing, terminalDrainResult == nil else {
            lock.unlock()
            signalProgress()
            return
        }
        do {
            let token = try assemblyGate.beginDelivery(
                observation,
                ownedPayload: ownedPayload
            )
            pendingDeliveries.insert(token)
            enqueueDeliveryLocked(token: token, observation: observation)
        } catch {
            beginError = error
        }
        lock.unlock()

        if beginError != nil {
            requestValidationFailure()
        }
        signalProgress()
    }

    func failPreprocessing(_ admission: SegmentPreprocessingAdmission) {
        lock.lock()
        _ = retirePreprocessingLocked(admission)
        lock.unlock()
        requestValidationFailure()
        signalProgress()
    }

    func rejectUnsupportedSegment() {
        requestValidationFailure()
    }

    func drain() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result = terminalDrainResult {
                lock.unlock()
                resume(continuation, with: result)
                return
            }
            guard drainContinuation == nil else {
                lock.unlock()
                continuation.resume(
                    throwing: DeterministicFMP4Fixture.GenerationError.writerFailed
                )
                return
            }
            drainContinuation = continuation
            lock.unlock()
            signalProgress()
        }
    }

    func closeAndDrain(
        for error: DeterministicFMP4Fixture.GenerationError
    ) async {
        requestClose(for: error)
        _ = try? await drain()
    }

    private func requestValidationFailure() {
        requestClose(
            reason: .validationFailed,
            error: .writerFailed
        )
        _ = state.requestWriterFailure()
    }

    private func requestClose(
        for error: DeterministicFMP4Fixture.GenerationError
    ) {
        switch error {
        case .cancelled:
            requestClose(reason: .parentCancelled, error: error)
        case .timedOut:
            requestClose(reason: .timedOut, error: error)
        case .invalidOutputRoot, .writerFailed:
            requestClose(reason: .validationFailed, error: error)
        }
    }

    private func requestClose(
        reason: DeterministicFMP4Fixture.SegmentWorkerCloseReason,
        error: DeterministicFMP4Fixture.GenerationError
    ) {
        let snapshot: DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot
        lock.lock()
        guard closeSnapshot == nil, terminalDrainResult == nil else {
            if firstError == nil { firstError = error }
            lock.unlock()
            signalProgress()
            return
        }
        acceptingPreprocessing = false
        if firstError == nil { firstError = error }
        snapshot = .init(
            reason: reason,
            preprocessingAdmissionCount: preprocessingAdmissionCount,
            activePreprocessingCount: activePreprocessing.count,
            activeCallbackCount: activeCallbacks.count
        )
        closeSnapshot = snapshot
        closeNotificationFinished = lifecycleHook == nil
        closeTransitionFinished = false
        lock.unlock()

        assemblyGate.invalidateForSegmentWorkerClose()
        publishCloseAfterGatePoison(snapshot)
    }

    private func publishCloseAfterGatePoison(
        _ snapshot: DeterministicFMP4Fixture.SegmentWorkerCloseSnapshot
    ) {
        closeObserver?(snapshot)
        lock.lock()
        closeTransitionFinished = true
        lock.unlock()
        if let lifecycleHook {
            let task = Task { [weak self] in
                await lifecycleHook(.segmentWorkerCloseRequested(snapshot))
                self?.closeNotificationDidFinish()
            }
            lock.lock()
            closeNotificationTask = task
            lock.unlock()
        }
        signalProgress()
    }

    private func enqueueDeliveryLocked(
        token: DeterministicFMP4Fixture.SegmentDeliveryToken,
        observation: DeterministicFMP4Fixture.SegmentCallbackObservation
    ) {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            let shouldInvokeHook = withLock {
                closeSnapshot == nil && terminalDrainResult == nil
            }
            if shouldInvokeHook {
                await lifecycleHook?(.segmentCallbackDidStart(observation))
            }
            let shouldComplete = withLock {
                closeSnapshot == nil && terminalDrainResult == nil
            }
            do {
                if shouldComplete {
                    try assemblyGate.completeSegmentWorkerDelivery(token)
                } else {
                    try assemblyGate.abortDelivery(token)
                }
            } catch {
                if shouldComplete {
                    requestValidationFailure()
                }
            }
            withLock {
                _ = pendingDeliveries.remove(token)
            }
            signalProgress()
        }
        tail = task
    }

    private func retirePreprocessingLocked(
        _ admission: SegmentPreprocessingAdmission
    ) -> Bool {
        guard activePreprocessingWork.remove(admission.id) != nil else {
            return false
        }
        if admission.countsAsMediaPreprocessing {
            activePreprocessing.remove(admission.id)
        }
        return true
    }

    private func closeNotificationDidFinish() {
        lock.lock()
        closeNotificationFinished = true
        lock.unlock()
        signalProgress()
    }

    private func signalProgress() {
        var continuation: CheckedContinuation<Void, Error>?
        var result: DrainResult?

        lock.lock()
        guard let waiting = drainContinuation,
            terminalDrainResult == nil
        else {
            lock.unlock()
            return
        }
        let workerJobsSettled = activeCallbacks.isEmpty
            && activePreprocessingWork.isEmpty
            && pendingDeliveries.isEmpty
        let candidate: DrainResult?
        if closeSnapshot != nil {
            candidate = workerJobsSettled
                && closeTransitionFinished
                && closeNotificationFinished
                ? .failure(firstError ?? .writerFailed)
                : nil
        } else {
            let reachedTarget = assemblyGate
                .contiguousCoveredPresentationEndFrame
                >= targetPresentationEndFrame
            candidate = workerJobsSettled
                && assemblyGate.activeDeliveryCount == 0
                && reachedTarget
                ? .success
                : nil
        }
        if let candidate {
            if case .failure = candidate {
                assemblyGate
                    .discardPayloadOwnershipAfterSegmentWorkerFailure()
            }
            acceptingPreprocessing = false
            terminalDrainResult = candidate
            drainContinuation = nil
            continuation = waiting
            result = candidate
        }
        lock.unlock()

        if let continuation, let result {
            resume(continuation, with: result)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: DrainResult
    ) {
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private struct SegmentTiming {
    let startFrame: Int64
    let endFrame: Int64
}

private struct SegmentInitializationTiming {
    let defaultSampleDuration: UInt32?
    let presentationMediaStartFrame: Int64
}

private enum SegmentTimingParser {
    private struct Box {
        let type: String
        let payloadRange: Range<Int>
    }

    static func parseInitialization(
        _ data: Data
    ) throws -> SegmentInitializationTiming {
        guard let moov = try boxes(data, in: data.startIndex..<data.endIndex)
            .first(where: { $0.type == "moov" })
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let mediaStartFrame = try audioPresentationMediaStartFrame(
            in: moov,
            data: data
        )
        guard let mvex = try children(of: moov, data: data)
                .first(where: { $0.type == "mvex" }),
            let trex = try children(of: mvex, data: data)
                .first(where: { $0.type == "trex" })
        else {
            return SegmentInitializationTiming(
                defaultSampleDuration: nil,
                presentationMediaStartFrame: mediaStartFrame
            )
        }
        let header = try fullBoxHeader(trex, data: data, versions: [0])
        _ = header
        let duration = try uint32(
            data,
            at: trex.payloadRange.lowerBound + 12,
            within: trex.payloadRange
        )
        return SegmentInitializationTiming(
            defaultSampleDuration: duration > 0 ? duration : nil,
            presentationMediaStartFrame: mediaStartFrame
        )
    }

    private static func audioPresentationMediaStartFrame(
        in moov: Box,
        data: Data
    ) throws -> Int64 {
        var audioTracks: [(timescale: UInt32, track: Box)] = []
        for track in try children(of: moov, data: data)
            where track.type == "trak"
        {
            guard let media = try children(of: track, data: data)
                .first(where: { $0.type == "mdia" })
            else { continue }
            let mediaChildren = try children(of: media, data: data)
            guard let handler = mediaChildren.first(where: { $0.type == "hdlr" })
            else { continue }
            _ = try fullBoxHeader(handler, data: data, versions: [0])
            let handlerType = try uint32(
                data,
                at: handler.payloadRange.lowerBound + 8,
                within: handler.payloadRange
            )
            guard handlerType == 0x736F_756E else { continue }
            guard let mediaHeader = mediaChildren.first(where: {
                $0.type == "mdhd"
            }) else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let header = try fullBoxHeader(
                mediaHeader,
                data: data,
                versions: [0, 1]
            )
            let timescaleOffset = mediaHeader.payloadRange.lowerBound
                + (header.version == 1 ? 20 : 12)
            let timescale = try uint32(
                data,
                at: timescaleOffset,
                within: mediaHeader.payloadRange
            )
            guard timescale > 0 else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            audioTracks.append((timescale, track))
        }
        guard audioTracks.count == 1,
            audioTracks[0].timescale == 48_000
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let track = audioTracks[0].track
        let editContainers = try children(of: track, data: data)
            .filter { $0.type == "edts" }
        if editContainers.isEmpty { return 0 }
        guard editContainers.count == 1, let editContainer = editContainers.first
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let editLists = try children(of: editContainer, data: data)
            .filter { $0.type == "elst" }
        guard editLists.count == 1, let editList = editLists.first else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let header = try fullBoxHeader(
            editList,
            data: data,
            versions: [0, 1]
        )
        let entryCount = try uint32(
            data,
            at: editList.payloadRange.lowerBound + 4,
            within: editList.payloadRange
        )
        guard entryCount == 1 else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let entryOffset = editList.payloadRange.lowerBound + 8
        let segmentDuration: UInt64
        let mediaTime: Int64
        let rateOffset: Int
        if header.version == 1 {
            segmentDuration = try uint64(
                data,
                at: entryOffset,
                within: editList.payloadRange
            )
            mediaTime = try int64(
                data,
                at: entryOffset + 8,
                within: editList.payloadRange
            )
            rateOffset = entryOffset + 16
        } else {
            segmentDuration = UInt64(
                try uint32(
                    data,
                    at: entryOffset,
                    within: editList.payloadRange
                )
            )
            mediaTime = Int64(
                try int32(
                    data,
                    at: entryOffset + 4,
                    within: editList.payloadRange
                )
            )
            rateOffset = entryOffset + 8
        }
        let rateInteger = try int16(
            data,
            at: rateOffset,
            within: editList.payloadRange
        )
        let rateFraction = try int16(
            data,
            at: rateOffset + 2,
            within: editList.payloadRange
        )
        guard segmentDuration == 0,
            mediaTime >= 0,
            rateInteger == 1,
            rateFraction == 0
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        return mediaTime
    }

    static func parse(
        _ data: Data,
        fallbackDefaultSampleDuration: UInt32?
    ) throws -> SegmentTiming {
        guard let moof = try boxes(data, in: data.startIndex..<data.endIndex)
            .first(where: { $0.type == "moof" })
        else { throw DeterministicFMP4Fixture.GenerationError.writerFailed }
        let trafs = try children(of: moof, data: data).filter { $0.type == "traf" }
        guard trafs.count == 1, let traf = trafs.first else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let entries = try children(of: traf, data: data)
        guard let tfhd = entries.first(where: { $0.type == "tfhd" }),
            let tfdt = entries.first(where: { $0.type == "tfdt" })
        else { throw DeterministicFMP4Fixture.GenerationError.writerFailed }
        let tfhdDefault = try parseTFHDDefaultDuration(tfhd, data: data)
        let defaultDuration = tfhdDefault ?? fallbackDefaultSampleDuration
        let start = try parseTFDT(tfdt, data: data)
        let truns = entries.filter { $0.type == "trun" }
        guard !truns.isEmpty else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        var duration: UInt64 = 0
        for trun in truns {
            let addition = try parseTRUN(
                trun,
                defaultSampleDuration: defaultDuration,
                data: data
            )
            let (sum, overflow) = duration.addingReportingOverflow(addition)
            guard !overflow else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            duration = sum
        }
        let (end, overflow) = start.addingReportingOverflow(duration)
        guard !overflow,
            duration > 0,
            start <= UInt64(Int64.max),
            end <= UInt64(Int64.max)
        else { throw DeterministicFMP4Fixture.GenerationError.writerFailed }
        return SegmentTiming(startFrame: Int64(start), endFrame: Int64(end))
    }

    private static func parseTFHDDefaultDuration(
        _ box: Box,
        data: Data
    ) throws -> UInt32? {
        let header = try fullBoxHeader(box, data: data, versions: [0])
        var cursor = box.payloadRange.lowerBound + 8
        if header.flags & 0x000001 != 0 {
            cursor = try advanced(cursor, by: 8, within: box.payloadRange)
        }
        if header.flags & 0x000002 != 0 {
            cursor = try advanced(cursor, by: 4, within: box.payloadRange)
        }
        guard header.flags & 0x000008 != 0 else { return nil }
        let duration = try uint32(data, at: cursor, within: box.payloadRange)
        return duration > 0 ? duration : nil
    }

    private static func parseTFDT(_ box: Box, data: Data) throws -> UInt64 {
        let header = try fullBoxHeader(box, data: data, versions: [0, 1])
        return header.version == 1
            ? try uint64(
                data,
                at: box.payloadRange.lowerBound + 4,
                within: box.payloadRange
            )
            : UInt64(
                try uint32(
                    data,
                    at: box.payloadRange.lowerBound + 4,
                    within: box.payloadRange
                )
            )
    }

    private static func parseTRUN(
        _ box: Box,
        defaultSampleDuration: UInt32?,
        data: Data
    ) throws -> UInt64 {
        let header = try fullBoxHeader(box, data: data, versions: [0, 1])
        let count = UInt64(
            try uint32(
                data,
                at: box.payloadRange.lowerBound + 4,
                within: box.payloadRange
            )
        )
        guard count > 0, count <= UInt64(Int.max) else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        var cursor = box.payloadRange.lowerBound + 8
        if header.flags & 0x000001 != 0 {
            cursor = try advanced(cursor, by: 4, within: box.payloadRange)
        }
        if header.flags & 0x000004 != 0 {
            cursor = try advanced(cursor, by: 4, within: box.payloadRange)
        }
        let hasDuration = header.flags & 0x000100 != 0
        let bytesPerSample = (hasDuration ? 4 : 0)
            + (header.flags & 0x000200 != 0 ? 4 : 0)
            + (header.flags & 0x000400 != 0 ? 4 : 0)
            + (header.flags & 0x000800 != 0 ? 4 : 0)
        let (requiredBytes, overflow) = Int(count)
            .multipliedReportingOverflow(by: bytesPerSample)
        guard !overflow else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        _ = try advanced(cursor, by: requiredBytes, within: box.payloadRange)

        if !hasDuration {
            guard let defaultSampleDuration, defaultSampleDuration > 0 else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let (total, totalOverflow) = count.multipliedReportingOverflow(
                by: UInt64(defaultSampleDuration)
            )
            guard !totalOverflow else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            return total
        }

        var total: UInt64 = 0
        for _ in 0..<Int(count) {
            let sampleDuration = UInt64(
                try uint32(data, at: cursor, within: box.payloadRange)
            )
            guard sampleDuration > 0 else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let (sum, sumOverflow) = total.addingReportingOverflow(sampleDuration)
            guard !sumOverflow else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            total = sum
            cursor += bytesPerSample
        }
        return total
    }

    private static func children(of box: Box, data: Data) throws -> [Box] {
        try boxes(data, in: box.payloadRange)
    }

    private static func boxes(_ data: Data, in range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let compact = UInt64(
                try uint32(data, at: offset, within: range)
            )
            let typeBytes = try slice(
                data,
                offset: offset + 4,
                count: 4,
                within: range
            )
            guard let type = String(data: typeBytes, encoding: .ascii) else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            var headerSize = 8
            let size: UInt64
            if compact == 0 {
                size = UInt64(range.upperBound - offset)
            } else if compact == 1 {
                headerSize = 16
                size = try uint64(data, at: offset + 8, within: range)
            } else {
                size = compact
            }
            guard size >= UInt64(headerSize),
                size <= UInt64(range.upperBound - offset),
                size <= UInt64(Int.max)
            else { throw DeterministicFMP4Fixture.GenerationError.writerFailed }
            let end = offset + Int(size)
            result.append(
                Box(
                    type: type,
                    payloadRange: (offset + headerSize)..<end
                )
            )
            offset = end
        }
        return result
    }

    private static func fullBoxHeader(
        _ box: Box,
        data: Data,
        versions: Set<UInt8>
    ) throws -> (version: UInt8, flags: UInt32) {
        let full = try uint32(
            data,
            at: box.payloadRange.lowerBound,
            within: box.payloadRange
        )
        let version = UInt8((full >> 24) & 0xFF)
        guard versions.contains(version) else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        return (version, full & 0x00FF_FFFF)
    }

    private static func advanced(
        _ offset: Int,
        by count: Int,
        within range: Range<Int>
    ) throws -> Int {
        guard count >= 0,
            offset >= range.lowerBound,
            offset <= range.upperBound,
            count <= range.upperBound - offset
        else { throw DeterministicFMP4Fixture.GenerationError.writerFailed }
        return offset + count
    }

    private static func uint32(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt32 {
        let bytes = try slice(data, offset: offset, count: 4, within: range)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> UInt64 {
        let bytes = try slice(data, offset: offset, count: 8, within: range)
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func int16(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> Int16 {
        let bytes = try slice(data, offset: offset, count: 2, within: range)
        let value = bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        return Int16(bitPattern: value)
    }

    private static func int32(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> Int32 {
        Int32(bitPattern: try uint32(data, at: offset, within: range))
    }

    private static func int64(
        _ data: Data,
        at offset: Int,
        within range: Range<Int>
    ) throws -> Int64 {
        Int64(bitPattern: try uint64(data, at: offset, within: range))
    }

    private static func slice(
        _ data: Data,
        offset: Int,
        count: Int,
        within range: Range<Int>
    ) throws -> Data.SubSequence {
        guard offset >= range.lowerBound,
            count >= 0,
            offset <= range.upperBound,
            count <= range.upperBound - offset
        else { throw DeterministicFMP4Fixture.GenerationError.writerFailed }
        return data[offset..<(offset + count)]
    }
}

private final class FinishWritingCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var resolved = false
    private var starterInvocationClaimed = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func claimStarterInvocation() -> Bool {
        lock.lock()
        guard !resolved,
            continuation != nil,
            !starterInvocationClaimed
        else {
            lock.unlock()
            return false
        }
        starterInvocationClaimed = true
        lock.unlock()
        return true
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class FinishWritingResolver: @unchecked Sendable {
    private let coordinator: FinishWritingCoordinator

    init(coordinator: FinishWritingCoordinator) {
        self.coordinator = coordinator
    }

    func resolveNormalCompletion() {
        coordinator.resolve(.success(()))
    }

    func resolveAbort(
        _ error: DeterministicFMP4Fixture.GenerationError
    ) {
        coordinator.resolve(.failure(error))
    }
}

private final class GenerationState: @unchecked Sendable {
    private let lock = NSLock()
    private var abort: DeterministicFMP4Fixture.GenerationError?
    private var terminalClaimed = false
    private var abortHandlers: [
        @Sendable (DeterministicFMP4Fixture.GenerationError) -> Void
    ] = []

    func requestCancellation() {
        requestAbort(.cancelled)
    }

    @discardableResult
    func requestTimeout() -> Bool {
        requestAbort(.timedOut)
    }

    @discardableResult
    func requestWriterFailure() -> Bool {
        requestAbort(.writerFailed)
    }

    @discardableResult
    private func requestAbort(
        _ error: DeterministicFMP4Fixture.GenerationError
    ) -> Bool {
        lock.lock()
        guard !terminalClaimed, abort == nil else {
            lock.unlock()
            return false
        }
        abort = error
        let handlers = abortHandlers
        abortHandlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler(error)
        }
        return true
    }

    func registerAbortHandler(
        _ handler: @escaping @Sendable (
            DeterministicFMP4Fixture.GenerationError
        ) -> Void
    ) {
        lock.lock()
        if let abort {
            lock.unlock()
            handler(abort)
            return
        }
        if terminalClaimed {
            lock.unlock()
            return
        }
        abortHandlers.append(handler)
        lock.unlock()
    }

    func abortError() -> DeterministicFMP4Fixture.GenerationError? {
        lock.lock()
        let value = abort
        lock.unlock()
        return value
    }

    func throwIfAborted() throws {
        if let abort = abortError() {
            throw abort
        }
    }

    func claimCompletedTerminal() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminalClaimed else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        if let abort {
            throw abort
        }
        terminalClaimed = true
        abortHandlers.removeAll()
    }

    func claimTerminal() -> Bool {
        lock.lock()
        guard !terminalClaimed else {
            lock.unlock()
            return false
        }
        terminalClaimed = true
        abortHandlers.removeAll()
        lock.unlock()
        return true
    }
}

private final class PCMAssetWriterAppender: @unchecked Sendable {
    private static let sampleRate: Int64 = 48_000
    private static let maximumFramesPerBuffer = 4_096
    private static let peakAmplitude = pow(10.0, -12.0 / 20.0)

    private let input: AVAssetWriterInput
    private let formatDescription: CMAudioFormatDescription
    private let configuration: DeterministicFMP4Fixture.Configuration
    private let state: GenerationState
    private let queue = DispatchQueue(
        label: "com.lovelymusic.debug.deterministic-fixture-writer",
        qos: .userInitiated
    )
    private let completionLock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed = false
    private var nextFrame: Int64 = 0

    init(
        input: AVAssetWriterInput,
        formatDescription: CMAudioFormatDescription,
        configuration: DeterministicFMP4Fixture.Configuration,
        state: GenerationState
    ) {
        self.input = input
        self.formatDescription = formatDescription
        self.configuration = configuration
        self.state = state
    }

    func appendAllSamples() async throws {
        try await withCheckedThrowingContinuation { continuation in
            completionLock.lock()
            self.continuation = continuation
            completionLock.unlock()

            state.registerAbortHandler { [weak self] error in
                self?.queue.async {
                    self?.complete(.failure(error))
                }
            }
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                self?.drainReadyInput()
            }
        }
    }

    private func drainReadyInput() {
        guard !isCompleted else { return }
        while input.isReadyForMoreMediaData, !isCompleted {
            if let abort = state.abortError() {
                complete(.failure(abort))
                return
            }
            let totalFrames = Int64(configuration.durationSeconds * 48_000)
            guard nextFrame < totalFrames else {
                input.markAsFinished()
                complete(.success(()))
                return
            }
            let remaining = totalFrames - nextFrame
            let frameCount = min(Int64(Self.maximumFramesPerBuffer), remaining)
            do {
                let sampleBuffer = try makeSampleBuffer(
                    startingAt: nextFrame,
                    frameCount: Int(frameCount)
                )
                guard input.append(sampleBuffer) else {
                    throw DeterministicFMP4Fixture.GenerationError.writerFailed
                }
                nextFrame += frameCount
            } catch {
                complete(.failure(error))
                return
            }
        }
    }

    private func makeSampleBuffer(
        startingAt frameOffset: Int64,
        frameCount: Int
    ) throws -> CMSampleBuffer {
        var samples = [Float](repeating: 0, count: frameCount)
        let regions = configuration.toneRegions
        for localFrame in samples.indices {
            let globalFrame = frameOffset + Int64(localFrame)
            let seconds = Double(globalFrame) / Double(Self.sampleRate)
            let frequency = regions.first(where: {
                seconds >= $0.startSeconds && seconds < $0.endSeconds
            })?.frequencyHz ?? regions.last?.frequencyHz ?? 440
            samples[localFrame] = Float(
                Self.peakAmplitude
                    * sin(2 * .pi * frequency * Double(globalFrame) / 48_000)
            )
        }

        let (byteCount, byteCountOverflow) = samples.count
            .multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !byteCountOverflow, byteCount > 0 else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let copyStatus = samples.withUnsafeBytes { sampleBytes -> OSStatus in
            guard let baseAddress = sampleBytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: CMTime(
                value: frameOffset,
                timescale: CMTimeScale(Self.sampleRate)
            ),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        return sampleBuffer
    }

    private var isCompleted: Bool {
        completionLock.lock()
        let value = completed
        completionLock.unlock()
        return value
    }

    private func complete(_ result: Result<Void, Error>) {
        completionLock.lock()
        guard !completed, let continuation else {
            completionLock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        completionLock.unlock()
        continuation.resume(with: result)
    }
}

private struct FragmentedMP4Inspection {
    let mediaPayloadBytes: Int
    let layoutProfile: String

    static func inspect(_ data: Data) throws -> FragmentedMP4Inspection {
        let boxes = try MP4TopLevelBox.parseAll(data)
        guard boxes.first?.type == "ftyp",
            boxes.filter({ $0.type == "moov" }).count == 1
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let relevant = boxes.filter {
            ["ftyp", "moov", "moof", "mdat"].contains($0.type)
        }
        guard relevant.count >= 4,
            relevant.first?.type == "ftyp",
            relevant.dropFirst().first?.type == "moov"
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        let media = Array(relevant.dropFirst(2))
        guard media.count.isMultiple(of: 2) else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        var mediaPayloadBytes = 0
        for pairOffset in stride(from: 0, to: media.count, by: 2) {
            guard media.indices.contains(pairOffset),
                media.indices.contains(pairOffset + 1),
                media[pairOffset].type == "moof",
                media[pairOffset + 1].type == "mdat"
            else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let (next, overflow) = mediaPayloadBytes.addingReportingOverflow(
                media[pairOffset + 1].payloadRange.count
            )
            guard !overflow else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            mediaPayloadBytes = next
        }
        guard mediaPayloadBytes > 0 else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        return FragmentedMP4Inspection(
            mediaPayloadBytes: mediaPayloadBytes,
            layoutProfile: "ftyp+moov+(moof+mdat)*"
        )
    }
}

private struct MP4TopLevelBox {
    let type: String
    let payloadRange: Range<Int>

    static func parseAll(_ data: Data) throws -> [MP4TopLevelBox] {
        var boxes: [MP4TopLevelBox] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= 8 else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let compactSize = UInt64(try uint32(data, at: offset))
            let typeData = try slice(data, offset: offset + 4, count: 4)
            guard let type = String(data: typeData, encoding: .ascii) else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let headerSize: Int
            let boxSize: UInt64
            switch compactSize {
            case 0:
                headerSize = 8
                boxSize = UInt64(data.endIndex - offset)
            case 1:
                guard data.endIndex - offset >= 16 else {
                    throw DeterministicFMP4Fixture.GenerationError.writerFailed
                }
                headerSize = 16
                boxSize = try uint64(data, at: offset + 8)
            default:
                headerSize = 8
                boxSize = compactSize
            }
            guard boxSize >= UInt64(headerSize),
                boxSize <= UInt64(data.endIndex - offset),
                boxSize <= UInt64(Int.max)
            else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            let end = offset + Int(boxSize)
            guard end > offset else {
                throw DeterministicFMP4Fixture.GenerationError.writerFailed
            }
            boxes.append(
                MP4TopLevelBox(
                    type: type,
                    payloadRange: (offset + headerSize)..<end
                )
            )
            offset = end
        }
        return boxes
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        let bytes = try slice(data, offset: offset, count: 4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ data: Data, at offset: Int) throws -> UInt64 {
        let bytes = try slice(data, offset: offset, count: 8)
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func slice(
        _ data: Data,
        offset: Int,
        count: Int
    ) throws -> Data.SubSequence {
        guard offset >= data.startIndex,
            count >= 0,
            offset <= data.endIndex,
            count <= data.endIndex - offset
        else {
            throw DeterministicFMP4Fixture.GenerationError.writerFailed
        }
        return data[offset..<(offset + count)]
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func toneScheduleSHA256(_ regions: [ToneRegion]) -> String {
    let canonical = regions.map { region in
        String(
            format: "%.6f-%.6f:%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            region.startSeconds,
            region.endSeconds,
            region.frequencyHz
        )
    }.joined(separator: "\n")
    return sha256Hex(Data(canonical.utf8))
}
#endif
