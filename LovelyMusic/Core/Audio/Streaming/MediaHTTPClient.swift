import Foundation

enum MediaRequestPurpose: String, Sendable {
    case generationProbe
    case initialization
    case index
    case media
    case retry
}

struct MediaByteRequest: Sendable, CustomStringConvertible {
    let descriptor: StreamDescriptor
    let range: Range<Int64>?
    let ifRangeValidator: String?
    let purpose: MediaRequestPurpose
    let byteCeiling: Int64?
    let tokens: ActivePlaybackTokens

    /// Deliberately excludes the signed URL, headers, media identity, and tokens.
    var description: String {
        "MediaByteRequest(purpose: \(purpose.rawValue), ranged: \(range != nil))"
    }
}

struct ValidatedMediaChunk: Sendable {
    let absoluteRange: Range<Int64>
    let payload: Data
    let generationScope: ContentGenerationScope
    let cumulativeResponseBodyBytes: Int64
}

protocol MediaByteTransport: Sendable {
    func validateGeneration(
        for descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> ContentGenerationScope

    func bytes(
        for request: MediaByteRequest
    ) -> AsyncThrowingStream<ValidatedMediaChunk, Error>
}

struct MediaApprovedOrigin: Sendable {
    let origin: URL
    let headers: [String: String]
}

struct MediaRedirectPolicy: Sendable {
    private let approvedHeaders: [MediaOrigin: [String: String]]

    init(approvedOrigins: [MediaApprovedOrigin]) {
        approvedHeaders = approvedOrigins.reduce(into: [:]) { result, approval in
            guard let origin = MediaOrigin(secureURL: approval.origin) else { return }
            result[origin] = approval.headers
        }
    }

    fileprivate func approves(_ url: URL) -> Bool {
        guard let origin = MediaOrigin(secureURL: url) else { return false }
        return approvedHeaders[origin] != nil
    }

    fileprivate func redirectedRequest(
        from currentRequest: URLRequest,
        to targetURL: URL
    ) throws -> URLRequest {
        guard targetURL.user == nil,
            targetURL.password == nil,
            targetURL.fragment == nil,
            let sourceURL = currentRequest.url,
            let sourceOrigin = MediaOrigin(secureURL: sourceURL),
            let targetOrigin = MediaOrigin(secureURL: targetURL),
            let targetHeaders = approvedHeaders[targetOrigin]
        else {
            throw MediaTransportError.unapprovedRedirect
        }

        if sourceOrigin == targetOrigin {
            var redirected = currentRequest
            redirected.url = targetURL
            return redirected
        }

        var redirected = URLRequest(
            url: targetURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: currentRequest.timeoutInterval
        )
        redirected.httpMethod = currentRequest.httpMethod
        redirected.httpShouldHandleCookies = false

        for (name, value) in targetHeaders {
            redirected.setValue(value, forHTTPHeaderField: name)
        }

        // These are range-transport controls, not origin identity headers.
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        redirected.setValue(
            currentRequest.value(forHTTPHeaderField: "Range"),
            forHTTPHeaderField: "Range"
        )
        redirected.setValue(
            currentRequest.value(forHTTPHeaderField: "If-Range"),
            forHTTPHeaderField: "If-Range"
        )
        return redirected
    }
}

struct MediaTransportDiagnostic: Sendable, CustomStringConvertible {
    enum Family: String, Sendable {
        case request
        case response
        case contentEncoding
        case generation
        case playbackControl
        case byteCeiling
        case backpressure
        case redirect
        case transport
        case cancellation
    }

    let family: Family
    let statusCode: Int?
    let cumulativeResponseBodyBytes: Int64

    var description: String {
        var message = "media_transport family=\(family.rawValue)"
        if let statusCode {
            message += " status=\(statusCode)"
        }
        message += " response_body_bytes=\(cumulativeResponseBodyBytes)"
        return message
    }
}

struct MediaTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Reason: Equatable, Sendable {
        case invalidRequest
        case invalidResponse
        case rangeIgnored
        case invalidContentRange
        case transformedContentEncoding
        case endOfResource(totalLength: Int64)
        case generationChanged
        case staleKillSwitchEpoch
        case killSwitchEnabled
        case stalePlaybackTokens
        case byteCeilingExceeded(ceiling: Int64)
        case backpressureExceeded(maximumBufferedChunks: Int)
        case unapprovedRedirect
        case unsupportedStatus(Int)
        case transportFailure
        case cancelled
    }

    let reason: Reason
    let cumulativeResponseBodyBytes: Int64

    static let invalidRequest = Self(reason: .invalidRequest, cumulativeResponseBodyBytes: 0)
    static let invalidResponse = Self(reason: .invalidResponse, cumulativeResponseBodyBytes: 0)
    static let rangeIgnored = Self(reason: .rangeIgnored, cumulativeResponseBodyBytes: 0)
    static let invalidContentRange = Self(
        reason: .invalidContentRange,
        cumulativeResponseBodyBytes: 0
    )
    static let transformedContentEncoding = Self(
        reason: .transformedContentEncoding,
        cumulativeResponseBodyBytes: 0
    )
    static let generationChanged = Self(
        reason: .generationChanged,
        cumulativeResponseBodyBytes: 0
    )
    static let staleKillSwitchEpoch = Self(
        reason: .staleKillSwitchEpoch,
        cumulativeResponseBodyBytes: 0
    )
    static let killSwitchEnabled = Self(
        reason: .killSwitchEnabled,
        cumulativeResponseBodyBytes: 0
    )
    static let stalePlaybackTokens = Self(
        reason: .stalePlaybackTokens,
        cumulativeResponseBodyBytes: 0
    )
    static let unapprovedRedirect = Self(
        reason: .unapprovedRedirect,
        cumulativeResponseBodyBytes: 0
    )
    static let cancelled = Self(reason: .cancelled, cumulativeResponseBodyBytes: 0)

