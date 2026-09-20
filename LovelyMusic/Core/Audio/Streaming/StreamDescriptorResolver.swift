import Foundation

enum StreamDescriptorResolver {
    static func capabilityKey(
        for descriptor: StreamDescriptor,
        environment: PlaybackCapabilityEnvironment,
        containerLayoutProfile: String,
        qualityTier: AudioQuality,
        controls: PlaybackFeatureSnapshot
    ) -> CapabilityKey {
        CapabilityKey(
            appBuild: environment.appBuild,
            iOSBuild: environment.iOSBuild,
            deviceFamily: environment.deviceFamily,
            itag: descriptor.itag,
            mimeType: descriptor.mimeType,
            codec: descriptor.codec,
            containerLayoutProfile: containerLayoutProfile,
            qualityTier: qualityTier,
            headerSchemaVersion: controls.headerSchemaVersion,
            loaderVersion: controls.loaderVersion
        )
    }

    static func resolve(
        videoID: String,
        format: StreamFormat,
        expiresAt: Date?,
        requestHeaders: [String: String]
    ) throws -> StreamDescriptor {
        guard let urlString = format.url else {
            throw StreamDescriptorError.missingURL
        }
        guard
            let remoteURL = URL(string: urlString),
            let scheme = remoteURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = remoteURL.host,
            !host.isEmpty,
            remoteURL.absoluteString == urlString
        else {
            throw StreamDescriptorError.invalidURL
        }

        let parsedMIME = try parseMIME(format.mimeType)
        guard let bitrate = format.bitrate, bitrate > 0 else {
            throw StreamDescriptorError.invalidBitrate
        }
        let contentLength = try parsePositiveInt64(
            format.contentLength,
            error: .invalidContentLength
        )
        let durationMilliseconds = try parseNonnegativeInt64(
            format.approxDurationMs,
            error: .invalidDuration
        )
        let initializationRange = try range(
            format.initializationRange,
            error: .invalidInitializationRange
        )
        let indexRange = try range(
            format.indexRange,
            error: .invalidIndexRange
        )

        return StreamDescriptor(
            videoID: videoID,
            remoteURL: remoteURL,
            itag: format.itag,
            mimeType: parsedMIME.base,
            codec: parsedMIME.codec,
            bitrate: bitrate,
            contentLength: contentLength,
            duration: durationMilliseconds.map { Duration.milliseconds($0) },
            initializationRange: initializationRange,
            indexRange: indexRange,
            expiresAt: expiresAt,
            requestHeaders: requestHeaders,
            provisionalResourceKey: ProvisionalResourceKey(
                videoID: videoID,
                itag: format.itag,
                codec: parsedMIME.codec,
                declaredTotalLength: contentLength
            )
        )
    }

    private static func parseMIME(_ rawValue: String) throws -> (base: String, codec: String) {
        let rawBase = StreamMIMEBaseSyntax.trimmedBase(rawValue)
        guard !rawBase.isEmpty, StreamMIMEBaseSyntax.isValid(rawBase) else {
            throw StreamDescriptorError.missingMIMEType
        }
        let base = rawBase.lowercased()
        let segments = try splitMIMEParameters(rawValue)

        for parameter in segments.dropFirst() {
            let pieces = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "codecs" else { continue }
            let codec = try decodeCodecValue(
                String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return (base, codec)
        }
        throw StreamDescriptorError.missingCodec
    }

    private static func splitMIMEParameters(_ value: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false
        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" && isQuoted {
                current.append(character)
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
                current.append(character)
            } else if character == ";" && !isQuoted {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !isQuoted, !isEscaped else {
            throw StreamDescriptorError.missingCodec
        }
        result.append(current)
        return result
    }

    private static func decodeCodecValue(_ value: String) throws -> String {
        guard !value.isEmpty else { throw StreamDescriptorError.missingCodec }

        guard value.first == "\"" else {
            guard !value.contains("\""), !value.contains("\\") else {
                throw StreamDescriptorError.missingCodec
            }
            return value
        }

        var codec = ""
        var isEscaped = false
        var foundClosingQuote = false
        var index = value.index(after: value.startIndex)

        while index < value.endIndex {
            let character = value[index]
            if isEscaped {
                codec.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                foundClosingQuote = true
                index = value.index(after: index)
                let remainder = value[index...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard remainder.isEmpty else {
                    throw StreamDescriptorError.missingCodec
                }
                break
            } else {
                codec.append(character)
            }
            index = value.index(after: index)
        }

        codec = codec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard foundClosingQuote, !isEscaped, !codec.isEmpty else {
            throw StreamDescriptorError.missingCodec
        }
        return codec
    }

    private static func parsePositiveInt64(
        _ value: String?,
        error: StreamDescriptorError
    ) throws -> Int64? {
        guard let value else { return nil }
        guard let parsed = Int64(value), parsed > 0 else { throw error }
        return parsed
    }

    private static func parseNonnegativeInt64(
        _ value: String?,
        error: StreamDescriptorError
    ) throws -> Int64? {
        guard let value else { return nil }
        guard let parsed = Int64(value), parsed >= 0 else { throw error }
        return parsed
    }

    private static func range(
        _ value: StreamByteRange?,
        error: StreamDescriptorError
    ) throws -> Range<Int64>? {
        guard let value else { return nil }
        switch value {
        case .valid(let range): return range
        case .invalid: throw error
        }
    }
}
