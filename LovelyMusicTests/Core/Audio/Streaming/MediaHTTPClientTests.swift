import Foundation
import XCTest
@testable import LovelyMusic

@MainActor
final class MediaHTTPClientTests: XCTestCase {
    private let epoch: UInt64 = 41
    private let signedURLString =
        "https://media.example.test/videoplayback?sig=secret%2Bsignature&x=1&x=2&range=7-9"

    override func tearDown() {
        MediaURLProtocolStub.reset()
        super.tearDown()
    }

    func testProductionMediaSessionHasNoUnmanagedPersistence() {
        let configuration = MediaHTTPClient.productionConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )
        XCTAssertEqual(
            configuration.httpAdditionalHeaders?["Accept-Encoding"] as? String,
            "identity"
        )
        XCTAssertNil(configuration.protocolClasses)
    }

    func testTestProtocolInjectionDoesNotMutateProductionConfiguration() {
        let testing = MediaHTTPClient.testingConfiguration(
            protocolClass: MediaURLProtocolStub.self
        )

        XCTAssertTrue(testing.protocolClasses?.first === MediaURLProtocolStub.self)
        XCTAssertNil(MediaHTTPClient.productionConfiguration().protocolClasses)
        XCTAssertNil(testing.urlCache)
        XCTAssertNil(testing.httpCookieStorage)
        XCTAssertNil(testing.urlCredentialStorage)
    }

    func testClientDefensivelyCopiesAndSanitizesInjectedConfiguration() {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let supplied = MediaHTTPClient.testingConfiguration(
            protocolClass: MediaURLProtocolStub.self
        )
        let client = makeClient(tokens: tokens, configuration: supplied)

        supplied.urlCache = URLCache(
            memoryCapacity: 1_024,
            diskCapacity: 0,
            diskPath: nil
        )
        supplied.httpCookieStorage = .shared
        supplied.urlCredentialStorage = .shared
        supplied.httpShouldSetCookies = true
        supplied.httpCookieAcceptPolicy = .always
        supplied.requestCachePolicy = .returnCacheDataElseLoad
        supplied.httpAdditionalHeaders = ["Accept-Encoding": "br"]
        supplied.protocolClasses = nil

        let stored = Mirror(reflecting: client).children.first(where: {
            $0.label == "configuration"
        })?.value as? URLSessionConfiguration

        XCTAssertNotNil(stored)
        XCTAssertFalse(stored === supplied)
        XCTAssertNil(stored?.urlCache)
        XCTAssertNil(stored?.httpCookieStorage)
        XCTAssertNil(stored?.urlCredentialStorage)
        XCTAssertEqual(stored?.httpShouldSetCookies, false)
        XCTAssertEqual(stored?.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(stored?.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(
            stored?.httpAdditionalHeaders?["Accept-Encoding"] as? String,
            "identity"
        )
        XCTAssertTrue(stored?.protocolClasses?.first === MediaURLProtocolStub.self)
    }

    func testActualRequestPreservesSignedURLAndHeadersExactlyOnce() async throws {
        let sentinels = secretHeaders()
        let descriptor = makeDescriptor(headers: sentinels)
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let recorder = DiagnosticRecorder()
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4]))
        ])
        let client = makeClient(tokens: tokens, diagnostics: recorder.record)
        let request = MediaByteRequest(
            descriptor: descriptor,
            range: 0..<4,
            ifRangeValidator: nil,
            purpose: .media,
            byteCeiling: 4,
            tokens: tokens
        )

        let chunks = try await collect(client.bytes(for: request))
        let captured = try XCTUnwrap(MediaURLProtocolStub.capturedRequests.first)

        XCTAssertEqual(chunks.map(\.payload).reduce(Data(), +), Data([1, 2, 3, 4]))
        XCTAssertEqual(captured.url?.absoluteString, signedURLString)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Range"), "bytes=0-3")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        for (name, value) in sentinels where
            name.caseInsensitiveCompare("Range") != .orderedSame
                && name.caseInsensitiveCompare("Accept-Encoding") != .orderedSame
        {
            XCTAssertEqual(captured.value(forHTTPHeaderField: name), value)
            XCTAssertEqual(
                captured.allHTTPHeaderFields?.keys.filter {
                    $0.caseInsensitiveCompare(name) == .orderedSame
                }.count,
                1
            )
        }
        XCTAssertNotEqual(
            captured.value(forHTTPHeaderField: "Range"),
            sentinels["Range"]
        )
        XCTAssertNotEqual(
            captured.value(forHTTPHeaderField: "Accept-Encoding"),
            sentinels["Accept-Encoding"]
        )
        XCTAssertFalse(request.description.contains("secret"))
        XCTAssertFalse(request.description.contains(signedURLString))
        XCTAssertTrue(recorder.messages.isEmpty)
    }

    func testInitialOriginMustBeApprovedBeforeForwardingDescriptorHeaders() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4]))
        ])
        let deniedClient = makeClient(
            tokens: tokens,
            redirectPolicy: .init(approvedOrigins: [
                .init(origin: URL(string: "https://cdn.example.test")!, headers: [:])
            ])
        )

        let denied = await collectResult(
            deniedClient.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )

        XCTAssertTrue(denied.chunks.isEmpty)
        XCTAssertEqual(denied.error as? MediaTransportError, .invalidRequest)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 0)

        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4]))
        ])
        let approvedClient = makeClient(
            tokens: tokens,
            redirectPolicy: .init(approvedOrigins: [
                .init(origin: URL(string: "https://media.example.test")!, headers: [:])
            ])
        )

        let approved = try await collect(
            approvedClient.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )

        XCTAssertEqual(approved.map(\.payload).reduce(Data(), +), Data([1, 2, 3, 4]))
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 1)
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests[0].value(forHTTPHeaderField: "Cookie"),
            secretHeaders()["Cookie"]
        )
    }

    func testGenerationProbeUsesOnlyByteZeroAndCreatesPersistentScope() async throws {
        let descriptor = makeDescriptor()
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([0xAA])
            )
        ])
        let client = makeClient(tokens: tokens)

        let scope = try await client.validateGeneration(for: descriptor, tokens: tokens)

        XCTAssertEqual(
            scope,
            .persistent(
                ValidatedContentGeneration(
                    provisionalKey: descriptor.provisionalResourceKey,
                    totalLength: 16,
                    strongValidator: "\"generation-a\""
                )
            )
        )
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 1)
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests[0].value(forHTTPHeaderField: "Range"),
            "bytes=0-0"
        )
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 1)
    }

    func testWeakMissingAndLastModifiedValidatorsRemainAttemptOnly() async throws {
        let validators: [[String: String]] = [
            ["ETag": "W/\"weak\""],
            ["ETag": "unquoted-validator"],
            ["ETag": "\"\""],
            [:],
            ["Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"],
        ]

        for headers in validators {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            var responseHeaders = headers
            responseHeaders["Content-Range"] = "bytes 0-0/16"
            responseHeaders["Content-Length"] = "1"
            MediaURLProtocolStub.reset(responses: [
                .init(statusCode: 206, headers: responseHeaders, bodyChunks: [Data([1])])
            ])
            let client = makeClient(tokens: tokens)

            let scope = try await client.validateGeneration(
                for: makeDescriptor(),
                tokens: tokens
            )

            XCTAssertEqual(
                scope,
                .attemptOnly(
                    sessionID: tokens.sessionID,
                    sourceAttemptID: tokens.currentSourceAttempt.id,
                    totalLength: 16
                )
            )
        }
    }

    func testAttemptOnlyGenerationRejectsAChangedStrongValidatorOnceObserved() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-0/16",
                    "Content-Length": "1",
                    "Content-Encoding": "identity",
                ],
                bodyChunks: [Data([0])]
            ),
            validPartialResponse(
                range: 1..<2,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([1])
            ),
            validPartialResponse(
                range: 2..<3,
                total: 16,
                etag: "\"generation-b\"",
                body: Data([2])
            ),
        ])
        let client = makeClient(tokens: tokens)

        let missing = try await collect(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<1))
        )
        let anchored = try await collect(
            client.bytes(for: makeRequest(tokens: tokens, range: 1..<2))
        )
        let changed = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 2..<3))
        )

        let expectedScope = ContentGenerationScope.attemptOnly(
            sessionID: tokens.sessionID,
            sourceAttemptID: tokens.currentSourceAttempt.id,
            totalLength: 16
        )
        XCTAssertEqual(missing.last?.generationScope, expectedScope)
        XCTAssertEqual(anchored.last?.generationScope, expectedScope)
        XCTAssertTrue(changed.chunks.isEmpty)
        XCTAssertEqual(changed.error as? MediaTransportError, .generationChanged)
        XCTAssertEqual(changed.error?.accountedResponseBodyBytes, 2)
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests.last?.value(forHTTPHeaderField: "If-Range"),
            "\"generation-a\""
        )
    }

    func testGenerationIdentityRejectsDifferentResourceWithMissingValidator() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let firstDescriptor = makeDescriptor(videoID: "resource-a")
        let secondDescriptor = makeDescriptor(videoID: "resource-b")
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-0/16",
                    "Content-Length": "1",
                    "Content-Encoding": "identity",
                ],
                bodyChunks: [Data([0])]
            ),
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 1-1/16",
                    "Content-Length": "1",
                    "Content-Encoding": "identity",
                ],
                bodyChunks: [Data([1])]
            ),
        ])
        let client = makeClient(tokens: tokens)

        _ = try await collect(
            client.bytes(
                for: makeRequest(
                    tokens: tokens,
                    descriptor: firstDescriptor,
                    range: 0..<1
                )
            )
        )
        let changed = await collectResult(
            client.bytes(
                for: makeRequest(
                    tokens: tokens,
                    descriptor: secondDescriptor,
                    range: 1..<2
                )
            )
        )

        XCTAssertTrue(changed.chunks.isEmpty)
        XCTAssertEqual(changed.error as? MediaTransportError, .generationChanged)
        XCTAssertEqual(changed.error?.accountedResponseBodyBytes, 1)
    }

    func testGenerationIdentityRejectsDifferentResourceWithSameStrongValidator() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let firstDescriptor = makeDescriptor(videoID: "resource-a")
        let secondDescriptor = makeDescriptor(videoID: "resource-b")
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"shared-validator\"",
                body: Data([0])
            ),
            validPartialResponse(
                range: 1..<2,
                total: 16,
                etag: "\"shared-validator\"",
                body: Data([1])
            ),
        ])
        let client = makeClient(tokens: tokens)

        _ = try await collect(
            client.bytes(
                for: makeRequest(
                    tokens: tokens,
                    descriptor: firstDescriptor,
                    range: 0..<1
                )
            )
        )
        let changed = await collectResult(
            client.bytes(
                for: makeRequest(
                    tokens: tokens,
                    descriptor: secondDescriptor,
                    range: 1..<2
                )
            )
        )

        XCTAssertTrue(changed.chunks.isEmpty)
        XCTAssertEqual(changed.error as? MediaTransportError, .generationChanged)
        XCTAssertEqual(changed.error?.accountedResponseBodyBytes, 1)
    }

    func testOverlappingGenerationCandidatesRejectDifferentResourceBeforeExposure() throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let firstDescriptor = makeDescriptor(videoID: "resource-a")
        let secondDescriptor = makeDescriptor(videoID: "resource-b")
        MediaURLProtocolStub.reset()
        let ledger = MediaAttemptLedger()
        let firstLease = try ledger.beginGeneration(
            totalLength: 16,
            etag: "\"shared-validator\"",
            descriptor: firstDescriptor,
            tokens: tokens,
            allowPersistent: true
        ).get()
        defer { ledger.rollback(firstLease) }

        let changed = ledger.beginGeneration(
            totalLength: 16,
            etag: "\"shared-validator\"",
            descriptor: secondDescriptor,
            tokens: tokens,
            allowPersistent: true
        )

        guard case .failure(let error) = changed else {
            if case .success(let lease) = changed {
                ledger.rollback(lease)
            }
            return XCTFail("A second resource cannot acquire an overlapping generation lease")
        }
        XCTAssertEqual(error, .generationChanged)
        XCTAssertEqual(ledger.cumulativeBytes(for: tokens), 0)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
        XCTAssertTrue(MediaURLProtocolStub.capturedRequests.isEmpty)
    }

    func testSignedURLRefreshWithSameProvisionalResourceKeyRemainsAllowed() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let refreshedURL =
            "https://media.example.test/videoplayback?sig=refreshed%2Bsignature&x=1&x=2"
        let firstDescriptor = makeDescriptor()
        let refreshedDescriptor = makeDescriptor(remoteURLString: refreshedURL)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<1, total: 16, body: Data([0])),
            validPartialResponse(range: 1..<2, total: 16, body: Data([1])),
        ])
        let client = makeClient(tokens: tokens)

        _ = try await collect(
            client.bytes(
                for: makeRequest(
                    tokens: tokens,
                    descriptor: firstDescriptor,
                    range: 0..<1
                )
            )
        )
        let refreshed = try await collect(
            client.bytes(
                for: makeRequest(
                    tokens: tokens,
                    descriptor: refreshedDescriptor,
                    range: 1..<2
                )
            )
        )

        XCTAssertEqual(refreshed.map(\.payload), [Data([1])])
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.last?.url?.absoluteString, refreshedURL)
        XCTAssertEqual(firstDescriptor.provisionalResourceKey, refreshedDescriptor.provisionalResourceKey)
    }

    func testOnlyRFCETagcCharactersCanCreatePersistentGeneration() async throws {
        let malformedValidators = [
            "\"embedded\"quote\"",
            "\"tab\tvalue\"",
            "\"space value\"",
            "\"delete\u{7F}value\"",
            "\"emoji-🎵\"",
        ]

        for validator in malformedValidators {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [
                validPartialResponse(
                    range: 0..<1,
                    total: 16,
                    etag: validator,
                    body: Data([0])
                )
            ])

            let scope = try await makeClient(tokens: tokens).validateGeneration(
                for: makeDescriptor(),
                tokens: tokens
            )

            XCTAssertEqual(
                scope,
                .attemptOnly(
                    sessionID: tokens.sessionID,
                    sourceAttemptID: tokens.currentSourceAttempt.id,
                    totalLength: 16
                ),
                String(reflecting: validator)
            )
        }

        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"latin-\u{E9}\"",
                body: Data([0])
            )
        ])
        let validScope = try await makeClient(tokens: tokens).validateGeneration(
            for: makeDescriptor(),
            tokens: tokens
        )
        XCTAssertEqual(
            validScope,
            .persistent(
                ValidatedContentGeneration(
                    provisionalKey: makeDescriptor().provisionalResourceKey,
                    totalLength: 16,
                    strongValidator: "\"latin-\u{E9}\""
                )
            )
        )
    }

    func testOffsetZeroWithoutRangeMayAccept200WithoutSystemCaching() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let body = Data([1, 2, 3, 4])
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 200,
                headers: [
                    "Content-Length": "4",
                    "ETag": "\"generation-a\"",
                ],
                bodyChunks: [body]
            )
        ])
        let client = makeClient(tokens: tokens)
        let descriptor = makeDescriptor(contentLength: 4)
        let request = makeRequest(
            tokens: tokens,
            descriptor: descriptor,
            range: nil,
            byteCeiling: 4
        )

        let chunks = try await collect(client.bytes(for: request))

        XCTAssertEqual(chunks.map(\.payload).reduce(Data(), +), body)
        XCTAssertTrue(
            chunks.allSatisfy {
                $0.generationScope == .attemptOnly(
                    sessionID: tokens.sessionID,
                    sourceAttemptID: tokens.currentSourceAttempt.id,
                    totalLength: 4
                )
            }
        )
        XCTAssertNil(MediaURLProtocolStub.capturedRequests[0].value(forHTTPHeaderField: "Range"))
        XCTAssertNil(MediaHTTPClient.testingConfiguration(
            protocolClass: MediaURLProtocolStub.self
        ).urlCache)
    }

    func testNoRange200RejectsKnownDescriptorLengthMismatchAtHeaders() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 200,
                headers: ["Content-Length": "4"]
            )
        ])
        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: nil, byteCeiling: 16)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .invalidResponse)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
    }

    func testNonzeroRangeReturning200IsStructuralFailureAndExposesNoBytes() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 200,
                headers: ["Content-Length": "4"]
            )
        ])
        let client = makeClient(tokens: tokens)

        let result = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 4..<8))
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .rangeIgnored)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
    }

    func testOffsetZeroRangeReturning200IsAlsoStructuralFailure() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 200,
                headers: ["Content-Length": "4"]
            )
        ])

        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .rangeIgnored)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
    }

    func testEveryUnsupportedStatusExposesNoBytesAndAccountsOnlyDeliveredBody() async {
        let cases: [(status: Int, body: Data)] = [
            (201, Data([1, 2])),
            (204, Data()),
            (304, Data()),
            (400, Data([3, 4])),
            (503, Data([5, 6])),
        ]

        for testCase in cases {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [
                .init(
                    statusCode: testCase.status,
                    headers: ["Content-Length": "\(testCase.body.count)"]
                )
            ])

            let result = await collectResult(
                makeClient(tokens: tokens).bytes(
                    for: makeRequest(tokens: tokens, range: 0..<4)
                )
            )

            XCTAssertTrue(result.chunks.isEmpty, "status \(testCase.status)")
            XCTAssertEqual(
                result.error as? MediaTransportError,
                .unsupportedStatus(
                    testCase.status,
                    cumulativeResponseBodyBytes: 0
                )
            )
            XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0)
            XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
        }
    }

    func testNotModifiedWithLocationIsNotTreatedAsRedirect() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 304,
                headers: ["Location": "https://media.example.test/next"]
            )
        ])

        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(
            result.error as? MediaTransportError,
            .unsupportedStatus(304, cumulativeResponseBodyBytes: 0)
        )
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 1)
    }

    func testMalformedMismatchedAndOverflowingContentRangesExposeNoBytes() async {
        let invalidValues = [
            "bytes 3-7/16",
            "bytes 4-8/16",
            "bytes 4-7/17",
            "bytes 4-3/16",
            "bytes 4-9223372036854775807/16",
            "bytes nope",
            "items 4-7/16",
        ]

        for value in invalidValues {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": value,
                        "Content-Length": "4",
                        "ETag": "\"generation-a\"",
                    ]
                )
            ])
            let result = await collectResult(
                makeClient(tokens: tokens).bytes(
                    for: makeRequest(tokens: tokens, range: 4..<8)
                )
            )

            XCTAssertTrue(result.chunks.isEmpty, value)
            XCTAssertEqual(result.error as? MediaTransportError, .invalidContentRange, value)
            XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0, value)
            XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0, value)
        }
    }

    func testHeaderKnownStructuralFailureRejectsWithoutBodyExposure() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let body = Data(repeating: 0xA5, count: 64 * 1024)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 200,
                headers: ["Content-Length": "\(body.count)"]
            )
        ])
        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 4..<8)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .rangeIgnored)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
    }

    func testEveryHeaderKnownFailureRejectsWithoutBodyExposure() async throws {
        let body = Data(repeating: 0x5A, count: 16 * 1024)
        let fixtures: [
            (
                name: String,
                response: MediaURLProtocolStub.Response,
                range: Range<Int64>,
                error: MediaTransportError
            )
        ] = [
            (
                "range ignored",
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "\(body.count)"]
                ),
                4..<8,
                .rangeIgnored
            ),
            (
                "malformed content range",
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes malformed",
                        "Content-Length": "\(body.count)",
                    ]
                ),
                4..<8,
                .invalidContentRange
            ),
            (
                "transformed encoding",
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 4-7/16",
                        "Content-Length": "4",
                        "Content-Encoding": "gzip",
                    ]
                ),
                4..<8,
                .transformedContentEncoding
            ),
            (
                "unsupported status",
                .init(
                    statusCode: 503,
                    headers: ["Content-Length": "\(body.count)"]
                ),
                4..<8,
                .unsupportedStatus(503, cumulativeResponseBodyBytes: 0)
            ),
            (
                "consistent eof",
                .init(
                    statusCode: 416,
                    headers: [
                        "Content-Range": "bytes */16",
                        "Content-Length": "\(body.count)",
                    ]
                ),
                16..<20,
                .endOfResource(totalLength: 16, cumulativeResponseBodyBytes: 0)
            ),
        ]

        for fixture in fixtures {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [fixture.response])
            let result = await collectResult(
                makeClient(tokens: tokens).bytes(
                    for: makeRequest(tokens: tokens, range: fixture.range)
                )
            )

            XCTAssertTrue(result.chunks.isEmpty, fixture.name)
            XCTAssertEqual(result.error as? MediaTransportError, fixture.error, fixture.name)
            XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0, fixture.name)
            XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0, fixture.name)
        }

        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let client = makeClient(tokens: tokens)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([0])
            )
        ])
        _ = try await client.validateGeneration(for: makeDescriptor(), tokens: tokens)

        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-3/16",
                    "Content-Length": "4",
                    "ETag": "\"generation-b\"",
                ]
            )
        ])
        let result = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .generationChanged)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 1)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
    }

    func testConsistent416IsEndOfResourceAndInconsistent416IsStructural() async {
        let cases: [(String, MediaTransportError)] = [
            (
                "bytes */16",
                .endOfResource(totalLength: 16, cumulativeResponseBodyBytes: 0)
            ),
            ("bytes */17", .invalidContentRange),
            ("bytes 0-0/16", .invalidContentRange),
        ]

        for (contentRange, expectedError) in cases {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [
                .init(statusCode: 416, headers: ["Content-Range": contentRange])
            ])
            let result = await collectResult(
                makeClient(tokens: tokens).bytes(
                    for: makeRequest(tokens: tokens, range: 16..<20)
                )
            )

            XCTAssertTrue(result.chunks.isEmpty)
            XCTAssertEqual(result.error as? MediaTransportError, expectedError)
        }


        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(statusCode: 416, headers: ["Content-Range": "bytes */16"])
        ])
        let premature = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 4..<8)
            )
        )
        XCTAssertEqual(premature.error as? MediaTransportError, .invalidContentRange)
    }

    func testGenerationProbeRejectsAndAccountsMoreThanOneResponseByte() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-0/16",
                    "ETag": "\"generation-a\"",
                ],
                bodyChunks: [Data([1, 2])]
            )
        ])

        do {
            _ = try await makeClient(tokens: tokens).validateGeneration(
                for: makeDescriptor(),
                tokens: tokens
            )
            XCTFail("An oversized generation probe must fail closed")
        } catch {
            XCTAssertEqual(
                error as? MediaTransportError,
                .byteCeilingExceeded(ceiling: 1, cumulativeResponseBodyBytes: 2)
            )
            XCTAssertEqual(error.accountedResponseBodyBytes, 2)
        }
    }

    func testFailedGenerationProbesNeverCommitAuthoritativeValidator() async {
        let failedProbes: [(name: String, response: MediaURLProtocolStub.Response)] = [
            (
                "oversized",
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/16",
                        "ETag": "\"generation-a\"",
                    ],
                    bodyChunks: [Data([1, 2])]
                )
            ),
            (
                "truncated",
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/16",
                        "Content-Length": "1",
                        "ETag": "\"generation-a\"",
                    ]
                )
            ),
            (
                "cancelled",
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/16",
                        "Content-Length": "1",
                        "ETag": "\"generation-a\"",
                    ],
                    bodyChunks: [Data([1])],
                    error: URLError(.cancelled)
                )
            ),
        ]

        for failedProbe in failedProbes {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [
                failedProbe.response,
                validPartialResponse(
                    range: 0..<1,
                    total: 16,
                    etag: "\"generation-b\"",
                    body: Data([2])
                ),
            ])
            let client = makeClient(tokens: tokens)

            do {
                _ = try await client.validateGeneration(for: makeDescriptor(), tokens: tokens)
                XCTFail("\(failedProbe.name) probe must fail")
            } catch {}

            do {
                let scope = try await client.validateGeneration(
                    for: makeDescriptor(),
                    tokens: tokens
                )
                XCTAssertEqual(
                    scope,
                    .persistent(
                        ValidatedContentGeneration(
                            provisionalKey: makeDescriptor().provisionalResourceKey,
                            totalLength: 16,
                            strongValidator: "\"generation-b\""
                        )
                    ),
                    failedProbe.name
                )
            } catch {
                XCTFail("\(failedProbe.name) poisoned the next probe: \(error)")
            }
        }
    }

    func testFailedOrdinaryResponsesNeverCommitAuthoritativeValidator() async {
        let failedResponses: [
            (name: String, range: Range<Int64>?, response: MediaURLProtocolStub.Response)
        ] = [
            (
                "truncated",
                0..<4,
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-3/16",
                        "Content-Length": "4",
                        "ETag": "\"generation-a\"",
                    ],
                    bodyChunks: [Data([1, 2])]
                )
            ),
            (
                "cancelled",
                0..<4,
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-3/16",
                        "Content-Length": "4",
                        "ETag": "\"generation-a\"",
                    ],
                    bodyChunks: [Data([1, 2])],
                    error: URLError(.cancelled)
                )
            ),
            (
                "truncated origin 200",
                nil,
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "4"],
                    bodyChunks: [Data([1, 2])]
                )
            ),
        ]

        for failedResponse in failedResponses {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [
                failedResponse.response,
                validPartialResponse(
                    range: 0..<4,
                    total: 16,
                    etag: "\"generation-b\"",
                    body: Data([4, 5, 6, 7])
                ),
            ])
            let client = makeClient(tokens: tokens)

            let failed = await collectResult(
                client.bytes(for: makeRequest(tokens: tokens, range: failedResponse.range))
            )
            XCTAssertNotNil(failed.error, failedResponse.name)

            let recovered = await collectResult(
                client.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
            )
            XCTAssertNil(recovered.error, failedResponse.name)
            XCTAssertEqual(
                recovered.chunks.map(\.payload).reduce(Data(), +),
                Data([4, 5, 6, 7]),
                failedResponse.name
            )
            XCTAssertEqual(
                recovered.chunks.last?.generationScope,
                .persistent(
                    ValidatedContentGeneration(
                        provisionalKey: makeDescriptor().provisionalResourceKey,
                        totalLength: 16,
                        strongValidator: "\"generation-b\""
                    )
                ),
                failedResponse.name
            )
        }
    }

    func testTransformedContentEncodingFailsBeforeAnyYield() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        var response = validPartialResponse(
            range: 0..<4,
            total: 16,
            body: Data([1, 2, 3, 4])
        )
        response = .init(
            statusCode: response.statusCode,
            headers: response.headers.merging(["Content-Encoding": "gzip"]) { _, new in new },
            bodyChunks: []
        )
        MediaURLProtocolStub.reset(responses: [response])

        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .transformedContentEncoding)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
    }

    func testStrongValidatorChangeWithinAttemptIsStructuralAndIfRangeIsExact() async throws {
        let descriptor = makeDescriptor()
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([0])
            ),
            validPartialResponse(
                range: 4..<8,
                total: 16,
                etag: "\"generation-b\"",
                body: Data([4, 5, 6, 7])
            ),
        ])
        let client = makeClient(tokens: tokens)
        _ = try await client.validateGeneration(for: descriptor, tokens: tokens)

        let result = await collectResult(
            client.bytes(
                for: MediaByteRequest(
                    descriptor: descriptor,
                    range: 4..<8,
                    ifRangeValidator: "\"generation-a\"",
                    purpose: .media,
                    byteCeiling: 4,
                    tokens: tokens
                )
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .generationChanged)
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests.last?.value(forHTTPHeaderField: "If-Range"),
            "\"generation-a\""
        )
    }

    func testPersistentGenerationRejectsMissingAndWeakETagOnLaterResponse() async throws {
        for laterETag in [nil, "W/\"weak\"", "unquoted", "\"\""] as [String?] {
            let descriptor = makeDescriptor()
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            var laterHeaders = [
                "Content-Range": "bytes 4-7/16",
                "Content-Length": "4",
            ]
            laterHeaders["ETag"] = laterETag
            MediaURLProtocolStub.reset(responses: [
                validPartialResponse(
                    range: 0..<1,
                    total: 16,
                    etag: "\"generation-a\"",
                    body: Data([0])
                ),
                .init(
                    statusCode: 206,
                    headers: laterHeaders,
                    bodyChunks: [Data([4, 5, 6, 7])]
                ),
            ])
            let client = makeClient(tokens: tokens)
            _ = try await client.validateGeneration(for: descriptor, tokens: tokens)

            let result = await collectResult(
                client.bytes(for: makeRequest(tokens: tokens, range: 4..<8))
            )

            XCTAssertTrue(result.chunks.isEmpty)
            XCTAssertEqual(result.error as? MediaTransportError, .generationChanged)
        }
    }

    func testStoredStrongValidatorOverridesUntrustedCallerIfRange() async throws {
        let descriptor = makeDescriptor()
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([0])
            ),
            validPartialResponse(
                range: 4..<8,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([4, 5, 6, 7])
            ),
        ])
        let client = makeClient(tokens: tokens)
        _ = try await client.validateGeneration(for: descriptor, tokens: tokens)

        _ = try await collect(
            client.bytes(
                for: MediaByteRequest(
                    descriptor: descriptor,
                    range: 4..<8,
                    ifRangeValidator: "\"caller-must-not-win\"",
                    purpose: .media,
                    byteCeiling: 4,
                    tokens: tokens
                )
            )
        )

        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests.last?.value(forHTTPHeaderField: "If-Range"),
            "\"generation-a\""
        )
    }

    func testLargeProtocolDeliveryIsSplitIntoBoundedChunks() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let body = Data((0..<10).map(UInt8.init))
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<10, total: 16, body: body)
        ])
        let client = makeClient(tokens: tokens, maximumChunkBytes: 4)

        let chunks = try await collect(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<10, byteCeiling: 10))
        )

        XCTAssertEqual(chunks.map(\.payload.count), [4, 4, 2])
        XCTAssertEqual(chunks.map(\.absoluteRange), [0..<4, 4..<8, 8..<10])
        XCTAssertEqual(chunks.map(\.cumulativeResponseBodyBytes), [10, 10, 10])
        XCTAssertEqual(chunks.map(\.payload).reduce(Data(), +), body)
        XCTAssertTrue(chunks.allSatisfy { $0.payload.count <= 4 })
    }

    func testAuthorizationIsRecheckedBeforeEveryYieldSplitFromOneCallback() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let validator = SequencedTokenValidator(validCallCount: 4)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<8,
                total: 16,
                body: Data([0, 1, 2, 3, 4, 5, 6, 7])
            )
        ])

        let result = await collectResult(
            makeClient(
                tokens: tokens,
                maximumChunkBytes: 4,
                tokenValidator: validator.accepts
            ).bytes(for: makeRequest(tokens: tokens, range: 0..<8))
        )

        XCTAssertEqual(result.chunks.map(\.payload), [Data([0, 1, 2, 3])])
        XCTAssertEqual(result.error as? MediaTransportError, .stalePlaybackTokens)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 8)
        XCTAssertGreaterThanOrEqual(validator.callCount, 5)
    }

    func testValidated206RangeLargerThanByteCeilingRejectsAtHeadersWithoutExposure() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-7/16",
                    "Content-Encoding": "identity",
                    "ETag": "\"generation-a\"",
                ]
            )
        ])

        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 0..<8, byteCeiling: 5)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(
            result.error as? MediaTransportError,
            .byteCeilingExceeded(ceiling: 5, cumulativeResponseBodyBytes: 0)
        )
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 0)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 0)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 1)
    }

    func testConsumerCancellationCancelsUnderlyingProtocolRequest() async {
        let requestStarted = expectation(description: "request started")
        let requestStopped = expectation(description: "request stopped")
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-3/16",
                        "Content-Length": "4",
                        "ETag": "\"generation-a\"",
                    ],
                    finish: false
                )
            ],
            onRequest: { _ in requestStarted.fulfill() },
            onStop: { requestStopped.fulfill() }
        )
        let client = makeClient(tokens: tokens)
        let stream = client.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        let consumer = Task {
            for try await _ in stream {}
        }

        await fulfillment(of: [requestStarted], timeout: 2)
        consumer.cancel()

        _ = try? await consumer.value
        await fulfillment(of: [requestStopped], timeout: 2)
        XCTAssertEqual(MediaURLProtocolStub.stoppedRequestCount, 1)
    }

    func testSlowConsumerTriggersBoundedBackpressureInsteadOfUnboundedBuffering() async {
        let requestStopped = expectation(description: "overflow cancels request")
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let overflowChunkCount = MediaHTTPClient.maximumBufferedChunkCount + 3
        MediaURLProtocolStub.reset(
            responses: [
                validPartialResponse(
                    range: 0..<Int64(overflowChunkCount),
                    total: 16,
                    bodyChunks: (0..<overflowChunkCount).map { Data([UInt8($0)]) }
                )
            ],
            onStop: { requestStopped.fulfill() }
        )
        let stream = makeClient(tokens: tokens, maximumChunkBytes: 1).bytes(
            for: makeRequest(tokens: tokens, range: 0..<Int64(overflowChunkCount))
        )

        await fulfillment(of: [requestStopped], timeout: 2)
        let result = await collectResult(stream)

        XCTAssertLessThanOrEqual(result.chunks.count, MediaHTTPClient.maximumBufferedChunkCount)
        XCTAssertEqual(
            result.error as? MediaTransportError,
            .backpressureExceeded(
                maximumBufferedChunks: MediaHTTPClient.maximumBufferedChunkCount,
                cumulativeResponseBodyBytes: Int64(overflowChunkCount)
            )
        )
        XCTAssertGreaterThan(
            result.error?.accountedResponseBodyBytes ?? 0,
            Int64(MediaHTTPClient.maximumBufferedChunkCount)
        )
        XCTAssertLessThanOrEqual(
            result.error?.accountedResponseBodyBytes ?? .max,
            Int64(overflowChunkCount)
        )
    }

    func testStaleKillSwitchEpochAndTokensRejectBeforeNetwork() async {
        let validTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let staleTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let featureStore = PlaybackFeatureSnapshotStore(initial: enabledSnapshot(epoch: epoch + 1))
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<4, total: 16, body: Data(repeating: 1, count: 4))
        ])

        let epochResult = await collectResult(
            makeClient(tokens: validTokens, featureStore: featureStore).bytes(
                for: makeRequest(tokens: validTokens, range: 0..<4)
            )
        )
        XCTAssertEqual(epochResult.error as? MediaTransportError, .staleKillSwitchEpoch)

        featureStore.update(enabledSnapshot(epoch: epoch))
        let tokenResult = await collectResult(
            makeClient(tokens: validTokens, featureStore: featureStore).bytes(
                for: makeRequest(tokens: staleTokens, range: 0..<4)
            )
        )
        XCTAssertEqual(tokenResult.error as? MediaTransportError, .stalePlaybackTokens)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 0)
    }

    func testTokenInvalidationAtResponseHeadersPrecedesGenerationMutation() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let replacement = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let tokenState = MutableTokenState(tokens)
        let client = makeClient(tokens: tokens, tokenValidator: tokenState.accepts)
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/16",
                        "Content-Length": "1",
                        "ETag": "\"generation-a\"",
                    ]
                )
            ],
            beforeResponse: { _ in tokenState.replace(with: replacement) }
        )

        let rejected = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<1))
        )

        XCTAssertTrue(rejected.chunks.isEmpty)
        XCTAssertEqual(rejected.error as? MediaTransportError, .stalePlaybackTokens)

        tokenState.replace(with: tokens)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"generation-b\"",
                body: Data([2])
            )
        ])
        let recovered = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<1))
        )

        XCTAssertNil(recovered.error)
        XCTAssertEqual(recovered.chunks.map(\.payload), [Data([2])])
    }

    func testEpochInvalidationAtResponseHeadersPrecedesGenerationMutation() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let featureStore = PlaybackFeatureSnapshotStore(initial: enabledSnapshot(epoch: epoch))
        let client = makeClient(tokens: tokens, featureStore: featureStore)
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-0/16",
                        "Content-Length": "1",
                        "ETag": "\"generation-a\"",
                    ]
                )
            ],
            beforeResponse: { _ in
                featureStore.update(self.enabledSnapshot(epoch: self.epoch + 1))
            }
        )

        let rejected = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<1))
        )

        XCTAssertTrue(rejected.chunks.isEmpty)
        XCTAssertEqual(rejected.error as? MediaTransportError, .staleKillSwitchEpoch)

        featureStore.update(enabledSnapshot(epoch: epoch))
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"generation-b\"",
                body: Data([2])
            )
        ])
        let recovered = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<1))
        )

        XCTAssertNil(recovered.error)
        XCTAssertEqual(recovered.chunks.map(\.payload), [Data([2])])
    }

    func testInvalidRangeAndByteCeilingFailBeforeNetwork() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let invalidRequests = [
            makeRequest(tokens: tokens, range: -1..<4),
            makeRequest(tokens: tokens, range: 4..<4),
            MediaByteRequest(
                descriptor: makeDescriptor(),
                range: 0..<4,
                ifRangeValidator: nil,
                purpose: .media,
                byteCeiling: 0,
                tokens: tokens
            ),
            MediaByteRequest(
                descriptor: makeDescriptor(),
                range: 0..<4,
                ifRangeValidator: nil,
                purpose: .media,
                byteCeiling: -1,
                tokens: tokens
            ),
        ]
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4]))
        ])
        let client = makeClient(tokens: tokens)

        for request in invalidRequests {
            let result = await collectResult(client.bytes(for: request))
            XCTAssertTrue(result.chunks.isEmpty)
            XCTAssertEqual(result.error as? MediaTransportError, .invalidRequest)
        }
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 0)
    }

    func testGenerationProbeShapeIsFixedAndFailsBeforeNetwork() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let invalidShapes: [(range: Range<Int64>?, ceiling: Int64?)] = [
            (nil, 1),
            (1..<2, 1),
            (0..<2, 1),
            (0..<1, nil),
            (0..<1, 2),
        ]
        MediaURLProtocolStub.reset()
        let client = makeClient(tokens: tokens)

        for shape in invalidShapes {
            let result = await collectResult(
                client.bytes(
                    for: MediaByteRequest(
                        descriptor: makeDescriptor(),
                        range: shape.range,
                        ifRangeValidator: nil,
                        purpose: .generationProbe,
                        byteCeiling: shape.ceiling,
                        tokens: tokens
                    )
                )
            )
            XCTAssertTrue(result.chunks.isEmpty)
            XCTAssertEqual(result.error as? MediaTransportError, .invalidRequest)
        }

        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 0)
    }

    func testEnabledKillSwitchAtCurrentEpochRejectsMediaAndProbeBeforeNetwork() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let featureStore = PlaybackFeatureSnapshotStore(
            initial: enabledSnapshot(epoch: epoch, killSwitch: true)
        )
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<1, total: 16, body: Data([1]))
        ])
        let client = makeClient(tokens: tokens, featureStore: featureStore)

        let media = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )
        XCTAssertEqual(media.error as? MediaTransportError, .killSwitchEnabled)
        do {
            _ = try await client.validateGeneration(for: makeDescriptor(), tokens: tokens)
            XCTFail("Kill switch must reject the probe")
        } catch {
            XCTAssertEqual(error as? MediaTransportError, .killSwitchEnabled)
        }
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 0)
    }

    func testEpochChangeDuringResponseAccountsButDoesNotExposeLateChunk() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let snapshots = SequencedFeatureSnapshotProvider(
            valid: enabledSnapshot(epoch: epoch),
            stale: enabledSnapshot(epoch: epoch + 1),
            validCallCount: 4
        )
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<8,
                total: 16,
                body: Data([0, 1, 2, 3, 4, 5, 6, 7])
            )
        ])

        let result = await collectResult(
            makeClient(
                tokens: tokens,
                featureSnapshot: snapshots.snapshot,
                maximumChunkBytes: 4
            ).bytes(for: makeRequest(tokens: tokens, range: 0..<8))
        )

        XCTAssertEqual(result.chunks.map(\.payload), [Data([0, 1, 2, 3])])
        XCTAssertEqual(result.error as? MediaTransportError, .staleKillSwitchEpoch)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 8)
        XCTAssertGreaterThanOrEqual(snapshots.callCount, 5)
    }

    func testTokenChangeDuringResponseAccountsButDoesNotExposeLateChunk() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let validator = SequencedTokenValidator(validCallCount: 4)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<8,
                total: 16,
                body: Data([0, 1, 2, 3, 4, 5, 6, 7])
            )
        ])

        let result = await collectResult(
            makeClient(
                tokens: tokens,
                maximumChunkBytes: 4,
                tokenValidator: validator.accepts
            ).bytes(for: makeRequest(tokens: tokens, range: 0..<8))
        )

        XCTAssertEqual(result.chunks.map(\.payload), [Data([0, 1, 2, 3])])
        XCTAssertEqual(result.error as? MediaTransportError, .stalePlaybackTokens)
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 8)
        XCTAssertGreaterThanOrEqual(validator.callCount, 5)
    }

    func testStaleTokenRejectsGenerationProbeBeforeNetwork() async {
        let current = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let stale = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<1, total: 16, body: Data([1]))
        ])

        do {
            _ = try await makeClient(tokens: current).validateGeneration(
                for: makeDescriptor(),
                tokens: stale
            )
            XCTFail("Stale probe tokens must fail closed")
        } catch {
            XCTAssertEqual(error as? MediaTransportError, .stalePlaybackTokens)
        }
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 0)
    }

    func testTokenBecomingStaleInsideGenerationProbeRejectsTheProbeByte() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let validator = SequencedTokenValidator(validCallCount: 3)
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<1, total: 16, body: Data([1]))
        ])

        do {
            _ = try await makeClient(
                tokens: tokens,
                tokenValidator: validator.accepts
            ).validateGeneration(for: makeDescriptor(), tokens: tokens)
            XCTFail("A probe byte cannot outlive its playback tokens")
        } catch {
            XCTAssertEqual(error as? MediaTransportError, .stalePlaybackTokens)
            XCTAssertEqual(error.accountedResponseBodyBytes, 1)
            XCTAssertGreaterThanOrEqual(validator.callCount, 4)
        }
    }

    func testSameOriginHTTPSRedirectRequiresApprovalAndPreservesRequestIdentity() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let redirectURL = URL(string: "https://media.example.test/next?token=redirect%2Bvalue")!
        MediaURLProtocolStub.reset(responses: [
            redirectResponse(to: redirectURL, body: Data([9, 9])),
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
        ])
        let client = makeClient(
            tokens: tokens,
            redirectPolicy: .init(approvedOrigins: [
                .init(origin: URL(string: "https://media.example.test")!, headers: [:])
            ])
        )

        let chunks = try await collect(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<4, byteCeiling: 8))
        )

        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 2)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests[1].url?.absoluteString, redirectURL.absoluteString)
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests[1].value(forHTTPHeaderField: "Cookie"),
            secretHeaders()["Cookie"]
        )
        for (name, value) in secretHeaders() where
            name.caseInsensitiveCompare("Range") != .orderedSame
                && name.caseInsensitiveCompare("Accept-Encoding") != .orderedSame
        {
            XCTAssertEqual(
                MediaURLProtocolStub.capturedRequests[1].value(forHTTPHeaderField: name),
                value
            )
        }
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests[1].value(forHTTPHeaderField: "Range"),
            "bytes=0-3"
        )
        XCTAssertEqual(
            MediaURLProtocolStub.capturedRequests[1].value(forHTTPHeaderField: "Accept-Encoding"),
            "identity"
        )
        XCTAssertEqual(chunks.last?.cumulativeResponseBodyBytes, 6)
    }

    func testRedirectDeclaredLengthWithoutDeliveredBodyDoesNotConsumeCeiling() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let redirectURL = URL(string: "https://media.example.test/next")!
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 302,
                headers: [
                    "Location": redirectURL.absoluteString,
                    "Content-Length": "5",
                ],
                redirectURL: redirectURL
            ),
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
        ])

        let chunks = try await collect(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4, byteCeiling: 4)
            )
        )

        XCTAssertEqual(chunks.map(\.payload).reduce(Data(), +), Data([1, 2, 3, 4]))
        XCTAssertEqual(chunks.last?.cumulativeResponseBodyBytes, 4)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 4)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 2)
    }

    func testTargetDeclaredBodyLargerThanRemainingCeilingCancelsAtHeaders() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let redirectURL = URL(string: "https://media.example.test/next")!
        MediaURLProtocolStub.reset(responses: [
            redirectResponse(to: redirectURL, body: Data([9, 9])),
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-3/16",
                    "Content-Length": "4",
                    "Content-Encoding": "identity",
                    "ETag": "\"generation-a\"",
                ]
            )
        ])
        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4, byteCeiling: 5)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(
            result.error as? MediaTransportError,
            .byteCeilingExceeded(ceiling: 5, cumulativeResponseBodyBytes: 2)
        )
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 2)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 2)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 2)
    }

    func testRedirectBodyCountsTowardOneRequestByteCeiling() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let redirectURL = URL(string: "https://media.example.test/next")!
        MediaURLProtocolStub.reset(responses: [
            redirectResponse(to: redirectURL, body: Data(repeating: 9, count: 5)),
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
        ])

        let result = await collectResult(
            makeClient(tokens: tokens).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4, byteCeiling: 8)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(
            result.error as? MediaTransportError,
            .byteCeilingExceeded(ceiling: 8, cumulativeResponseBodyBytes: 5)
        )
        XCTAssertEqual(result.error?.accountedResponseBodyBytes, 5)
        XCTAssertEqual(MediaURLProtocolStub.emittedResponseBodyBytes, 9)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 2)
    }

    func testEpochChangeAtRedirectRejectsBeforeLaunchingTargetHop() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let featureStore = PlaybackFeatureSnapshotStore(initial: enabledSnapshot(epoch: epoch))
        let redirectURL = URL(string: "https://media.example.test/next")!
        MediaURLProtocolStub.reset(
            responses: [
                redirectResponse(to: redirectURL),
                validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
            ],
            beforeRedirect: { _ in
                featureStore.update(self.enabledSnapshot(epoch: self.epoch + 1))
            }
        )

        let result = await collectResult(
            makeClient(tokens: tokens, featureStore: featureStore).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .staleKillSwitchEpoch)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 1)
    }

    func testTokenChangeAtRedirectRejectsBeforeLaunchingTargetHop() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let tokenState = MutableTokenState(tokens)
        let redirectURL = URL(string: "https://media.example.test/next")!
        MediaURLProtocolStub.reset(
            responses: [
                redirectResponse(to: redirectURL),
                validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
            ],
            beforeRedirect: { _ in
                tokenState.replace(
                    with: ActivePlaybackTokens.freshSession(source: .rangeStream)
                )
            }
        )

        let result = await collectResult(
            makeClient(tokens: tokens, tokenValidator: tokenState.accepts).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4)
            )
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .stalePlaybackTokens)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 1)
    }

    func testSameOriginHTTPSRedirectWithoutExplicitApprovalIsDenied() async {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            redirectResponse(to: URL(string: "https://media.example.test/next")!),
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
        ])

        let result = await collectResult(
            makeClient(
                tokens: tokens,
                redirectPolicy: .init(approvedOrigins: [])
            ).bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )

        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.error as? MediaTransportError, .invalidRequest)
        XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 0)
    }

    func testCrossOriginRedirectStripsSensitiveHeadersAndRebuildsApprovedPolicy() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let redirectURL = URL(string: "https://cdn.example.test/object?sig=new%2Bsignature")!
        let targetHeaders = [
            "User-Agent": "approved-target-agent",
            "Origin": "https://music.youtube.com",
            "X-Goog-Visitor-Id": "approved-target-visitor",
        ]
        MediaURLProtocolStub.reset(responses: [
            redirectResponse(to: redirectURL),
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
        ])
        let policy = MediaRedirectPolicy(approvedOrigins: [
            .init(origin: URL(string: "https://media.example.test")!, headers: [:]),
            .init(origin: URL(string: "https://cdn.example.test")!, headers: targetHeaders),
        ])

        _ = try await collect(
            makeClient(tokens: tokens, redirectPolicy: policy).bytes(
                for: makeRequest(tokens: tokens, range: 0..<4)
            )
        )

        let redirected = try XCTUnwrap(MediaURLProtocolStub.capturedRequests.last)
        XCTAssertEqual(redirected.url?.absoluteString, redirectURL.absoluteString)
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "X-YouTube-Client-Name"))
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=0-3")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        for (name, value) in targetHeaders {
            XCTAssertEqual(redirected.value(forHTTPHeaderField: name), value)
        }
        XCTAssertNotEqual(
            redirected.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
            secretHeaders()["X-Goog-Visitor-Id"]
        )
    }

    func testHTTPUnknownAndCredentialBearingRedirectsFailBeforeTargetBody() async {
        let targets = [
            URL(string: "http://media.example.test/insecure")!,
            URL(string: "https://unknown.example.test/object")!,
            URL(string: "https://user:password@media.example.test/object")!,
        ]

        for target in targets {
            let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
            MediaURLProtocolStub.reset(responses: [
                redirectResponse(to: target, body: Data([8, 8, 8])),
                validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
            ])
            let result = await collectResult(
                makeClient(
                    tokens: tokens,
                    redirectPolicy: .init(approvedOrigins: [
                        .init(origin: URL(string: "https://media.example.test")!, headers: [:])
                    ])
                ).bytes(for: makeRequest(tokens: tokens, range: 0..<4))
            )

            XCTAssertTrue(result.chunks.isEmpty)
            XCTAssertEqual(result.error as? MediaTransportError, .unapprovedRedirect)
            XCTAssertEqual(MediaURLProtocolStub.capturedRequests.count, 1)
            XCTAssertEqual(result.error?.accountedResponseBodyBytes, 3)
        }
    }

    func testCumulativeAccountingIncludesRejectedRetryAndDuplicateBodies() async throws {
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-3/16",
                    "Content-Length": "4",
                    "ETag": "\"generation-a\"",
                ],
                bodyChunks: [Data([9, 9, 9])]
            ),
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4])),
        ])
        let client = makeClient(tokens: tokens)

        let rejected = await collectResult(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )
        XCTAssertEqual(rejected.chunks.map(\.payload), [Data([9, 9, 9])])
        XCTAssertEqual(rejected.error as? MediaTransportError, .invalidResponse)
        XCTAssertEqual(rejected.error?.accountedResponseBodyBytes, 3)

        let retry = try await collect(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )
        XCTAssertEqual(retry.last?.cumulativeResponseBodyBytes, 7)

        let duplicate = try await collect(
            client.bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )
        XCTAssertEqual(duplicate.last?.cumulativeResponseBodyBytes, 11)
    }

    func testFailureDiagnosticsAndDescriptionsNeverExposeSignedURLOrSecretHeaders() async {
        let recorder = DiagnosticRecorder()
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let secretValues = [
            "secret%2Bsignature",
            "secret-agent",
            "secret-origin",
            "secret-referer",
            "secret-cookie",
            "secret-visitor",
            "secret-authorization",
        ]
        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "malformed-secret%2Bsignature",
                    "Content-Encoding": "gzip",
                ],
                bodyChunks: [Data([1, 2, 3])]
            )
        ])
        let request = makeRequest(tokens: tokens, range: 0..<4)

        let result = await collectResult(
            makeClient(tokens: tokens, diagnostics: recorder.record).bytes(for: request)
        )
        let exported = ([
            request.description,
            String(describing: result.error),
        ] + recorder.messages).joined(separator: "|")

        for secret in secretValues {
            XCTAssertFalse(exported.contains(secret), secret)
        }
        XCTAssertFalse(exported.contains(signedURLString))
    }

    func testEveryFailureFamilyUsesOnlyRedactedDiagnostics() async {
        let recorder = DiagnosticRecorder()
        let tokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let client = makeClient(tokens: tokens, diagnostics: recorder.record)

        _ = await collectResult(client.bytes(for: makeRequest(tokens: tokens, range: -1..<4)))

        MediaURLProtocolStub.reset(responses: [
            .init(statusCode: 503, bodyChunks: [Data([1])])
        ])
        _ = await collectResult(client.bytes(for: makeRequest(tokens: tokens, range: 0..<4)))

        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 0-3/16",
                    "Content-Length": "4",
                    "Content-Encoding": "secret-cookie",
                ],
                bodyChunks: [Data([1, 2, 3, 4])]
            )
        ])
        _ = await collectResult(client.bytes(for: makeRequest(tokens: tokens, range: 0..<4)))

        MediaURLProtocolStub.reset(responses: [
            .init(
                statusCode: 206,
                headers: ["Content-Range": "secret%2Bsignature"],
                bodyChunks: [Data([1])]
            )
        ])
        _ = await collectResult(client.bytes(for: makeRequest(tokens: tokens, range: 0..<4)))

        MediaURLProtocolStub.reset(responses: [
            redirectResponse(to: URL(string: "https://unknown.example.test/secret%2Bsignature")!)
        ])
        _ = await collectResult(client.bytes(for: makeRequest(tokens: tokens, range: 0..<4)))

        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<1,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([0])
            ),
            validPartialResponse(
                range: 0..<4,
                total: 16,
                etag: "\"secret-visitor\"",
                body: Data([1, 2, 3, 4])
            ),
        ])
        _ = try? await client.validateGeneration(for: makeDescriptor(), tokens: tokens)
        _ = await collectResult(client.bytes(for: makeRequest(tokens: tokens, range: 0..<4)))

        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(range: 0..<4, total: 16, body: Data([1, 2, 3, 4]))
        ])
        _ = await collectResult(
            client.bytes(
                for: MediaByteRequest(
                    descriptor: makeDescriptor(),
                    range: 0..<4,
                    ifRangeValidator: nil,
                    purpose: .media,
                    byteCeiling: 1,
                    tokens: tokens
                )
            )
        )

        let staleStore = PlaybackFeatureSnapshotStore(initial: enabledSnapshot(epoch: epoch + 1))
        _ = await collectResult(
            makeClient(
                tokens: tokens,
                featureStore: staleStore,
                diagnostics: recorder.record
            ).bytes(for: makeRequest(tokens: tokens, range: 0..<4))
        )

        let overflowChunkCount = MediaHTTPClient.maximumBufferedChunkCount + 3
        let overflowStopped = expectation(description: "redaction overflow stopped")
        MediaURLProtocolStub.reset(
            responses: [
                validPartialResponse(
                    range: 0..<Int64(overflowChunkCount),
                    total: 16,
                    bodyChunks: (0..<overflowChunkCount).map { Data([UInt8($0)]) }
                )
            ],
            onStop: { overflowStopped.fulfill() }
        )
        let overflow = client.bytes(
            for: makeRequest(tokens: tokens, range: 0..<Int64(overflowChunkCount))
        )
        await fulfillment(of: [overflowStopped], timeout: 2)
        _ = await collectResult(overflow)

        let exported = recorder.messages.joined(separator: "|")
        XCTAssertGreaterThanOrEqual(recorder.messages.count, 8)
        for secret in secretHeaders().values {
            XCTAssertFalse(exported.contains(secret), secret)
        }
        XCTAssertFalse(exported.contains("secret%2Bsignature"))
        XCTAssertFalse(exported.contains("private-video-id"))
    }

    func testProductionSourceNeverUsesSharedURLSession() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let sourceURL = repositoryRoot.appendingPathComponent(
            "LovelyMusic/Core/Audio/Streaming/MediaHTTPClient.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("URLSession.shared"))
    }

    func testCancellationAndCompletionReleaseOwnedTaskSessionReferences() async throws {
        let completionTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let completionProbe = MediaResourceLifecycleProbe()
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<4,
                total: 16,
                body: Data([1, 2, 3, 4])
            )
        ])

        do {
            let client = makeClient(
                tokens: completionTokens,
                resourceObserver: { session, task in
                    completionProbe.observe(session: session, task: task)
                }
            )
            _ = try await collect(
                client.bytes(for: makeRequest(tokens: completionTokens, range: 0..<4))
            )
        }

        let completionResourcesReleased = await eventuallyReleases(completionProbe)
        XCTAssertTrue(
            completionResourcesReleased,
            "a completed request must break the session/delegate/task ownership cycle"
        )

        let cancellationTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        let cancellationProbe = MediaResourceLifecycleProbe()
        let bodyGate = MediaURLProtocolStub.BodyGate()
        let requestStarted = expectation(description: "cancellable request started")
        MediaURLProtocolStub.reset(
            responses: [
                .init(
                    statusCode: 206,
                    headers: [
                        "Content-Range": "bytes 0-3/16",
                        "Content-Length": "4",
                        "Content-Encoding": "identity",
                        "ETag": "\"generation-a\"",
                    ],
                    bodyChunks: [Data([1, 2, 3, 4])],
                    bodyGate: bodyGate
                )
            ],
            onRequest: { _ in requestStarted.fulfill() }
        )

        do {
            let client = makeClient(
                tokens: cancellationTokens,
                resourceObserver: { session, task in
                    cancellationProbe.observe(session: session, task: task)
                }
            )
            let stream = client.bytes(
                for: makeRequest(tokens: cancellationTokens, range: 0..<4)
            )
            let consumer = Task { try await self.collect(stream) }
            await fulfillment(of: [requestStarted], timeout: 1)
            consumer.cancel()
            _ = await consumer.result
        }
        bodyGate.release()

        let cancellationResourcesReleased = await eventuallyReleases(cancellationProbe)
        XCTAssertTrue(
            cancellationResourcesReleased,
            "a consumer-cancelled request must release both task and session"
        )
    }

    func testAccountingIsIsolatedBySessionAndSourceAttempt() async throws {
        let firstTokens = ActivePlaybackTokens.freshSession(source: .rangeStream)
        var secondTokens = firstTokens
        secondTokens.refreshCurrentSourceAttempt()
        MediaURLProtocolStub.reset(responses: [
            validPartialResponse(
                range: 0..<4,
                total: 16,
                etag: "\"generation-a\"",
                body: Data([1, 2, 3, 4])
            ),
            validPartialResponse(
                range: 0..<4,
                total: 16,
                etag: "\"generation-b\"",
                body: Data([5, 6, 7, 8])
            ),
        ])
        let client = makeClient(tokens: firstTokens, tokenValidator: { _ in true })

        let first = try await collect(
            client.bytes(for: makeRequest(tokens: firstTokens, range: 0..<4))
        )
        let second = try await collect(
            client.bytes(for: makeRequest(tokens: secondTokens, range: 0..<4))
        )

        XCTAssertEqual(first.last?.cumulativeResponseBodyBytes, 4)
        XCTAssertEqual(second.last?.cumulativeResponseBodyBytes, 4)
    }
}