    static func endOfResource(
        totalLength: Int64,
        cumulativeResponseBodyBytes: Int64
    ) -> Self {
        Self(
            reason: .endOfResource(totalLength: totalLength),
            cumulativeResponseBodyBytes: cumulativeResponseBodyBytes
        )
    }

    static func byteCeilingExceeded(
        ceiling: Int64,
        cumulativeResponseBodyBytes: Int64
    ) -> Self {
        Self(
            reason: .byteCeilingExceeded(ceiling: ceiling),
            cumulativeResponseBodyBytes: cumulativeResponseBodyBytes
        )
    }

    static func backpressureExceeded(
        maximumBufferedChunks: Int,
        cumulativeResponseBodyBytes: Int64
    ) -> Self {
        Self(
            reason: .backpressureExceeded(maximumBufferedChunks: maximumBufferedChunks),
            cumulativeResponseBodyBytes: cumulativeResponseBodyBytes
        )
    }

    static func unsupportedStatus(
        _ statusCode: Int,
        cumulativeResponseBodyBytes: Int64
    ) -> Self {
        Self(
            reason: .unsupportedStatus(statusCode),
            cumulativeResponseBodyBytes: cumulativeResponseBodyBytes
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reason == rhs.reason
    }

    var description: String {
        "MediaTransportError(reason: \(safeReason), responseBodyBytes: \(cumulativeResponseBodyBytes))"
    }

    fileprivate func accounting(_ bytes: Int64) -> Self {
        Self(reason: reason, cumulativeResponseBodyBytes: bytes)
    }

    fileprivate var diagnosticFamily: MediaTransportDiagnostic.Family {
        switch reason {
        case .invalidRequest:
            return .request
        case .invalidResponse, .rangeIgnored, .invalidContentRange, .endOfResource,
            .unsupportedStatus:
            return .response
        case .transformedContentEncoding:
            return .contentEncoding
        case .generationChanged:
            return .generation
        case .staleKillSwitchEpoch, .killSwitchEnabled, .stalePlaybackTokens:
            return .playbackControl
        case .byteCeilingExceeded:
            return .byteCeiling
        case .backpressureExceeded:
            return .backpressure
        case .unapprovedRedirect:
            return .redirect
        case .transportFailure:
            return .transport
        case .cancelled:
            return .cancellation
        }
    }

    fileprivate var statusCode: Int? {
        guard case .unsupportedStatus(let statusCode) = reason else { return nil }
        return statusCode
    }

    private var safeReason: String {
        switch reason {
        case .invalidRequest: return "invalid_request"
        case .invalidResponse: return "invalid_response"
        case .rangeIgnored: return "range_ignored"
        case .invalidContentRange: return "invalid_content_range"
        case .transformedContentEncoding: return "transformed_content_encoding"
        case .endOfResource: return "end_of_resource"
        case .generationChanged: return "generation_changed"
        case .staleKillSwitchEpoch: return "stale_kill_switch_epoch"
        case .killSwitchEnabled: return "kill_switch_enabled"
        case .stalePlaybackTokens: return "stale_playback_tokens"
        case .byteCeilingExceeded: return "byte_ceiling_exceeded"
        case .backpressureExceeded: return "backpressure_exceeded"
        case .unapprovedRedirect: return "unapproved_redirect"
        case .unsupportedStatus: return "unsupported_status"
        case .transportFailure: return "transport_failure"
        case .cancelled: return "cancelled"
        }
    }
}

/// Owns all media sessions and never shares system-managed cookie, credential,
/// or cache state. The configuration reference is immutable after init and
/// Foundation copies it for each session; request/generation state is lock-owned.
final class MediaHTTPClient: MediaByteTransport, @unchecked Sendable {
    static let maximumBufferedChunkCount = 4

    private let configuration: URLSessionConfiguration
    private let redirectPolicy: MediaRedirectPolicy
    private let authorizedKillSwitchEpoch: UInt64
    private let featureSnapshot: @Sendable () -> PlaybackFeatureSnapshot
    private let tokenValidator: @Sendable (ActivePlaybackTokens) -> Bool
    private let maximumChunkBytes: Int
    private let receivedBodyByteCount: @Sendable (URLSessionTask) -> Int64
    private let resourceObserver: @Sendable (URLSession, URLSessionDataTask) -> Void
    private let diagnosticSink: @Sendable (MediaTransportDiagnostic) -> Void
    private let ledger = MediaAttemptLedger()

    init(
        configuration: URLSessionConfiguration,
        redirectPolicy: MediaRedirectPolicy,
        authorizedKillSwitchEpoch: UInt64,
        featureSnapshot: @escaping @Sendable () -> PlaybackFeatureSnapshot,
        tokenValidator: @escaping @Sendable (ActivePlaybackTokens) -> Bool,
        maximumChunkBytes: Int = 64 * 1024,
        receivedBodyByteCount: @escaping @Sendable (URLSessionTask) -> Int64 = {
            $0.countOfBytesReceived
        },
        resourceObserver: @escaping @Sendable (URLSession, URLSessionDataTask) -> Void = {
            _, _ in
        },
        diagnosticSink: @escaping @Sendable (MediaTransportDiagnostic) -> Void = { _ in }
    ) {
        self.configuration = Self.isolatedConfiguration(copying: configuration)
        self.redirectPolicy = redirectPolicy
        self.authorizedKillSwitchEpoch = authorizedKillSwitchEpoch
        self.featureSnapshot = featureSnapshot
        self.tokenValidator = tokenValidator
        self.maximumChunkBytes = max(1, maximumChunkBytes)
        self.receivedBodyByteCount = receivedBodyByteCount
        self.resourceObserver = resourceObserver
        self.diagnosticSink = diagnosticSink
    }

