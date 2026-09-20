import Foundation

enum StreamingDataMapper {
    static func map(
        _ response: PlayerResponse.StreamingDataResponse?,
        now: Date = Date()
    ) -> StreamingData {
        guard let response else {
            return StreamingData(formats: [], adaptiveFormats: [], expiresAt: nil)
        }

        let formats = (response.formats ?? []).compactMap { mapFormat($0) }
        let adaptiveFormats = (response.adaptiveFormats ?? []).compactMap { mapFormat($0) }

        let expiresInSeconds = response.expiresInSeconds.flatMap { Int($0) } ?? 21600
        let expiresAt = now.addingTimeInterval(Double(expiresInSeconds))

        return StreamingData(
            formats: formats,
            adaptiveFormats: adaptiveFormats,
            expiresAt: expiresAt
        )
    }

    private static func mapFormat(_ response: PlayerResponse.StreamFormatResponse) -> StreamFormat? {
        guard let itag = response.itag else { return nil }

        return StreamFormat(
            itag: itag,
            url: response.urlHasInvalidScalarType ? "" : response.url,
            mimeType: response.mimeTypeHasInvalidScalarType ? "" : response.mimeType ?? "",
            bitrate: response.bitrateHasInvalidScalarType ? 0 : response.bitrate,
            contentLength: response.contentLengthHasInvalidScalarType
                ? ""
                : response.contentLength,
            quality: response.quality,
            audioQuality: response.audioQuality,
            audioSampleRate: response.audioSampleRate,
            audioChannels: response.audioChannels,
            approxDurationMs: response.approxDurationMsHasInvalidScalarType
                ? ""
                : response.approxDurationMs,
            initializationRange: mapRange(
                response.initRange,
                hasInvalidContainerType: response.initRangeHasInvalidContainerType
            ),
            indexRange: mapRange(
                response.indexRange,
                hasInvalidContainerType: response.indexRangeHasInvalidContainerType
            ),
            width: response.width,
            height: response.height
        )
    }

    private static func mapRange(
        _ response: ByteRangeResponse?,
        hasInvalidContainerType: Bool
    ) -> StreamByteRange? {
        guard !hasInvalidContainerType else { return .invalid }
        guard let response else { return nil }
        guard !response.hasInvalidScalarType else { return .invalid }
        guard
            let startString = response.start,
            let endString = response.end,
            let start = Int64(startString),
            let inclusiveEnd = Int64(endString),
            start >= 0,
            inclusiveEnd >= start,
            inclusiveEnd < Int64.max
        else {
            return .invalid
        }
        return .valid(start..<(inclusiveEnd + 1))
    }
}
