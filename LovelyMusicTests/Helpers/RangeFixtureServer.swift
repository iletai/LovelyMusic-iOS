import Foundation
import XCTest
@testable import LovelyMusic

enum RangeFixtureBehavior: Sendable {
    case valid206(etag: String)
    case generationProbeError(MediaTransportError.Reason)
    case ignoresRangeWith200
    case malformedContentRange
    case weakETag
    case noValidator
    case expiresAfterRequestCount(Int)
    case changesGenerationAfterRequestCount(Int)
    case stallsAfterBytes(Int64)
    case stallsEveryByteRequestBeforeBody
    case stallsMediaRequestBeforeBody(Int)
    case firstMediaRequestAccountsThenFails(bodyBytes: Int64)
    case redirects(to: URL, approved: Bool)
    case unsatisfied416(totalLength: Int64)
}

enum RangeFixtureEvent: Sendable {
    case generationValidationStarted
    case generationValidationCompleted
    case byteRequestStarted
}

struct RangeFixtureObservation: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let generationValidationCount: Int
    let byteRequestCount: Int
    let mediaStreamInvocationCount: Int
    let requestedHeaderNames: [[String]]
    let requestedRanges: [Range<Int64>?]
    let mediaRequestedRanges: [Range<Int64>?]
    let mediaByteCeilings: [Int64?]
    let generationProbeBodyBytes: Int64
    let mediaResponseBodyBytes: Int64
    let cancellationCount: Int
    let lateCallbackDrainCount: Int
    let servedRangeUnion: [Range<Int64>]
    let validatedChunkCumulativeBodyBytes: [Int64]
    let matchingTokenRequestCount: Int
    let mismatchingTokenRequestCount: Int

    var description: String {
        "RangeFixtureObservation(validations: \(generationValidationCount), "
            + "byteRequests: \(byteRequestCount), streamInvocations: \(mediaStreamInvocationCount), "
            + "headerNames: \(requestedHeaderNames), "
            + "ranges: \(requestedRanges), mediaRanges: \(mediaRequestedRanges), "
            + "mediaCeilings: \(mediaByteCeilings), "
            + "probeBytes: \(generationProbeBodyBytes), "
            + "mediaBytes: \(mediaResponseBodyBytes), cancellations: \(cancellationCount), "
            + "lateDrains: \(lateCallbackDrainCount), servedRanges: \(servedRangeUnion), "
            + "cumulativeBodyBytes: \(validatedChunkCumulativeBodyBytes), "
            + "tokenMatches: \(matchingTokenRequestCount), "
            + "tokenMismatches: \(mismatchingTokenRequestCount))"
    }

    var debugDescription: String { description }
}