private extension MediaHTTPClientTests {
    struct StreamResult {
        var chunks: [ValidatedMediaChunk]
        var error: Error?
    }

    func makeClient(
        tokens: ActivePlaybackTokens,
        configuration: URLSessionConfiguration? = nil,
        featureStore: PlaybackFeatureSnapshotStore? = nil,
        featureSnapshot: (@Sendable () -> PlaybackFeatureSnapshot)? = nil,
        redirectPolicy: MediaRedirectPolicy? = nil,
        maximumChunkBytes: Int = 64 * 1024,
        tokenValidator: (@Sendable (ActivePlaybackTokens) -> Bool)? = nil,
        receivedBodyByteCount: @escaping @Sendable (URLSessionTask) -> Int64 = { _ in
            MediaURLProtocolStub.emittedResponseBodyBytes
        },
        resourceObserver: @escaping @Sendable (URLSession, URLSessionDataTask) -> Void = {
            _, _ in
        },
        diagnostics: @escaping @Sendable (MediaTransportDiagnostic) -> Void = { _ in }
    ) -> MediaHTTPClient {
        let store = featureStore
            ?? PlaybackFeatureSnapshotStore(initial: enabledSnapshot(epoch: epoch))
        return MediaHTTPClient(
            configuration: configuration
                ?? MediaHTTPClient.testingConfiguration(
                    protocolClass: MediaURLProtocolStub.self
                ),
            redirectPolicy: redirectPolicy
                ?? .init(approvedOrigins: [
                    .init(origin: URL(string: "https://media.example.test")!, headers: [:])
                ]),
            authorizedKillSwitchEpoch: epoch,
            featureSnapshot: featureSnapshot ?? store.snapshot,
            tokenValidator: tokenValidator ?? { $0 == tokens },
            maximumChunkBytes: maximumChunkBytes,
            receivedBodyByteCount: receivedBodyByteCount,
            resourceObserver: resourceObserver,
            diagnosticSink: diagnostics
        )
    }

