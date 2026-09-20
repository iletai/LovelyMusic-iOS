import Foundation
import XCTest

@testable import LovelyMusic

final class StreamDescriptorResolverTests: XCTestCase {
    private let playerAACRangesFixtureName = "player-aac-ranges"
    private let signedURL =
        "https://example.test/videoplayback?sig=a%2Bb&x=1&x=2&range=7-9"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testPlayerAACRangesFixtureResolvesImmutableDescriptorWithoutRebuildingURL() throws {
        let descriptor = try resolveDescriptor(from: playerAACRangesFixture())

        XCTAssertEqual(playerAACRangesFixtureName, "player-aac-ranges")
        XCTAssertEqual(descriptor.videoID, "sensitive-video-id")
        XCTAssertEqual(descriptor.remoteURL.absoluteString, signedURL)
        XCTAssertEqual(descriptor.itag, 140)
        XCTAssertEqual(descriptor.mimeType, "audio/mp4")
        XCTAssertEqual(descriptor.codec, "mp4a.40.2")
        XCTAssertEqual(descriptor.bitrate, 128_000)
        XCTAssertEqual(descriptor.contentLength, 4_000_000)
        XCTAssertEqual(descriptor.duration, .milliseconds(245_678))
        XCTAssertEqual(descriptor.initializationRange, 0..<700)
        XCTAssertEqual(descriptor.indexRange, 700..<1_200)
        XCTAssertEqual(descriptor.expiresAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(descriptor.requestHeaders, ["Origin": "https://music.youtube.com"])
        XCTAssertEqual(
            descriptor.provisionalResourceKey,
            ProvisionalResourceKey(
                videoID: "sensitive-video-id",
                itag: 140,
                codec: "mp4a.40.2",
                declaredTotalLength: 4_000_000
            )
        )
    }

    func testMissingAndInvalidURLsAreTypedErrors() throws {
        try assertDescriptorError(.missingURL, mutatingFormat: { $0.removeValue(forKey: "url") })
        try assertDescriptorError(.invalidURL, mutatingFormat: { $0["url"] = "videoplayback?x=1" })
        try assertDescriptorError(.invalidURL, mutatingFormat: {
            $0["url"] = "https://example.test/signed path?sig=a%2Bb"
        })
    }

    func testOnlyHTTPAndHTTPSSchemesAreAcceptedWithoutRebuildingURL() throws {
        let acceptedURLs = [
            "http://example.test/videoplayback?sig=a%2Bb&x=1&x=2",
            signedURL,
        ]
        for rawURL in acceptedURLs {
            let descriptor = try resolveDescriptor(
                from: playerAACRangesFixture(mutatingFormat: { $0["url"] = rawURL })
            )
            XCTAssertEqual(descriptor.remoteURL.absoluteString, rawURL)
        }

        for rawURL in [
            "file:///tmp/audio.mp4",
            "ftp://example.test/audio.mp4",
            "custom+media://example.test/audio.mp4",
        ] {
            try assertDescriptorError(.invalidURL, mutatingFormat: { $0["url"] = rawURL })
        }
    }

    func testMissingAndInvalidMIMEOrCodecAreTypedErrors() throws {
        try assertDescriptorError(.missingMIMEType, mutatingFormat: {
            $0.removeValue(forKey: "mimeType")
        })
        try assertDescriptorError(.missingMIMEType, mutatingFormat: { $0["mimeType"] = "   " })

        for mime in [
            "audio/mp4",
            "audio/mp4; codecs=\"\"",
            "audio/mp4; codecs=\"mp4a.40.2",
            "audio/mp4; codecs=   ",
        ] {
            try assertDescriptorError(.missingCodec, mutatingFormat: { $0["mimeType"] = mime })
        }
    }

    func testMalformedMIMEBasesAreTypedErrors() throws {
        let malformedBases = [
            "audio",
            "audio/",
            "/mp4",
            "audio/mp4/extra",
            "audio//mp4",
            "aud io/mp4",
            "audio/mp@4",
        ]

        for base in malformedBases {
            try assertDescriptorError(.missingMIMEType, mutatingFormat: {
                $0["mimeType"] = "\(base); codecs=\"mp4a.40.2\""
            })
        }
    }

    func testMIMEBaseRejectsNonASCIIBeforeNormalization() throws {
        try assertDescriptorError(.missingMIMEType, mutatingFormat: {
            $0["mimeType"] = "audio/mK4; codecs=\"mp4a.40.2\""
        })
    }

    func testMalformedMIMEBaseQuoteIsRejectedBeforeParameterParsing() throws {
        try assertDescriptorError(.missingMIMEType, mutatingFormat: {
            $0["mimeType"] = "audio/mp\"4; codecs=\"mp4a.40.2\""
        })
    }

    func testMIMECodecParameterSupportsCaseOrderAndMultipleCodecs() throws {
        let cases = [
            ("audio/mp4; profile=music; CoDeCs=mp4a.40.2", "mp4a.40.2"),
            ("audio/mp4; CODECS=\"mp4a.40.2, mp4a.40.5\"; profile=music", "mp4a.40.2, mp4a.40.5"),
        ]

        for (mimeType, expectedCodec) in cases {
            let descriptor = try resolveDescriptor(
                from: playerAACRangesFixture(mutatingFormat: { $0["mimeType"] = mimeType })
            )
            XCTAssertEqual(descriptor.codec, expectedCodec)
        }
    }

    func testMIMEQuotedPairsAreUnescapedExactlyOnce() throws {
        let mimeType = #"audio/mp4; codecs="mp4a.40.2\"profile\\variant""#
        let descriptor = try resolveDescriptor(
            from: playerAACRangesFixture(mutatingFormat: { $0["mimeType"] = mimeType })
        )

        XCTAssertEqual(descriptor.codec, #"mp4a.40.2"profile\variant"#)
    }

    func testMIMERejectsEscapedTerminalQuoteWithoutAClosingQuote() throws {
        let mimeType = #"audio/mp4; codecs="mp4a.40.2\""#
        try assertDescriptorError(.missingCodec, mutatingFormat: { $0["mimeType"] = mimeType })
    }

    func testMalformedInitializationRangesRemainPresentAndAreTypedErrors() throws {
        let invalidRanges: [[String: Any]] = [
            ["end": "699"],
            ["start": "0"],
            ["start": "x", "end": "699"],
            ["start": "-1", "end": "699"],
            ["start": "700", "end": "699"],
            ["start": "0", "end": String(Int64.max)],
        ]

        for range in invalidRanges {
            try assertDescriptorError(.invalidInitializationRange, mutatingFormat: {
                $0["initRange"] = range
            })
        }
    }

    func testMissingAndNullRangeContainersRemainAbsent() throws {
        let missing = try resolveDescriptor(
            from: playerAACRangesFixture(mutatingFormat: {
                $0.removeValue(forKey: "initRange")
                $0.removeValue(forKey: "indexRange")
            })
        )
        XCTAssertNil(missing.initializationRange)
        XCTAssertNil(missing.indexRange)

        let null = try resolveDescriptor(
            from: playerAACRangesFixture(mutatingFormat: {
                $0["initRange"] = NSNull()
                $0["indexRange"] = NSNull()
            })
        )
        XCTAssertNil(null.initializationRange)
        XCTAssertNil(null.indexRange)
    }

    func testMalformedIndexRangeIsTypedError() throws {
        try assertDescriptorError(.invalidIndexRange, mutatingFormat: {
            $0["indexRange"] = ["start": "1200", "end": "700"]
        })
    }

    func testPresentNonpositiveAndMalformedContentLengthsAreTypedErrors() throws {
        for length in ["0", "-1", "four-million", "9223372036854775808"] {
            try assertDescriptorError(.invalidContentLength, mutatingFormat: {
                $0["contentLength"] = length
            })
        }
    }

    func testPresentInvalidDurationsAreTypedErrors() throws {
        for duration in ["-1", "invalid", "9223372036854775808"] {
            try assertDescriptorError(.invalidDuration, mutatingFormat: {
                $0["approxDurationMs"] = duration
            })
        }
    }

    func testBitrateMustBePositive() throws {
        for bitrate in [0, -1] {
            try assertDescriptorError(.invalidBitrate, mutatingFormat: {
                $0["bitrate"] = bitrate
            })
        }
    }

    func testDemoRepositoryRejectsRemoteDescriptorForLocalResource() async {
        let repository = DemoPlayerRepository()

        do {
            _ = try await repository.resolveStreamDescriptor(
                videoId: "demo-track",
                quality: .medium,
                requestHeaders: ["Origin": "https://caller.example"]
            )
            XCTFail("Expected local resources to be remote-range-ineligible")
        } catch {
            XCTAssertEqual(
                error as? StreamDescriptorError,
                .localResourceIsNotRemoteRangeEligible
            )
        }
    }

    func testProvisionalDigestIsDeterministicPrivateAndComponentSensitive() {
        let sensitiveVideoID = "raw-video-secret"
        let sensitiveCodec = "private-codec"
        let baseline = ProvisionalResourceKey(
            videoID: sensitiveVideoID,
            itag: 140,
            codec: sensitiveCodec,
            declaredTotalLength: 4_000_000
        )
        let repeated = ProvisionalResourceKey(
            videoID: sensitiveVideoID,
            itag: 140,
            codec: sensitiveCodec,
            declaredTotalLength: 4_000_000
        )

        XCTAssertEqual(baseline, repeated)
        assertPrivateSHA256(baseline.digest, excluding: [sensitiveVideoID, sensitiveCodec])
        XCTAssertNotEqual(
            baseline,
            ProvisionalResourceKey(
                videoID: sensitiveVideoID + "-changed",
                itag: 140,
                codec: sensitiveCodec,
                declaredTotalLength: 4_000_000
            )
        )
        XCTAssertNotEqual(
            baseline,
            ProvisionalResourceKey(
                videoID: sensitiveVideoID,
                itag: 141,
                codec: sensitiveCodec,
                declaredTotalLength: 4_000_000
            )
        )
        XCTAssertNotEqual(
            baseline,
            ProvisionalResourceKey(
                videoID: sensitiveVideoID,
                itag: 140,
                codec: sensitiveCodec + "-changed",
                declaredTotalLength: 4_000_000
            )
        )
        XCTAssertNotEqual(
            baseline,
            ProvisionalResourceKey(
                videoID: sensitiveVideoID,
                itag: 140,
                codec: sensitiveCodec,
                declaredTotalLength: nil
            )
        )
    }

    func testGenerationFingerprintsArePrivateDomainSeparatedAndAttemptScoped() {
        let provisional = ProvisionalResourceKey(
            videoID: "raw-video-secret",
            itag: 140,
            codec: "mp4a.40.2",
            declaredTotalLength: 4_000_000
        )
        let firstValidator = "validator-secret-A"
        let secondValidator = "validator-secret-B"
        let firstPersistent = ContentGenerationScope.persistent(
            ValidatedContentGeneration(
                provisionalKey: provisional,
                totalLength: 4_000_000,
                strongValidator: firstValidator
            )
        ).localFingerprint
        let repeatedPersistent = ContentGenerationScope.persistent(
            ValidatedContentGeneration(
                provisionalKey: provisional,
                totalLength: 4_000_000,
                strongValidator: firstValidator
            )
        ).localFingerprint
        let changedSameLengthValidator = ContentGenerationScope.persistent(
            ValidatedContentGeneration(
                provisionalKey: provisional,
                totalLength: 4_000_000,
                strongValidator: secondValidator
            )
        ).localFingerprint

        let sessionID = PlaybackSessionID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let firstAttempt = ContentGenerationScope.attemptOnly(
            sessionID: sessionID,
            sourceAttemptID: SourceAttemptID(
                rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            ),
            totalLength: 4_000_000
        ).localFingerprint
        let secondAttempt = ContentGenerationScope.attemptOnly(
            sessionID: sessionID,
            sourceAttemptID: SourceAttemptID(
                rawValue: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
            ),
            totalLength: 4_000_000
        ).localFingerprint

        XCTAssertEqual(firstPersistent, repeatedPersistent)
        XCTAssertNotEqual(firstPersistent, changedSameLengthValidator)
        XCTAssertNotEqual(firstAttempt, secondAttempt)
        XCTAssertNotEqual(firstPersistent, firstAttempt)
        assertPrivateSHA256(
            firstPersistent.digest,
            excluding: ["raw-video-secret", firstValidator, secondValidator]
        )
        assertPrivateSHA256(firstAttempt.digest, excluding: [sessionID.rawValue.uuidString])
    }

    private func resolveDescriptor(from data: Data) throws -> StreamDescriptor {
        let response = try JSONDecoder().decode(PlayerResponse.self, from: data)
        let streamingData = StreamingDataMapper.map(response.streamingData, now: now)
        let format = try XCTUnwrap(streamingData.adaptiveFormats.first)
        return try StreamDescriptorResolver.resolve(
            videoID: "sensitive-video-id",
            format: format,
            expiresAt: streamingData.expiresAt,
            requestHeaders: ["Origin": "https://music.youtube.com"]
        )
    }

    private func assertDescriptorError(
        _ expected: StreamDescriptorError,
        mutatingFormat: @escaping (inout [String: Any]) -> Void
    ) throws {
        XCTAssertThrowsError(
            try resolveDescriptor(from: playerAACRangesFixture(mutatingFormat: mutatingFormat))
        ) { error in
            XCTAssertEqual(error as? StreamDescriptorError, expected)
        }
    }

    private func assertPrivateSHA256(_ digest: String, excluding rawValues: [String]) {
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotNil(digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        for rawValue in rawValues {
            XCTAssertFalse(digest.contains(rawValue))
        }
    }

    /// Embedded named fixture: `player-aac-ranges`.
    private func playerAACRangesFixture(
        mutatingFormat: ((inout [String: Any]) -> Void)? = nil
    ) -> Data {
        var format: [String: Any] = [
            "itag": 140,
            "url": signedURL,
            "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
            "bitrate": 128_000,
            "contentLength": "4000000",
            "approxDurationMs": "245678",
            "initRange": ["start": "0", "end": "699"],
            "indexRange": ["start": "700", "end": "1199"],
        ]
        mutatingFormat?(&format)
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "expiresInSeconds": "3600",
                "adaptiveFormats": [format],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
