import Foundation

/// Deterministic, process-local HTTP fixture used only by media transport tests.
///
/// All mutable global state is protected by `lock`; the unchecked conformance is
/// limited to Foundation's callback-driven `URLProtocol` boundary.
final class MediaURLProtocolStub: URLProtocol, @unchecked Sendable {
    final class BodyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var delivery: (@Sendable () -> Void)?
        private var isReleased = false

        fileprivate func whenReleased(_ delivery: @escaping @Sendable () -> Void) {
            let deliverNow = lock.withLock { () -> Bool in
                if isReleased { return true }
                self.delivery = delivery
                return false
            }
            if deliverNow { delivery() }
        }

        func release() {
            let delivery = lock.withLock { () -> (@Sendable () -> Void)? in
                guard !isReleased else { return nil }
                isReleased = true
                defer { self.delivery = nil }
                return self.delivery
            }
            delivery?()
        }
    }

    struct Response: @unchecked Sendable {
        let statusCode: Int
        let headers: [String: String]
        let bodyChunks: [Data]
        let finish: Bool
        let error: URLError?
        let redirectURL: URL?
        let bodyGate: BodyGate?
        let bodyChunkGates: [BodyGate?]

        init(
            statusCode: Int,
            headers: [String: String] = [:],
            bodyChunks: [Data] = [],
            finish: Bool = true,
            error: URLError? = nil,
            redirectURL: URL? = nil,
            bodyGate: BodyGate? = nil,
            bodyChunkGates: [BodyGate?] = []
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.bodyChunks = bodyChunks
            self.finish = finish
            self.error = error
            self.redirectURL = redirectURL
            self.bodyGate = bodyGate
            self.bodyChunkGates = bodyChunkGates
        }
    }

    private struct State {
        var queuedResponses: [Response] = []
        var capturedRequests: [URLRequest] = []
        var emittedResponseBodyBytes: Int64 = 0
        var stoppedRequestCount = 0
        var onRequest: ((URLRequest) -> Void)?
        var beforeResponse: ((HTTPURLResponse) -> Void)?
        var onResponse: (() -> Void)?
        var beforeBodyChunk: ((Int, Data) -> Void)?
        var beforeRedirect: ((URL) -> Void)?
        var onStop: (() -> Void)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    private let instanceLock = NSLock()
    private let deliveryQueue = DispatchQueue(
        label: "LovelyMusic.MediaURLProtocolStub.delivery"
    )
    private var isStopped = false

    static var capturedRequests: [URLRequest] {
        lock.withLock { state.capturedRequests }
    }

    static var emittedResponseBodyBytes: Int64 {
        lock.withLock { state.emittedResponseBodyBytes }
    }

    static var stoppedRequestCount: Int {
        lock.withLock { state.stoppedRequestCount }
    }

    static func reset(
        responses: [Response] = [],
        onRequest: ((URLRequest) -> Void)? = nil,
        beforeResponse: ((HTTPURLResponse) -> Void)? = nil,
        onResponse: (() -> Void)? = nil,
        beforeBodyChunk: ((Int, Data) -> Void)? = nil,
        beforeRedirect: ((URL) -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        lock.withLock {
            state = State(
                queuedResponses: responses,
                capturedRequests: [],
                emittedResponseBodyBytes: 0,
                stoppedRequestCount: 0,
                onRequest: onRequest,
                beforeResponse: beforeResponse,
                onResponse: onResponse,
                beforeBodyChunk: beforeBodyChunk,
                beforeRedirect: beforeRedirect,
                onStop: onStop
            )
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https" || request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let fixture: (
            Response?,
            ((URLRequest) -> Void)?,
            ((HTTPURLResponse) -> Void)?,
            (() -> Void)?,
            ((Int, Data) -> Void)?,
            ((URL) -> Void)?
        ) =
            Self.lock.withLock {
                Self.state.capturedRequests.append(request)
                let response = Self.state.queuedResponses.isEmpty
                    ? nil
                    : Self.state.queuedResponses.removeFirst()
                return (
                    response,
                    Self.state.onRequest,
                    Self.state.beforeResponse,
                    Self.state.onResponse,
                    Self.state.beforeBodyChunk,
                    Self.state.beforeRedirect
                )
            }

        fixture.1?(request)

        guard let response = fixture.0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }

        guard let url = request.url,
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        fixture.2?(httpResponse)
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        fixture.3?()

        guard let bodyGate = response.bodyGate else {
            scheduleDelivery(
                response,
                httpResponse: httpResponse,
                beforeBodyChunk: fixture.4,
                beforeRedirect: fixture.5
            )
            return
        }

        bodyGate.whenReleased { [weak self] in
            self?.scheduleDelivery(
                response,
                httpResponse: httpResponse,
                beforeBodyChunk: fixture.4,
                beforeRedirect: fixture.5
            )
        }
    }

    private func scheduleDelivery(
        _ response: Response,
        httpResponse: HTTPURLResponse,
        beforeBodyChunk: ((Int, Data) -> Void)?,
        beforeRedirect: ((URL) -> Void)?
    ) {
        deliveryQueue.async { [weak self] in
            self?.deliver(
                response,
                httpResponse: httpResponse,
                beforeBodyChunk: beforeBodyChunk,
                beforeRedirect: beforeRedirect
            )
        }
    }

    private func deliver(
        _ response: Response,
        httpResponse: HTTPURLResponse,
        beforeBodyChunk: ((Int, Data) -> Void)?,
        beforeRedirect: ((URL) -> Void)?
    ) {
        deliverChunk(
            at: 0,
            response: response,
            httpResponse: httpResponse,
            beforeBodyChunk: beforeBodyChunk,
            beforeRedirect: beforeRedirect
        )
    }

    private func deliverChunk(
        at index: Int,
        response: Response,
        httpResponse: HTTPURLResponse,
        beforeBodyChunk: ((Int, Data) -> Void)?,
        beforeRedirect: ((URL) -> Void)?
    ) {
        guard !stopIfTaskIsNoLongerRunning() else { return }

        guard index < response.bodyChunks.count else {
            finish(response, httpResponse: httpResponse, beforeRedirect: beforeRedirect)
            return
        }

        let emitChunk: @Sendable () -> Void = { [weak self] in
            guard let self,
                !self.stopIfTaskIsNoLongerRunning()
            else { return }
            let chunk = response.bodyChunks[index]
            beforeBodyChunk?(index, chunk)
            Self.lock.withLock {
                Self.state.emittedResponseBodyBytes += Int64(chunk.count)
            }
            self.client?.urlProtocol(self, didLoad: chunk)
            self.deliveryQueue.async { [weak self] in
                self?.deliverChunk(
                    at: index + 1,
                    response: response,
                    httpResponse: httpResponse,
                    beforeBodyChunk: beforeBodyChunk,
                    beforeRedirect: beforeRedirect
                )
            }
        }

        if index < response.bodyChunkGates.count,
            let gate = response.bodyChunkGates[index]
        {
            gate.whenReleased(emitChunk)
        } else {
            emitChunk()
        }
    }

    private func finish(
        _ response: Response,
        httpResponse: HTTPURLResponse,
        beforeRedirect: ((URL) -> Void)?
    ) {
        guard !stopIfTaskIsNoLongerRunning() else { return }

        if let redirectURL = response.redirectURL {
            beforeRedirect?(redirectURL)
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: redirectURL),
                redirectResponse: httpResponse
            )
            return
        }

        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else if response.finish {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        recordStopIfNeeded()
    }

    private func stopIfTaskIsNoLongerRunning() -> Bool {
        if instanceLock.withLock({ isStopped }) { return true }
        guard let task, task.state == .canceling || task.state == .completed else {
            return false
        }
        recordStopIfNeeded()
        return true
    }

    private func recordStopIfNeeded() {
        let shouldNotify = instanceLock.withLock { () -> Bool in
            guard !isStopped else { return false }
            isStopped = true
            return true
        }
        guard shouldNotify else { return }
        let onStop = Self.lock.withLock { () -> (() -> Void)? in
            Self.state.stoppedRequestCount += 1
            return Self.state.onStop
        }
        onStop?()
    }
}