    func eventuallyReleases(_ probe: MediaResourceLifecycleProbe) async -> Bool {
        for _ in 0..<10_000 {
            if probe.resourcesReleased { return true }
            await Task.yield()
        }
        return probe.resourcesReleased
    }

    func makeDescriptor(
        headers: [String: String]? = nil,
        videoID: String = "private-video-id",
        remoteURLString: String? = nil,
        contentLength: Int64? = 16
    ) -> StreamDescriptor {
        StreamDescriptor(
            videoID: videoID,
            remoteURL: URL(string: remoteURLString ?? signedURLString)!,
            itag: 140,
            mimeType: "audio/mp4",
            codec: "mp4a.40.2",
            bitrate: 128_000,
            contentLength: contentLength,
            duration: .seconds(1),
            initializationRange: 0..<4,
            indexRange: 4..<8,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            requestHeaders: headers ?? secretHeaders(),
            provisionalResourceKey: ProvisionalResourceKey(
                videoID: videoID,
                itag: 140,
                codec: "mp4a.40.2",
                declaredTotalLength: contentLength
            )
        )
    }

    func secretHeaders() -> [String: String] {
        [
            "User-Agent": "secret-agent",
            "Origin": "https://secret-origin.example",
            "Referer": "https://secret-referer.example/path",
            "Cookie": "SID=secret-cookie",
            "X-Goog-Visitor-Id": "secret-visitor",
            "Authorization": "Bearer secret-authorization",
            "X-YouTube-Client-Name": "secret-client-name",
            "Range": "bytes=999-1000",
            "Accept-Encoding": "br",
        ]
    }