    static func productionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        configuration.protocolClasses = nil
        return configuration
    }

    static func testingConfiguration(
        protocolClass: AnyClass
    ) -> URLSessionConfiguration {
        let configuration = productionConfiguration()
        configuration.protocolClasses = [protocolClass]
        return configuration
    }

    func validateGeneration(
        for descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens
    ) async throws -> ContentGenerationScope {
        let request = MediaByteRequest(
            descriptor: descriptor,
            range: 0..<1,
            ifRangeValidator: nil,
            purpose: .generationProbe,
            byteCeiling: 1,
            tokens: tokens
        )
        var validatedScope: ContentGenerationScope?
        var exposedBytes: Int64 = 0

        for try await chunk in bytes(for: request) {
            exposedBytes = exposedBytes.addingClamped(Int64(chunk.payload.count))
            validatedScope = chunk.generationScope
        }

        guard exposedBytes == 1, let validatedScope else {
            let error = MediaTransportError.invalidResponse.accounting(
                ledger.cumulativeBytes(for: tokens)
            )
            emit(error)
            throw error
        }
        return validatedScope
    }

    func bytes(
        for request: MediaByteRequest
    ) -> AsyncThrowingStream<ValidatedMediaChunk, Error> {
        let pair = AsyncThrowingStream.makeStream(
            of: ValidatedMediaChunk.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedChunkCount)
        )
        let operation = MediaRequestOperation(
            request: request,
            configuration: configuration,
            redirectPolicy: redirectPolicy,
            authorizedKillSwitchEpoch: authorizedKillSwitchEpoch,
            featureSnapshot: featureSnapshot,
            tokenValidator: tokenValidator,
            maximumChunkBytes: maximumChunkBytes,
            receivedBodyByteCount: receivedBodyByteCount,
            ledger: ledger,
            continuation: pair.continuation,
            resourceObserver: resourceObserver,
            diagnosticSink: diagnosticSink
        )
        pair.continuation.onTermination = { [weak operation] termination in
            if case .cancelled = termination {
                operation?.cancelFromConsumer()
            }
        }
        operation.start()
        return pair.stream
    }

    private func emit(_ error: MediaTransportError) {
        diagnosticSink(
            MediaTransportDiagnostic(
                family: error.diagnosticFamily,
                statusCode: error.statusCode,
                cumulativeResponseBodyBytes: error.cumulativeResponseBodyBytes
            )
        )
    }

    private static func isolatedConfiguration(
        copying supplied: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        let isolated = (supplied.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.ephemeral
        isolated.urlCache = nil
        isolated.httpCookieStorage = nil
        isolated.urlCredentialStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.httpCookieAcceptPolicy = .never
        isolated.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        isolated.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return isolated
    }
}

private struct MediaOrigin: Hashable, Sendable {
    let host: String
    let port: Int

    init?(secureURL: URL) {
        guard secureURL.scheme?.lowercased() == "https",
            let normalizedHost = secureURL.host?.lowercased(),
            !normalizedHost.isEmpty
        else {
            return nil
        }
        host = normalizedHost
        port = secureURL.port ?? 443
    }
}

fileprivate struct MediaAttemptKey: Hashable, Sendable {
    let sessionID: PlaybackSessionID
    let sourceAttemptID: SourceAttemptID

    init(tokens: ActivePlaybackTokens) {
        sessionID = tokens.sessionID
        sourceAttemptID = tokens.currentSourceAttempt.id
    }
}

struct MediaGenerationLease: Sendable {
    fileprivate let id: UUID
    fileprivate let key: MediaAttemptKey
    let scope: ContentGenerationScope
}

final class MediaAttemptLedger: @unchecked Sendable {
    private enum Generation: Equatable {
        case persistent(
            provisionalKey: ProvisionalResourceKey,
            totalLength: Int64,
            validator: String
        )
        case attemptOnly(
            provisionalKey: ProvisionalResourceKey,
            totalLength: Int64,
            observedStrongValidator: String?
        )

        var provisionalKey: ProvisionalResourceKey {
            switch self {
            case .persistent(let provisionalKey, _, _),
                .attemptOnly(let provisionalKey, _, _):
                return provisionalKey
            }
        }

        var totalLength: Int64 {
            switch self {
            case .persistent(_, let totalLength, _),
                .attemptOnly(_, let totalLength, _):
                return totalLength
            }
        }

        var strongValidator: String? {
            switch self {
            case .persistent(_, _, let validator):
                return validator
            case .attemptOnly(_, _, let observedStrongValidator):
                return observedStrongValidator
            }
        }
    }

    private struct AttemptState {
        var cumulativeBytes: Int64 = 0
        var generation: Generation?
        var pendingGenerations: [UUID: Generation] = [:]
        var pendingGenerationOrder: [UUID] = []
    }

    private let lock = NSLock()
    private var attempts: [MediaAttemptKey: AttemptState] = [:]

    func account(_ count: Int64, for tokens: ActivePlaybackTokens) -> Int64 {
        lock.withLock {
            let key = MediaAttemptKey(tokens: tokens)
            var state = attempts[key, default: AttemptState()]
            state.cumulativeBytes = state.cumulativeBytes.addingClamped(count)
            attempts[key] = state
            return state.cumulativeBytes
        }
    }

    func cumulativeBytes(for tokens: ActivePlaybackTokens) -> Int64 {
        lock.withLock {
            attempts[MediaAttemptKey(tokens: tokens)]?.cumulativeBytes ?? 0
        }
    }