/// Deterministic, in-memory media transport for range-loader contract tests.
/// Its observations intentionally omit URLs, header values, validators, media
/// identities, and playback tokens so assertion output cannot expose secrets.
actor RangeFixtureServer: MediaByteTransport {
    typealias EventSink = @Sendable (RangeFixtureEvent) -> Void

    private struct StallWaiter {
        let transportID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct AttemptKey: Hashable {
        let sessionID: PlaybackSessionID
        let sourceAttemptID: SourceAttemptID
    }

    private enum CountWaitKind {
        case stalled
        case cancellation
        case lateDrain
        case byteRequest
    }

    private struct CountWaiter {
        let id: UUID
        let expectedCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let payload: Data
    private let behavior: RangeFixtureBehavior
    private let maximumChunkBytes: Int
    private let eventSink: EventSink
    private let invocationRecorder = RangeFixtureInvocationRecorder()
    private var expectedTokens: ActivePlaybackTokens?

    private var requestCount = 0
    private var generationValidationCount = 0
    private var byteRequestCount = 0
    private var requestedHeaderNames: [[String]] = []
    private var requestedRanges: [Range<Int64>?] = []
    private var mediaRequestedRanges: [Range<Int64>?] = []
    private var mediaByteCeilings: [Int64?] = []
    private var generationProbeBodyBytes: Int64 = 0
    private var mediaResponseBodyBytes: Int64 = 0
    private var didApplyConfiguredStall = false
    private var cancellationCount = 0
    private var lateCallbackDrainCount = 0
    private var servedRanges: [Range<Int64>] = []
    private var cumulativeBodyBytesByAttempt: [AttemptKey: Int64] = [:]
    private var validatedChunkCumulativeBodyBytes: [Int64] = []
    private var matchingTokenRequestCount = 0
    private var mismatchingTokenRequestCount = 0
    private var cancelledTransportIDs: Set<UUID> = []
    private var stalledTransportIDs: Set<UUID> = []
    private var releasesAllStalledRequests = false
    private var stallWaiters: [StallWaiter] = []
    private var stalledCountWaiters: [CountWaiter] = []
    private var cancellationCountWaiters: [CountWaiter] = []
    private var lateDrainCountWaiters: [CountWaiter] = []
    private var byteRequestCountWaiters: [CountWaiter] = []

    init(
        payload: Data,
        behavior: RangeFixtureBehavior,
        maximumChunkBytes: Int = 64 * 1024,
        expectedTokens: ActivePlaybackTokens? = nil,
        eventSink: @escaping EventSink = { _ in }
    ) {
        self.payload = payload
        self.behavior = behavior
        self.maximumChunkBytes = max(1, maximumChunkBytes)
        self.expectedTokens = expectedTokens
        self.eventSink = eventSink
    }

    func validateGeneration(
        for descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> ContentGenerationScope {
        let currentRequestCount = recordRequest(
            descriptor: descriptor,
            range: 0..<1,
            isGenerationValidation: true,
            includesIfRange: false,
            byteCeiling: 1,
            tokens: tokens
        )
        eventSink(.generationValidationStarted)
        let attemptBodyBytes = attemptCumulativeBodyBytes(tokens: tokens)

        switch behavior {
        case .generationProbeError(let reason):
            throw MediaTransportError(
                reason: reason,
                cumulativeResponseBodyBytes: attemptBodyBytes
            )
        case .redirects(_, let approved) where !approved:
            throw MediaTransportError(
                reason: .unapprovedRedirect,
                cumulativeResponseBodyBytes: attemptBodyBytes
            )
        case .expiresAfterRequestCount(let allowedCount)
        where currentRequestCount > allowedCount:
            throw MediaTransportError.unsupportedStatus(
                403,
                cumulativeResponseBodyBytes: attemptBodyBytes
            )
        default:
            break
        }

        guard !payload.isEmpty else {
            throw MediaTransportError(
                reason: .invalidResponse,
                cumulativeResponseBodyBytes: attemptBodyBytes
            )
        }

        generationProbeBodyBytes += 1
        _ = recordAttemptBodyBytes(1, tokens: tokens)
        let scope = generationScope(
            descriptor: descriptor,
            tokens: tokens,
            requestCount: currentRequestCount
        )
        eventSink(.generationValidationCompleted)
        return scope
    }

    nonisolated func bytes(
        for request: MediaByteRequest
    ) -> AsyncThrowingStream<ValidatedMediaChunk, Error> {
        invocationRecorder.record()
        let pair = AsyncThrowingStream.makeStream(
            of: ValidatedMediaChunk.self,
            throwing: Error.self
        )
        let transportID = UUID()

        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.recordCancellation(for: transportID) }
        }
        Task {
            await self.serve(
                request: request,
                transportID: transportID,
                continuation: pair.continuation
            )
        }
        return pair.stream
    }

    func observation() -> RangeFixtureObservation {
        RangeFixtureObservation(
            generationValidationCount: generationValidationCount,
            byteRequestCount: byteRequestCount,
            mediaStreamInvocationCount: invocationRecorder.count,
            requestedHeaderNames: requestedHeaderNames,
            requestedRanges: requestedRanges,
            mediaRequestedRanges: mediaRequestedRanges,
            mediaByteCeilings: mediaByteCeilings,
            generationProbeBodyBytes: generationProbeBodyBytes,
            mediaResponseBodyBytes: mediaResponseBodyBytes,
            cancellationCount: cancellationCount,
            lateCallbackDrainCount: lateCallbackDrainCount,
            servedRangeUnion: merged(servedRanges),
            validatedChunkCumulativeBodyBytes: validatedChunkCumulativeBodyBytes,
            matchingTokenRequestCount: matchingTokenRequestCount,
            mismatchingTokenRequestCount: mismatchingTokenRequestCount
        )
    }

    func expectTokens(
        _ tokens: ActivePlaybackTokens,
        resetObservation: Bool = false
    ) {
        expectedTokens = tokens
        if resetObservation {
            matchingTokenRequestCount = 0
            mismatchingTokenRequestCount = 0
        }
    }

    func waitUntilStalledRequestCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard stalledTransportIDs.count < expectedCount else { return }
        let reached = await waitForCount(expectedCount, kind: .stalled)
        if !reached {
            XCTFail("timed out waiting for stalled range request", file: file, line: line)
        }
    }

    func waitUntilCancellationCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard cancellationCount < expectedCount else { return }
        let reached = await waitForCount(expectedCount, kind: .cancellation)
        if !reached {
            XCTFail("timed out waiting for range cancellation", file: file, line: line)
        }
    }

    func waitUntilLateCallbackDrainCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard lateCallbackDrainCount < expectedCount else { return }
        let reached = await waitForCount(expectedCount, kind: .lateDrain)
        if !reached {
            XCTFail("timed out waiting for late callback drain", file: file, line: line)
        }
    }

    func waitUntilByteRequestCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard byteRequestCount < expectedCount else { return }
        let reached = await waitForCount(expectedCount, kind: .byteRequest)
        if !reached {
            XCTFail("timed out waiting for range byte request", file: file, line: line)
        }
    }

    /// Releases every deterministic transport hold. If a consumer already
    /// cancelled, the producer still attempts one late callback before
    /// draining, which lets loader tests prove stale callbacks are harmless.
    func releaseStalledRequests() {
        releasesAllStalledRequests = true
        let waiters = stallWaiters
        stallWaiters.removeAll()
        waiters.forEach { $0.continuation.resume() }
    }

    private func serve(
        request: MediaByteRequest,
        transportID: UUID,
        continuation: AsyncThrowingStream<ValidatedMediaChunk, Error>.Continuation
    ) async {
        let currentRequestCount = recordRequest(
            descriptor: request.descriptor,
            range: request.range,
            isGenerationValidation: false,
            includesIfRange: request.ifRangeValidator != nil,
            byteCeiling: request.byteCeiling,
            tokens: request.tokens
        )
        let currentMediaRequestCount = byteRequestCount
        eventSink(.byteRequestStarted)
        let attemptBodyBytes = attemptCumulativeBodyBytes(tokens: request.tokens)

        do {
            switch behavior {
            case .ignoresRangeWith200 where request.range?.lowerBound != 0:
                throw MediaTransportError(
                    reason: .rangeIgnored,
                    cumulativeResponseBodyBytes: attemptBodyBytes
                )
            case .malformedContentRange:
                throw MediaTransportError(
                    reason: .invalidContentRange,
                    cumulativeResponseBodyBytes: attemptBodyBytes
                )
            case .redirects(_, let approved) where !approved:
                throw MediaTransportError(
                    reason: .unapprovedRedirect,
                    cumulativeResponseBodyBytes: attemptBodyBytes
                )
            case .expiresAfterRequestCount(let allowedCount)
            where currentRequestCount > allowedCount:
                throw MediaTransportError.unsupportedStatus(
                    403,
                    cumulativeResponseBodyBytes: attemptBodyBytes
                )
            case .unsatisfied416(let totalLength):
                throw MediaTransportError.endOfResource(
                    totalLength: totalLength,
                    cumulativeResponseBodyBytes: attemptBodyBytes
                )
            default:
                break
            }

            let requestedRange = request.range ?? 0..<Int64(payload.count)
            guard requestedRange.lowerBound >= 0,
                requestedRange.upperBound >= requestedRange.lowerBound
            else {
                throw MediaTransportError(
                    reason: .invalidRequest,
                    cumulativeResponseBodyBytes: attemptBodyBytes
                )
            }
            guard requestedRange.lowerBound < Int64(payload.count) else {
                throw MediaTransportError.endOfResource(
                    totalLength: Int64(payload.count),
                    cumulativeResponseBodyBytes: attemptBodyBytes
                )
            }

            let upperBound = min(requestedRange.upperBound, Int64(payload.count))
            let scope = generationScope(
                descriptor: request.descriptor,
                tokens: request.tokens,
                requestCount: currentRequestCount
            )
            var offset = requestedRange.lowerBound
            var requestBodyBytes: Int64 = 0
            var didHold = false

            if case .firstMediaRequestAccountsThenFails(let bodyBytes) = behavior,
                currentMediaRequestCount == 1
            {
                let accountedBytes = min(
                    max(0, bodyBytes),
                    request.byteCeiling ?? max(0, bodyBytes),
                    upperBound - requestedRange.lowerBound
                )
                if accountedBytes > 0 {
                    mediaResponseBodyBytes += accountedBytes
                    servedRanges.append(
                        requestedRange.lowerBound..<(requestedRange.lowerBound + accountedBytes)
                    )
                }
                let cumulativeBodyBytes = recordAttemptBodyBytes(
                    accountedBytes,
                    tokens: request.tokens
                )
                throw MediaTransportError(
                    reason: .transportFailure,
                    cumulativeResponseBodyBytes: cumulativeBodyBytes
                )
            }

            if shouldHoldBeforeBody(mediaRequestCount: currentMediaRequestCount) {
                didHold = true
                await holdTransport(transportID)
                if cancelledTransportIDs.contains(transportID) {
                    let lateEnd = min(
                        upperBound,
                        offset + Int64(maximumChunkBytes)
                    )
                    if lateEnd > offset {
                        let lateRange = offset..<lateEnd
                        let lateData = payload.subdata(
                            in: Int(lateRange.lowerBound)..<Int(lateRange.upperBound)
                        )
                        mediaResponseBodyBytes += Int64(lateData.count)
                        servedRanges.append(lateRange)
                        let lateCumulativeBodyBytes = recordAttemptBodyBytes(
                            Int64(lateData.count),
                            tokens: request.tokens
                        )
                        validatedChunkCumulativeBodyBytes.append(
                            lateCumulativeBodyBytes
                        )
                        _ = continuation.yield(
                            ValidatedMediaChunk(
                                absoluteRange: lateRange,
                                payload: lateData,
                                generationScope: scope,
                                cumulativeResponseBodyBytes: lateCumulativeBodyBytes
                            )
                        )
                    }
                    markLateCallbackDrained(transportID)
                    continuation.finish(throwing: CancellationError())
                    return
                }
            }

            while offset < upperBound {
                let desiredChunkEnd = min(
                    upperBound,
                    offset + Int64(maximumChunkBytes)
                )
                let ceilingEnd = request.byteCeiling.map {
                    requestedRange.lowerBound + $0
                }
                let chunkEnd = min(desiredChunkEnd, ceilingEnd ?? desiredChunkEnd)
                guard chunkEnd > offset else {
                    throw MediaTransportError.byteCeilingExceeded(
                        ceiling: request.byteCeiling ?? 0,
                        cumulativeResponseBodyBytes: attemptCumulativeBodyBytes(
                            tokens: request.tokens
                        )
                    )
                }

                let absoluteRange = offset..<chunkEnd
                let data = payload.subdata(
                    in: Int(absoluteRange.lowerBound)..<Int(absoluteRange.upperBound)
                )
                mediaResponseBodyBytes += Int64(data.count)
                requestBodyBytes += Int64(data.count)
                servedRanges.append(absoluteRange)
                let cumulativeBodyBytes = recordAttemptBodyBytes(
                    Int64(data.count),
                    tokens: request.tokens
                )
                validatedChunkCumulativeBodyBytes.append(cumulativeBodyBytes)
                continuation.yield(
                    ValidatedMediaChunk(
                        absoluteRange: absoluteRange,
                        payload: data,
                        generationScope: scope,
                        cumulativeResponseBodyBytes: cumulativeBodyBytes
                    )
                )
                offset = chunkEnd

                if claimConfiguredStall(afterMediaBytes: requestBodyBytes) {
                    didHold = true
                    await holdTransport(transportID)
                    if cancelledTransportIDs.contains(transportID) {
                        let lateRange: Range<Int64>
                        if offset < upperBound {
                            lateRange = offset..<min(
                                upperBound,
                                offset + Int64(maximumChunkBytes)
                            )
                        } else {
                            let lateStart = max(
                                requestedRange.lowerBound,
                                offset - Int64(maximumChunkBytes)
                            )
                            lateRange = lateStart..<offset
                        }
                        if !lateRange.isEmpty {
                            let lateData = payload.subdata(
                                in: Int(lateRange.lowerBound)..<Int(lateRange.upperBound)
                            )
                            mediaResponseBodyBytes += Int64(lateData.count)
                            servedRanges.append(lateRange)
                            let lateCumulativeBodyBytes = recordAttemptBodyBytes(
                                Int64(lateData.count),
                                tokens: request.tokens
                            )
                            validatedChunkCumulativeBodyBytes.append(
                                lateCumulativeBodyBytes
                            )
                            _ = continuation.yield(
                                ValidatedMediaChunk(
                                    absoluteRange: lateRange,
                                    payload: lateData,
                                    generationScope: scope,
                                    cumulativeResponseBodyBytes: lateCumulativeBodyBytes
                                )
                            )
                        }
                        markLateCallbackDrained(transportID)
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                }
            }

            if didHold {
                markLateCallbackDrained(transportID)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    @discardableResult
    private func recordRequest(
        descriptor: StreamDescriptor,
        range: Range<Int64>?,
        isGenerationValidation: Bool,
        includesIfRange: Bool,
        byteCeiling: Int64?,
        tokens: ActivePlaybackTokens
    ) -> Int {
        requestCount += 1
        if isGenerationValidation {
            generationValidationCount += 1
        } else {
            byteRequestCount += 1
            mediaRequestedRanges.append(range)
            mediaByteCeilings.append(byteCeiling)
        }

        if let expectedTokens {
            if expectedTokens == tokens {
                matchingTokenRequestCount += 1
            } else {
                mismatchingTokenRequestCount += 1
            }
        }

        var names = descriptor.requestHeaders.keys.map { $0.lowercased() }
        names.append("accept-encoding")
        if range != nil { names.append("range") }
        if includesIfRange { names.append("if-range") }
        requestedHeaderNames.append(Array(Set(names)).sorted())
        requestedRanges.append(range)
        resumeByteRequestWaitersIfReady()
        return requestCount
    }

    private func generationScope(
        descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens,
        requestCount: Int
    ) -> ContentGenerationScope {
        let totalLength = Int64(payload.count)
        switch behavior {
        case .weakETag, .noValidator:
            return .attemptOnly(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                totalLength: totalLength
            )
        case .valid206(let etag) where etag.hasPrefix("W/"):
            return .attemptOnly(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                totalLength: totalLength
            )
        case .valid206(let etag):
            return .persistent(
                ValidatedContentGeneration(
                    provisionalKey: descriptor.provisionalResourceKey,
                    totalLength: totalLength,
                    strongValidator: etag
                )
            )
        case .changesGenerationAfterRequestCount(let threshold):
            let validator = requestCount > threshold
                ? "\"fixture-generation-b\""
                : "\"fixture-generation-a\""
            return .persistent(
                ValidatedContentGeneration(
                    provisionalKey: descriptor.provisionalResourceKey,
                    totalLength: totalLength,
                    strongValidator: validator
                )
            )
        default:
            return .persistent(
                ValidatedContentGeneration(
                    provisionalKey: descriptor.provisionalResourceKey,
                    totalLength: totalLength,
                    strongValidator: "\"fixture-generation-a\""
                )
            )
        }
    }

    private func claimConfiguredStall(afterMediaBytes bodyBytes: Int64) -> Bool {
        guard case .stallsAfterBytes(let threshold) = behavior else {
            return false
        }
        guard !didApplyConfiguredStall, bodyBytes >= threshold else {
            return false
        }
        didApplyConfiguredStall = true
        return true
    }

    private func shouldHoldBeforeBody(mediaRequestCount: Int) -> Bool {
        switch behavior {
        case .stallsEveryByteRequestBeforeBody:
            return true
        case .stallsMediaRequestBeforeBody(let expectedRequest):
            return mediaRequestCount == expectedRequest
        case .firstMediaRequestAccountsThenFails(_) where mediaRequestCount > 1:
            return true
        default:
            return claimConfiguredStall(afterMediaBytes: 0)
        }
    }

    private func holdTransport(_ transportID: UUID) async {
        stalledTransportIDs.insert(transportID)
        resumeStalledCountWaitersIfReady()
        if releasesAllStalledRequests {
            stalledTransportIDs.remove(transportID)
            return
        }
        await withCheckedContinuation { continuation in
            if releasesAllStalledRequests {
                continuation.resume()
            } else {
                stallWaiters.append(
                    StallWaiter(
                        transportID: transportID,
                        continuation: continuation
                    )
                )
            }
        }
        stalledTransportIDs.remove(transportID)
    }

    private func recordCancellation(for transportID: UUID) {
        guard cancelledTransportIDs.insert(transportID).inserted else { return }
        cancellationCount += 1
        resumeCancellationCountWaitersIfReady()
    }

    private func markLateCallbackDrained(_ transportID: UUID) {
        guard cancelledTransportIDs.contains(transportID) else { return }
        lateCallbackDrainCount += 1
        resumeLateDrainWaitersIfReady()
    }

    private func waitForCount(
        _ expectedCount: Int,
        kind: CountWaitKind
    ) async -> Bool {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let waiter = CountWaiter(
                id: waiterID,
                expectedCount: expectedCount,
                continuation: continuation
            )
            switch kind {
            case .stalled:
                stalledCountWaiters.append(waiter)
            case .cancellation:
                cancellationCountWaiters.append(waiter)
            case .lateDrain:
                lateDrainCountWaiters.append(waiter)
            case .byteRequest:
                byteRequestCountWaiters.append(waiter)
            }
            // Timeout is a failure-only escape hatch; readiness always comes
            // from the named continuation milestone above.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.expireCountWaiter(waiterID, kind: kind)
            }
        }
    }

    private func expireCountWaiter(_ waiterID: UUID, kind: CountWaitKind) {
        let waiter: CountWaiter?
        switch kind {
        case .stalled:
            waiter = removeCountWaiter(waiterID, from: &stalledCountWaiters)
        case .cancellation:
            waiter = removeCountWaiter(waiterID, from: &cancellationCountWaiters)
        case .lateDrain:
            waiter = removeCountWaiter(waiterID, from: &lateDrainCountWaiters)
        case .byteRequest:
            waiter = removeCountWaiter(waiterID, from: &byteRequestCountWaiters)
        }
        waiter?.continuation.resume(returning: false)
    }

    private func removeCountWaiter(
        _ waiterID: UUID,
        from waiters: inout [CountWaiter]
    ) -> CountWaiter? {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return nil
        }
        return waiters.remove(at: index)
    }

    private func resumeStalledCountWaitersIfReady() {
        let ready = stalledCountWaiters.filter {
            stalledTransportIDs.count >= $0.expectedCount
        }
        stalledCountWaiters.removeAll {
            stalledTransportIDs.count >= $0.expectedCount
        }
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    private func resumeCancellationCountWaitersIfReady() {
        let ready = cancellationCountWaiters.filter {
            cancellationCount >= $0.expectedCount
        }
        cancellationCountWaiters.removeAll {
            cancellationCount >= $0.expectedCount
        }
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    private func resumeLateDrainWaitersIfReady() {
        let ready = lateDrainCountWaiters.filter {
            lateCallbackDrainCount >= $0.expectedCount
        }
        lateDrainCountWaiters.removeAll {
            lateCallbackDrainCount >= $0.expectedCount
        }
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    private func resumeByteRequestWaitersIfReady() {
        let ready = byteRequestCountWaiters.filter {
            byteRequestCount >= $0.expectedCount
        }
        byteRequestCountWaiters.removeAll {
            byteRequestCount >= $0.expectedCount
        }
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    private func merged(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        let sorted = ranges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
        return sorted.reduce(into: []) { result, range in
            guard let last = result.last, range.lowerBound <= last.upperBound else {
                result.append(range)
                return
            }
            _ = result.removeLast()
            result.append(
                last.lowerBound..<max(last.upperBound, range.upperBound)
            )
        }
    }

    private func recordAttemptBodyBytes(
        _ byteCount: Int64,
        tokens: ActivePlaybackTokens
    ) -> Int64 {
        let key = AttemptKey(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id
        )
        let cumulative = (cumulativeBodyBytesByAttempt[key] ?? 0) + byteCount
        cumulativeBodyBytesByAttempt[key] = cumulative
        return cumulative
    }

    private func attemptCumulativeBodyBytes(
        tokens: ActivePlaybackTokens
    ) -> Int64 {
        let key = AttemptKey(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id
        )
        return cumulativeBodyBytesByAttempt[key] ?? 0
    }
}

private final class RangeFixtureInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    var count: Int {
        lock.withLock { invocationCount }
    }

    func record() {
        lock.withLock { invocationCount += 1 }
    }
}