    func makeRequest(
        tokens: ActivePlaybackTokens,
        descriptor: StreamDescriptor? = nil,
        range: Range<Int64>?,
        byteCeiling: Int64? = nil
    ) -> MediaByteRequest {
        MediaByteRequest(
            descriptor: descriptor ?? makeDescriptor(),
            range: range,
            ifRangeValidator: nil,
            purpose: .media,
            byteCeiling: byteCeiling,
            tokens: tokens
        )
    }

    func enabledSnapshot(
        epoch: UInt64,
        killSwitch: Bool = false
    ) -> PlaybackFeatureSnapshot {
        PlaybackFeatureSnapshot(
            rangeStreamingV1: true,
            cohortPercent: 100,
            boundedPreloadV1: false,
            killSwitch: killSwitch,
            killSwitchEpoch: epoch,
            loaderVersion: PlaybackFeatureSnapshot.supportedLoaderVersion,
            headerSchemaVersion: PlaybackFeatureSnapshot.supportedHeaderSchemaVersion
        )
    }

    func validPartialResponse(
        range: Range<Int64>,
        total: Int64,
        etag: String = "\"generation-a\"",
        body: Data
    ) -> MediaURLProtocolStub.Response {
        validPartialResponse(range: range, total: total, etag: etag, bodyChunks: [body])
    }