    func expectedTotalLength(for tokens: ActivePlaybackTokens) -> Int64? {
        lock.withLock {
            guard let state = attempts[MediaAttemptKey(tokens: tokens)] else {
                return nil
            }
            return state.generation?.totalLength
                ?? state.pendingGenerations.values.first?.totalLength
        }
    }

    func authoritativeStrongValidator(for tokens: ActivePlaybackTokens) -> String? {
        lock.withLock {
            attempts[MediaAttemptKey(tokens: tokens)]?.generation?.strongValidator
        }
    }

    func beginGeneration(
        totalLength: Int64,
        etag: String?,
        descriptor: StreamDescriptor,
        tokens: ActivePlaybackTokens,
        allowPersistent: Bool
    ) -> Result<MediaGenerationLease, MediaTransportError> {
        lock.withLock {
            let key = MediaAttemptKey(tokens: tokens)
            var state = attempts[key, default: AttemptState()]
            let strongValidator = etag.flatMap(Self.strongValidator)

            let proposed: Generation = if allowPersistent, let strongValidator {
                .persistent(
                    provisionalKey: descriptor.provisionalResourceKey,
                    totalLength: totalLength,
                    validator: strongValidator
                )
            } else {
                .attemptOnly(
                    provisionalKey: descriptor.provisionalResourceKey,
                    totalLength: totalLength,
                    observedStrongValidator: strongValidator
                )
            }

            var canonical = proposed
            if let committed = state.generation {
                guard let merged = Self.merging(committed, with: canonical) else {
                    return .failure(.generationChanged)
                }
                canonical = merged
            }
            for pendingID in state.pendingGenerationOrder {
                guard let pending = state.pendingGenerations[pendingID],
                    let merged = Self.merging(pending, with: canonical)
                else {
                    return .failure(.generationChanged)
                }
                canonical = merged
            }

            let id = UUID()
            state.pendingGenerations[id] = canonical
            state.pendingGenerationOrder.append(id)
            attempts[key] = state
            return .success(
                MediaGenerationLease(
                    id: id,
                    key: key,
                    scope: Self.scope(for: canonical, tokens: tokens)
                )
            )
        }
    }

    func commit(_ lease: MediaGenerationLease) -> Result<Void, MediaTransportError> {
        lock.withLock {
            guard var state = attempts[lease.key],
                let candidate = state.pendingGenerations.removeValue(forKey: lease.id)
            else {
                return .failure(.generationChanged)
            }
            state.pendingGenerationOrder.removeAll { $0 == lease.id }
            defer { attempts[lease.key] = state }

            if let committed = state.generation {
                guard let merged = Self.merging(committed, with: candidate) else {
                    return .failure(.generationChanged)
                }
                state.generation = merged
            } else {
                state.generation = candidate
            }
            return .success(())
        }
    }

    func rollback(_ lease: MediaGenerationLease?) {
        guard let lease else { return }
        lock.withLock {
            guard var state = attempts[lease.key] else { return }
            state.pendingGenerations.removeValue(forKey: lease.id)
            state.pendingGenerationOrder.removeAll { $0 == lease.id }
            attempts[lease.key] = state
        }
    }

    private static func merging(
        _ authoritative: Generation,
        with proposed: Generation
    ) -> Generation? {
        guard authoritative.provisionalKey == proposed.provisionalKey,
            authoritative.totalLength == proposed.totalLength
        else {
            return nil
        }

        switch authoritative {
        case .persistent(let provisionalKey, let totalLength, let validator):
            guard case .persistent = proposed,
                proposed.strongValidator == validator
            else {
                return nil
            }
            return .persistent(
                provisionalKey: provisionalKey,
                totalLength: totalLength,
                validator: validator
            )

        case .attemptOnly(
            let provisionalKey,
            let totalLength,
            let observedStrongValidator
        ):
            if let observedStrongValidator,
                proposed.strongValidator != observedStrongValidator
            {
                return nil
            }
            return .attemptOnly(
                provisionalKey: provisionalKey,
                totalLength: totalLength,
                observedStrongValidator: observedStrongValidator
                    ?? proposed.strongValidator
            )
        }
    }

    private static func scope(
        for generation: Generation,
        tokens: ActivePlaybackTokens
    ) -> ContentGenerationScope {
        switch generation {
        case .persistent(let provisionalKey, let totalLength, let validator):
            return .persistent(
                ValidatedContentGeneration(
                    provisionalKey: provisionalKey,
                    totalLength: totalLength,
                    strongValidator: validator
                )
            )
        case .attemptOnly(_, let totalLength, _):
            return .attemptOnly(
                sessionID: tokens.sessionID,
                sourceAttemptID: tokens.currentSourceAttempt.id,
                totalLength: totalLength
            )
        }
    }

    fileprivate static func strongValidator(_ value: String) -> String? {
        guard !value.lowercased().hasPrefix("w/"),
            value.count > 2,
            value.first == "\"",
            value.last == "\""
        else {
            return nil
        }
        let interior = value.dropFirst().dropLast()
        guard interior.unicodeScalars.allSatisfy({ scalar in
            let codePoint = scalar.value
            return codePoint == 0x21
                || (0x23...0x7E).contains(codePoint)
                || (0x80...0xFF).contains(codePoint)
        }) else {
            return nil
        }
        return value
    }
}

private final class MediaRequestOperation: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private enum ResponsePlan {
        case payload(
            range: Range<Int64>,
            generationScope: ContentGenerationScope,
            generationLease: MediaGenerationLease
        )
        case redirect(declaredBodyBytes: Int64)
        case discard(MediaTransportError)

