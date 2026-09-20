import Foundation

struct ByteRangeResponse: Codable {
    let start: String?
    let end: String?

    private(set) var startHasInvalidScalarType = false
    private(set) var endHasInvalidScalarType = false

    var hasInvalidScalarType: Bool {
        startHasInvalidScalarType || endHasInvalidScalarType
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }
}

struct PlayerResponse: Codable {
    let playabilityStatus: PlayabilityStatus?
    let streamingData: StreamingDataResponse?
    let videoDetails: VideoDetails?

    struct PlayabilityStatus: Codable {
        let status: String?
        let reason: String?
    }

    struct StreamingDataResponse: Codable {
        let formats: [StreamFormatResponse]?
        let adaptiveFormats: [StreamFormatResponse]?
        let expiresInSeconds: String?
        let hlsManifestUrl: String?
    }

    struct StreamFormatResponse: Codable {
        let itag: Int?
        let url: String?
        let mimeType: String?
        let bitrate: Int?
        let contentLength: String?
        let quality: String?
        let audioQuality: String?
        let audioSampleRate: String?
        let audioChannels: Int?
        let approxDurationMs: String?
        let initRange: ByteRangeResponse?
        let indexRange: ByteRangeResponse?
        let signatureCipher: String?
        let width: Int?
        let height: Int?

        private(set) var urlHasInvalidScalarType = false
        private(set) var mimeTypeHasInvalidScalarType = false
        private(set) var bitrateHasInvalidScalarType = false
        private(set) var contentLengthHasInvalidScalarType = false
        private(set) var approxDurationMsHasInvalidScalarType = false
        private(set) var initRangeHasInvalidContainerType = false
        private(set) var indexRangeHasInvalidContainerType = false

        private enum CodingKeys: String, CodingKey {
            case itag
            case url
            case mimeType
            case bitrate
            case contentLength
            case quality
            case audioQuality
            case audioSampleRate
            case audioChannels
            case approxDurationMs
            case initRange
            case indexRange
            case signatureCipher
            case width
            case height
        }
    }

    struct VideoDetails: Codable {
        let videoId: String?
        let title: String?
        let lengthSeconds: String?
        let channelId: String?
        let shortDescription: String?
        let thumbnail: ThumbnailContainer?
        let viewCount: String?
        let author: String?
        let musicVideoType: String?
    }
}

private struct DecodedDescriptorScalar<Value> {
    let value: Value?
    let hasInvalidScalarType: Bool
}

private extension KeyedDecodingContainer {
    func decodeDescriptorScalar<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> DecodedDescriptorScalar<Value> {
        guard contains(key) else {
            return DecodedDescriptorScalar(value: nil, hasInvalidScalarType: false)
        }
        if try decodeNil(forKey: key) {
            return DecodedDescriptorScalar(value: nil, hasInvalidScalarType: false)
        }

        do {
            return DecodedDescriptorScalar(
                value: try decode(type, forKey: key),
                hasInvalidScalarType: false
            )
        } catch let error as DecodingError {
            switch error {
            case .typeMismatch, .dataCorrupted:
                return DecodedDescriptorScalar(value: nil, hasInvalidScalarType: true)
            case .keyNotFound, .valueNotFound:
                throw error
            @unknown default:
                throw error
            }
        }
    }
}

extension ByteRangeResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedStart = try container.decodeDescriptorScalar(String.self, forKey: .start)
        let decodedEnd = try container.decodeDescriptorScalar(String.self, forKey: .end)

        start = decodedStart.value
        end = decodedEnd.value
        startHasInvalidScalarType = decodedStart.hasInvalidScalarType
        endHasInvalidScalarType = decodedEnd.hasInvalidScalarType
    }

    func encode(to encoder: Encoder) throws {
        guard !hasInvalidScalarType else {
            throw EncodingError.invalidValue(
                "invalid byte-range scalar state",
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Cannot encode an invalid byte-range scalar state"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
    }
}

extension PlayerResponse.StreamFormatResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        itag = try container.decodeIfPresent(Int.self, forKey: .itag)

        let decodedURL = try container.decodeDescriptorScalar(String.self, forKey: .url)
        url = decodedURL.value
        urlHasInvalidScalarType = decodedURL.hasInvalidScalarType

        let decodedMIMEType = try container.decodeDescriptorScalar(String.self, forKey: .mimeType)
        mimeType = decodedMIMEType.value
        mimeTypeHasInvalidScalarType = decodedMIMEType.hasInvalidScalarType

        let decodedBitrate = try container.decodeDescriptorScalar(Int.self, forKey: .bitrate)
        bitrate = decodedBitrate.value
        bitrateHasInvalidScalarType = decodedBitrate.hasInvalidScalarType

        let decodedContentLength = try container.decodeDescriptorScalar(
            String.self,
            forKey: .contentLength
        )
        contentLength = decodedContentLength.value
        contentLengthHasInvalidScalarType = decodedContentLength.hasInvalidScalarType

        quality = try container.decodeIfPresent(String.self, forKey: .quality)
        audioQuality = try container.decodeIfPresent(String.self, forKey: .audioQuality)
        audioSampleRate = try container.decodeIfPresent(String.self, forKey: .audioSampleRate)
        audioChannels = try container.decodeIfPresent(Int.self, forKey: .audioChannels)

        let decodedDuration = try container.decodeDescriptorScalar(
            String.self,
            forKey: .approxDurationMs
        )
        approxDurationMs = decodedDuration.value
        approxDurationMsHasInvalidScalarType = decodedDuration.hasInvalidScalarType

        let decodedInitializationRange = try container.decodeDescriptorScalar(
            ByteRangeResponse.self,
            forKey: .initRange
        )
        initRange = decodedInitializationRange.value
        initRangeHasInvalidContainerType =
            decodedInitializationRange.hasInvalidScalarType

        let decodedIndexRange = try container.decodeDescriptorScalar(
            ByteRangeResponse.self,
            forKey: .indexRange
        )
        indexRange = decodedIndexRange.value
        indexRangeHasInvalidContainerType = decodedIndexRange.hasInvalidScalarType
        signatureCipher = try container.decodeIfPresent(String.self, forKey: .signatureCipher)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
    }

    func encode(to encoder: Encoder) throws {
        guard
            !urlHasInvalidScalarType,
            !mimeTypeHasInvalidScalarType,
            !bitrateHasInvalidScalarType,
            !contentLengthHasInvalidScalarType,
            !approxDurationMsHasInvalidScalarType,
            !initRangeHasInvalidContainerType,
            !indexRangeHasInvalidContainerType
        else {
            throw EncodingError.invalidValue(
                "invalid stream-format scalar state",
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Cannot encode an invalid stream-format scalar state"
                )
            )
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(itag, forKey: .itag)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encodeIfPresent(contentLength, forKey: .contentLength)
        try container.encodeIfPresent(quality, forKey: .quality)
        try container.encodeIfPresent(audioQuality, forKey: .audioQuality)
        try container.encodeIfPresent(audioSampleRate, forKey: .audioSampleRate)
        try container.encodeIfPresent(audioChannels, forKey: .audioChannels)
        try container.encodeIfPresent(approxDurationMs, forKey: .approxDurationMs)
        try container.encodeIfPresent(initRange, forKey: .initRange)
        try container.encodeIfPresent(indexRange, forKey: .indexRange)
        try container.encodeIfPresent(signatureCipher, forKey: .signatureCipher)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
    }
}