    func validPartialResponse(
        range: Range<Int64>,
        total: Int64,
        etag: String = "\"generation-a\"",
        bodyChunks: [Data],
        bodyChunkGates: [MediaURLProtocolStub.BodyGate?] = [],
        includesContentLength: Bool = true
    ) -> MediaURLProtocolStub.Response {
        var headers = [
            "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)",
            "ETag": etag,
            "Content-Encoding": "identity",
        ]
        if includesContentLength {
            headers["Content-Length"] = "\(range.count)"
        }
        return .init(
            statusCode: 206,
            headers: headers,
            bodyChunks: bodyChunks,
            bodyChunkGates: bodyChunkGates
        )
    }

    func redirectResponse(to url: URL, body: Data = Data()) -> MediaURLProtocolStub.Response {
        .init(
            statusCode: 302,
            headers: [
                "Location": url.absoluteString,
                "Content-Length": "\(body.count)",
            ],
            bodyChunks: body.isEmpty ? [] : [body],
            redirectURL: url
        )
    }

    func collect(
        _ stream: AsyncThrowingStream<ValidatedMediaChunk, Error>
    ) async throws -> [ValidatedMediaChunk] {
        var chunks: [ValidatedMediaChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    func collectResult(
        _ stream: AsyncThrowingStream<ValidatedMediaChunk, Error>
    ) async -> StreamResult {
        var chunks: [ValidatedMediaChunk] = []
        do {
            for try await chunk in stream {
                chunks.append(chunk)
            }
            return StreamResult(chunks: chunks, error: nil)
        } catch {
            return StreamResult(chunks: chunks, error: error)
        }
    }
}

private final class MediaResourceLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: URLSession?
    private weak var task: URLSessionTask?

    var resourcesReleased: Bool {
        lock.withLock { session == nil && task == nil }
    }

    func observe(session: URLSession, task: URLSessionDataTask) {
        lock.withLock {
            self.session = session
            self.task = task
        }
    }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.withLock { storage }
    }