        var generationLease: MediaGenerationLease? {
            guard case .payload(_, _, let lease) = self else { return nil }
            return lease
        }
    }

    private struct State {
        var session: URLSession?
        var task: URLSessionDataTask?
        var currentRequest: URLRequest?
        var responsePlan: ResponsePlan?
        var nextAbsoluteOffset: Int64 = 0
        var currentResponseBodyBytes: Int64 = 0
        var taskBodyBytesAccounted: Int64 = 0
        var logicalRequestBodyBytes: Int64 = 0
        var redirectCount = 0
        var completed = false
    }

    private struct TerminalResources {
        let task: URLSessionDataTask?
        let session: URLSession?
        let generationLease: MediaGenerationLease?
    }

    private struct ClaimedTermination {
        let error: MediaTransportError
        let resources: TerminalResources
    }

    private let request: MediaByteRequest
    private let configuration: URLSessionConfiguration
    private let redirectPolicy: MediaRedirectPolicy
    private let authorizedKillSwitchEpoch: UInt64
    private let featureSnapshot: @Sendable () -> PlaybackFeatureSnapshot
    private let tokenValidator: @Sendable (ActivePlaybackTokens) -> Bool
    private let maximumChunkBytes: Int
    private let receivedBodyByteCount: @Sendable (URLSessionTask) -> Int64
    private let ledger: MediaAttemptLedger
    private let continuation: AsyncThrowingStream<ValidatedMediaChunk, Error>.Continuation
    private let resourceObserver: @Sendable (URLSession, URLSessionDataTask) -> Void
    private let diagnosticSink: @Sendable (MediaTransportDiagnostic) -> Void
    private let lock = NSLock()
    private var state = State()

    init(
        request: MediaByteRequest,
        configuration: URLSessionConfiguration,
        redirectPolicy: MediaRedirectPolicy,
        authorizedKillSwitchEpoch: UInt64,
        featureSnapshot: @escaping @Sendable () -> PlaybackFeatureSnapshot,
        tokenValidator: @escaping @Sendable (ActivePlaybackTokens) -> Bool,
        maximumChunkBytes: Int,
        receivedBodyByteCount: @escaping @Sendable (URLSessionTask) -> Int64,
        ledger: MediaAttemptLedger,
        continuation: AsyncThrowingStream<ValidatedMediaChunk, Error>.Continuation,
        resourceObserver: @escaping @Sendable (URLSession, URLSessionDataTask) -> Void,
        diagnosticSink: @escaping @Sendable (MediaTransportDiagnostic) -> Void
    ) {
        self.request = request
        self.configuration = configuration
        self.redirectPolicy = redirectPolicy
        self.authorizedKillSwitchEpoch = authorizedKillSwitchEpoch
        self.featureSnapshot = featureSnapshot
        self.tokenValidator = tokenValidator
        self.maximumChunkBytes = maximumChunkBytes
        self.receivedBodyByteCount = receivedBodyByteCount
        self.ledger = ledger
        self.continuation = continuation
        self.resourceObserver = resourceObserver
        self.diagnosticSink = diagnosticSink
    }

    func start() {
        if let error = authorizationError() ?? requestValidationError() {
            finish(with: error)
            return
        }

        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest()
        } catch let error as MediaTransportError {
            finish(with: error)
            return
        } catch {
            finish(with: .invalidRequest)
            return
        }

        let delegateQueue = OperationQueue()
        delegateQueue.name = "LovelyMusic.MediaHTTPClient"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        let task = session.dataTask(with: urlRequest)
        lock.withLock {
            state.session = session
            state.task = task
            state.currentRequest = urlRequest
        }
        resourceObserver(session, task)
        task.resume()
    }

    func cancelFromConsumer() {
        terminate(with: .cancelled, cancelNetwork: true)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            cancelResponse(with: .invalidResponse, completionHandler: completionHandler)
            return
        }

        if let controlError = authorizationError() {
            cancelResponse(with: controlError, completionHandler: completionHandler)
            return
        }

        let plan = responsePlan(for: response)
        switch plan {
        case .discard(let error):
            cancelResponse(with: error, completionHandler: completionHandler)
        case .payload:
            if let error = payloadByteCeilingError(for: plan) {
                ledger.rollback(plan.generationLease)
                cancelResponse(with: error, completionHandler: completionHandler)
                return
            }
            guard installResponsePlan(plan) else {
                ledger.rollback(plan.generationLease)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        case .redirect:
            guard installResponsePlan(plan) else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let receivedBytes = Int64(data.count)
        let action: (ResponsePlan?, Int64, Int64, Bool) = lock.withLock {
            let plan = state.responsePlan
            guard !state.completed else {
                return (plan, state.logicalRequestBodyBytes, receivedBytes, true)
            }

            let previousResponseBytes = state.currentResponseBodyBytes
            state.currentResponseBodyBytes = previousResponseBytes.addingClamped(
                receivedBytes
            )
            state.taskBodyBytesAccounted = state.taskBodyBytesAccounted.addingClamped(
                receivedBytes
            )
            state.logicalRequestBodyBytes = state.logicalRequestBodyBytes.addingClamped(
                receivedBytes
            )
            return (
                plan,
                state.logicalRequestBodyBytes,
                receivedBytes,
                false
            )
        }
        let cumulativeBytes = ledger.account(action.2, for: request.tokens)
        guard !action.3 else { return }

        if let controlError = authorizationError() {
            terminate(with: controlError.accounting(cumulativeBytes), cancelNetwork: true)
            return
        }

        if let ceiling = request.byteCeiling, action.1 > ceiling {
            terminate(
                with:
                .byteCeilingExceeded(
                    ceiling: ceiling,
                    cumulativeResponseBodyBytes: cumulativeBytes
                ),
                cancelNetwork: true
            )
            return
        }

        guard let responsePlan = action.0 else {
            terminate(with: .invalidResponse.accounting(cumulativeBytes), cancelNetwork: true)
            return
        }
        guard case .payload(let absoluteRange, let generationScope, _) = responsePlan else {
            return
        }

        let offset = lock.withLock { state.nextAbsoluteOffset }
        guard offset >= absoluteRange.lowerBound,
            offset <= absoluteRange.upperBound,
            Int64(data.count) <= absoluteRange.upperBound - offset
        else {
            terminate(with: .invalidResponse.accounting(cumulativeBytes), cancelNetwork: true)
            return
        }

        var cursor = data.startIndex
        var absoluteOffset = offset
        while cursor < data.endIndex {
            if let controlError = authorizationError() {
                terminate(with: controlError.accounting(cumulativeBytes), cancelNetwork: true)
                return
            }
            guard lock.withLock({ !state.completed }) else { return }

            let end = min(data.endIndex, cursor + maximumChunkBytes)
            let payload = Data(data[cursor..<end])
            let payloadEnd = absoluteOffset + Int64(payload.count)
            let chunk = ValidatedMediaChunk(
                absoluteRange: absoluteOffset..<payloadEnd,
                payload: payload,
                generationScope: generationScope,
                cumulativeResponseBodyBytes: cumulativeBytes
            )

            switch continuation.yield(chunk) {
            case .enqueued:
                lock.withLock { state.nextAbsoluteOffset = payloadEnd }
            case .dropped:
                terminate(
                    with:
                    .backpressureExceeded(
                        maximumBufferedChunks: MediaHTTPClient.maximumBufferedChunkCount,
                        cumulativeResponseBodyBytes: cumulativeBytes
                    ),
                    cancelNetwork: true
                )
                return
            case .terminated:
                cancelFromConsumer()
                return
            @unknown default:
                terminate(
                    with: .invalidResponse.accounting(cumulativeBytes),
                    cancelNetwork: true
                )
                return
            }

            absoluteOffset = payloadEnd
            cursor = end
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest proposedRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let accountingError = accountRedirectResponse(response, task: task) {
            cancelRedirect(with: accountingError, completionHandler: completionHandler)
            return
        }
        if let controlError = authorizationError() {
            cancelRedirect(with: controlError, completionHandler: completionHandler)
            return
        }

        let currentRequest = lock.withLock { state.currentRequest }
        guard let currentRequest, let targetURL = proposedRequest.url else {
            cancelRedirect(
                with: .unapprovedRedirect,
                completionHandler: completionHandler
            )
            return
        }

        do {
            let redirected = try redirectPolicy.redirectedRequest(
                from: currentRequest,
                to: targetURL
            )
            if let controlError = authorizationError() {
                cancelRedirect(with: controlError, completionHandler: completionHandler)
                return
            }
            let allowed = lock.withLock { () -> Bool in
                guard !state.completed, state.redirectCount < 5 else { return false }
                state.redirectCount += 1
                state.currentRequest = redirected
                state.nextAbsoluteOffset = 0
                return true
            }
            guard allowed else {
                cancelRedirect(
                    with: .unapprovedRedirect,
                    completionHandler: completionHandler
                )
                return
            }
            completionHandler(redirected)
        } catch {
            cancelRedirect(
                with: .unapprovedRedirect,
                completionHandler: completionHandler
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let controlError = authorizationError()
        let completion: (MediaTransportError?, TerminalResources)? = lock.withLock {
            guard !state.completed else { return nil }
            state.completed = true

            var finalError = controlError
            if finalError == nil, let error {
                if (error as? URLError)?.code == .cancelled {
                    finalError = .cancelled
                } else {
                    finalError = MediaTransportError(
                        reason: .transportFailure,
                        cumulativeResponseBodyBytes: 0
                    )
                }
            }
            if finalError == nil {
                switch state.responsePlan {
                case .payload(let range, _, _):
                    if state.nextAbsoluteOffset != range.upperBound {
                        finalError = .invalidResponse
                    }
                case .redirect:
                    finalError = .unapprovedRedirect
                case .discard(let responseError):
                    finalError = responseError
                case nil:
                    finalError = .invalidResponse
                }
            }
            let resources = TerminalResources(
                task: state.task,
                session: state.session,
                generationLease: state.responsePlan?.generationLease
            )
            state.task = nil
            state.session = nil
            state.currentRequest = nil
            state.responsePlan = nil
            return (finalError, resources)
        }
        guard let completion else { return }

        var finalError = completion.0
        if finalError == nil, let lease = completion.1.generationLease {
            if case .failure(let error) = ledger.commit(lease) {
                finalError = error
            }
        } else {
            ledger.rollback(completion.1.generationLease)
        }

        let cumulativeBytes = ledger.cumulativeBytes(for: request.tokens)
        if let error = finalError {
            let accounted = error.accounting(cumulativeBytes)
            emit(accounted)
            continuation.finish(throwing: accounted)
        } else {
            continuation.finish()
        }
        completion.1.session?.finishTasksAndInvalidate()
    }

    private func responsePlan(for response: HTTPURLResponse) -> ResponsePlan {
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
            encoding.caseInsensitiveCompare("identity") != .orderedSame
        {
            return .discard(.transformedContentEncoding)
        }

        let statusCode = response.statusCode
        if [301, 302, 303, 307, 308].contains(statusCode),
            response.value(forHTTPHeaderField: "Location") != nil
        {
            guard let contentLengthValue = response.value(
                forHTTPHeaderField: "Content-Length"
            ) else {
                return .redirect(declaredBodyBytes: 0)
            }
            guard let declaredBodyBytes = nonnegativeInt64(contentLengthValue) else {
                return .discard(.invalidResponse)
            }
            return .redirect(declaredBodyBytes: declaredBodyBytes)
        }

        switch statusCode {
        case 200:
            guard request.range == nil,
                let totalLength = positiveInt64(
                    response.value(forHTTPHeaderField: "Content-Length")
                ),
                request.descriptor.contentLength.map({ $0 == totalLength }) ?? true
            else {
                return .discard(request.range == nil ? .invalidResponse : .rangeIgnored)
            }
            return generationPlan(
                response: response,
                totalLength: totalLength,
                absoluteRange: 0..<totalLength,
                allowPersistent: false
            )

        case 206:
            guard let requestedRange = request.range,
                let parsed = parseSatisfiedContentRange(
                    response.value(forHTTPHeaderField: "Content-Range")
                ),
                parsed.range.lowerBound == requestedRange.lowerBound,
                parsed.range.upperBound
                    == min(requestedRange.upperBound, parsed.totalLength),
                request.descriptor.contentLength.map({ $0 == parsed.totalLength }) ?? true,
                response.value(forHTTPHeaderField: "Content-Length").map({
                    positiveInt64($0) == Int64(parsed.range.count)
                }) ?? true
            else {
                return .discard(.invalidContentRange)
            }
            return generationPlan(
                response: response,
                totalLength: parsed.totalLength,
                absoluteRange: parsed.range,
                allowPersistent: true
            )

        case 416:
            guard let totalLength = parseUnsatisfiedContentRange(
                response.value(forHTTPHeaderField: "Content-Range")
            ),
                let requestedRange = request.range,
                requestedRange.lowerBound >= totalLength,
                (ledger.expectedTotalLength(for: request.tokens)
                    ?? request.descriptor.contentLength) == totalLength
            else {
                return .discard(.invalidContentRange)
            }
            return .discard(
                .endOfResource(
                    totalLength: totalLength,
                    cumulativeResponseBodyBytes: 0
                )
            )

        default:
            return .discard(
                .unsupportedStatus(statusCode, cumulativeResponseBodyBytes: 0)
            )
        }
    }

    private func generationPlan(
        response: HTTPURLResponse,
        totalLength: Int64,
        absoluteRange: Range<Int64>,
        allowPersistent: Bool
    ) -> ResponsePlan {
        switch ledger.beginGeneration(
            totalLength: totalLength,
            etag: response.value(forHTTPHeaderField: "ETag"),
            descriptor: request.descriptor,
            tokens: request.tokens,
            allowPersistent: allowPersistent
        ) {
        case .success(let lease):
            return .payload(
                range: absoluteRange,
                generationScope: lease.scope,
                generationLease: lease
            )
        case .failure(let error):
            return .discard(error)
        }
    }

    private func installResponsePlan(_ plan: ResponsePlan) -> Bool {
        lock.withLock {
            guard !state.completed else { return false }
            state.responsePlan = plan
            state.currentResponseBodyBytes = 0
            if case .payload(let range, _, _) = plan {
                state.nextAbsoluteOffset = range.lowerBound
            }
            return true
        }
    }

    private func accountRedirectResponse(
        _ response: HTTPURLResponse,
        task: URLSessionTask
    ) -> MediaTransportError? {
        if let rawLength = response.value(forHTTPHeaderField: "Content-Length") {
            guard nonnegativeInt64(rawLength) != nil else {
                return .invalidResponse
            }
        }

        let accounting = lock.withLock { () -> (Int64, Int64)? in
            guard !state.completed else { return nil }
            let receivedTaskBodyBytes = max(0, receivedBodyByteCount(task))
            let newlyObservedBodyBytes = max(
                0,
                receivedTaskBodyBytes - state.taskBodyBytesAccounted
            )
            state.taskBodyBytesAccounted = state.taskBodyBytesAccounted.addingClamped(
                newlyObservedBodyBytes
            )
            state.logicalRequestBodyBytes = state.logicalRequestBodyBytes.addingClamped(
                newlyObservedBodyBytes
            )
            return (newlyObservedBodyBytes, state.logicalRequestBodyBytes)
        }
        guard let accounting else { return .cancelled }

        let cumulativeResponseBodyBytes = ledger.account(
            accounting.0,
            for: request.tokens
        )

        if let ceiling = request.byteCeiling, accounting.1 > ceiling {
            return .byteCeilingExceeded(
                ceiling: ceiling,
                cumulativeResponseBodyBytes: cumulativeResponseBodyBytes
            )
        }
        return nil
    }

    private func payloadByteCeilingError(
        for plan: ResponsePlan
    ) -> MediaTransportError? {
        guard case .payload(let range, _, _) = plan,
            let ceiling = request.byteCeiling
        else {
            return nil
        }

        let validatedPayloadBytes = range.upperBound - range.lowerBound
        let logicalRequestBodyBytes = lock.withLock {
            state.logicalRequestBodyBytes
        }
        guard logicalRequestBodyBytes > ceiling
            || validatedPayloadBytes > ceiling - logicalRequestBodyBytes
        else {
            return nil
        }
        return .byteCeilingExceeded(
            ceiling: ceiling,
            cumulativeResponseBodyBytes: ledger.cumulativeBytes(for: request.tokens)
        )
    }

    private func terminate(
        with error: MediaTransportError,
        cancelNetwork: Bool
    ) {
        guard let claimed = claimTermination(with: error) else { return }
        finishClaimedTermination(claimed, cancelNetwork: cancelNetwork)
    }

    private func cancelResponse(
        with error: MediaTransportError,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let claimed = claimTermination(with: error)
        if let claimed {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                finishClaimedTermination(claimed, cancelNetwork: true)
            }
        }
        completionHandler(.cancel)
    }

    private func cancelRedirect(
        with error: MediaTransportError,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let claimed = claimTermination(with: error)
        if let claimed {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                finishClaimedTermination(claimed, cancelNetwork: true)
            }
        }
        completionHandler(nil)
    }

    private func claimTermination(
        with error: MediaTransportError
    ) -> ClaimedTermination? {
        let resources: TerminalResources? = lock.withLock {
            guard !state.completed else { return nil }
            state.completed = true
            let resources = TerminalResources(
                task: state.task,
                session: state.session,
                generationLease: state.responsePlan?.generationLease
            )
            state.task = nil
            state.session = nil
            state.currentRequest = nil
            state.responsePlan = nil
            return resources
        }
        guard let resources else { return nil }
        return ClaimedTermination(error: error, resources: resources)
    }

    private func finishClaimedTermination(
        _ claimed: ClaimedTermination,
        cancelNetwork: Bool
    ) {
        ledger.rollback(claimed.resources.generationLease)
        if cancelNetwork {
            claimed.resources.task?.cancel()
            claimed.resources.session?.invalidateAndCancel()
        } else {
            claimed.resources.session?.finishTasksAndInvalidate()
        }

        let accounted = claimed.error.accounting(
            ledger.cumulativeBytes(for: request.tokens)
        )
        emit(accounted)
        continuation.finish(throwing: accounted)
    }

    private func finish(with error: MediaTransportError) {
        terminate(with: error, cancelNetwork: false)
    }

    private func emit(_ error: MediaTransportError) {
        diagnosticSink(
            MediaTransportDiagnostic(
                family: error.diagnosticFamily,
                statusCode: error.statusCode,
                cumulativeResponseBodyBytes: error.cumulativeResponseBodyBytes
            )
        )
    }

    private func authorizationError() -> MediaTransportError? {
        let snapshot = featureSnapshot()
        guard snapshot.killSwitchEpoch == authorizedKillSwitchEpoch else {
            return .staleKillSwitchEpoch
        }
        guard !snapshot.killSwitch else { return .killSwitchEnabled }
        guard snapshot.hasSupportedSchema else { return .killSwitchEnabled }
        guard tokenValidator(request.tokens) else { return .stalePlaybackTokens }
        return nil
    }

    private func requestValidationError() -> MediaTransportError? {
        let url = request.descriptor.remoteURL
        guard redirectPolicy.approves(url),
            url.user == nil,
            url.password == nil,
            url.fragment == nil,
            request.byteCeiling.map({ $0 > 0 }) ?? true
        else {
            return .invalidRequest
        }
        if let range = request.range {
            guard range.lowerBound >= 0, range.lowerBound < range.upperBound else {
                return .invalidRequest
            }
        }
        if let validator = request.ifRangeValidator,
            MediaAttemptLedger.strongValidator(validator) == nil
        {
            return .invalidRequest
        }
        if request.purpose == .generationProbe,
            request.range != 0..<1 || request.byteCeiling != 1
        {
            return .invalidRequest
        }

        var names = Set<String>()
        for (name, value) in request.descriptor.requestHeaders {
            let normalized = name.lowercased()
            guard !normalized.isEmpty,
                names.insert(normalized).inserted,
                !name.contains("\r"),
                !name.contains("\n"),
                !value.contains("\r"),
                !value.contains("\n")
            else {
                return .invalidRequest
            }
        }
        return nil
    }

    private func makeURLRequest() throws -> URLRequest {
        var urlRequest = URLRequest(
            url: request.descriptor.remoteURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
        )
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false

        for (name, value) in request.descriptor.requestHeaders {
            guard name.caseInsensitiveCompare("Range") != .orderedSame,
                name.caseInsensitiveCompare("If-Range") != .orderedSame,
                name.caseInsensitiveCompare("Accept-Encoding") != .orderedSame
            else {
                continue
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if let range = request.range {
            guard range.upperBound > range.lowerBound else {
                throw MediaTransportError.invalidRequest
            }
            urlRequest.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
        }

        let validator = ledger.authoritativeStrongValidator(for: request.tokens)
            ?? request.ifRangeValidator
        urlRequest.setValue(validator, forHTTPHeaderField: "If-Range")
        return urlRequest
    }
}

private struct ParsedSatisfiedContentRange {
    let range: Range<Int64>
    let totalLength: Int64
}

private func parseSatisfiedContentRange(_ value: String?) -> ParsedSatisfiedContentRange? {
    guard let value, value.hasPrefix("bytes ") else { return nil }
    let fields = value.dropFirst("bytes ".count).split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard fields.count == 2,
        let totalLength = Int64(fields[1]),
        totalLength > 0
    else {
        return nil
    }
    let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2,
        let lowerBound = Int64(bounds[0]),
        let inclusiveUpperBound = Int64(bounds[1]),
        lowerBound >= 0,
        inclusiveUpperBound >= lowerBound,
        inclusiveUpperBound < Int64.max,
        inclusiveUpperBound < totalLength
    else {
        return nil
    }
    return ParsedSatisfiedContentRange(
        range: lowerBound..<(inclusiveUpperBound + 1),
        totalLength: totalLength
    )
}

private func parseUnsatisfiedContentRange(_ value: String?) -> Int64? {
    guard let value, value.hasPrefix("bytes */"),
        let totalLength = Int64(value.dropFirst("bytes */".count)),
        totalLength > 0
    else {
        return nil
    }
    return totalLength
}

private func positiveInt64(_ value: String?) -> Int64? {
    guard let value, let parsed = Int64(value), parsed > 0 else { return nil }
    return parsed
}

private func nonnegativeInt64(_ value: String?) -> Int64? {
    guard let value, let parsed = Int64(value), parsed >= 0 else { return nil }
    return parsed
}

private extension Int64 {
    func addingClamped(_ other: Int64) -> Int64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }
}