    func record(_ diagnostic: MediaTransportDiagnostic) {
        lock.withLock {
            storage.append(diagnostic.description)
        }
    }
}

private final class MutableTokenState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ActivePlaybackTokens

    init(_ current: ActivePlaybackTokens) {
        self.current = current
    }

    func accepts(_ tokens: ActivePlaybackTokens) -> Bool {
        lock.withLock { current == tokens }
    }

    func replace(with tokens: ActivePlaybackTokens) {
        lock.withLock { current = tokens }
    }
}

private final class SequencedTokenValidator: @unchecked Sendable {
    private let lock = NSLock()
    private let validCallCount: Int
    private var calls = 0

    init(validCallCount: Int) {
        self.validCallCount = validCallCount
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func accepts(_: ActivePlaybackTokens) -> Bool {
        lock.withLock {
            calls += 1
            return calls <= validCallCount
        }
    }
}

private final class SequencedFeatureSnapshotProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let valid: PlaybackFeatureSnapshot
    private let stale: PlaybackFeatureSnapshot
    private let validCallCount: Int
    private var calls = 0

    init(
        valid: PlaybackFeatureSnapshot,
        stale: PlaybackFeatureSnapshot,
        validCallCount: Int
    ) {
        self.valid = valid
        self.stale = stale
        self.validCallCount = validCallCount
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func snapshot() -> PlaybackFeatureSnapshot {
        lock.withLock {
            calls += 1
            return calls <= validCallCount ? valid : stale
        }
    }
}

private extension Error {
    var accountedResponseBodyBytes: Int64? {
        (self as? MediaTransportError)?.cumulativeResponseBodyBytes
    }
}
