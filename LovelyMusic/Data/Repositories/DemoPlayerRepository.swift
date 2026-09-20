import Foundation

/// Player repository for demo mode.
/// Resolves stream URLs from bundled .m4a files or a remote fallback pattern.
final class DemoPlayerRepository: PlayerRepositoryProtocol {

    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        throw StreamDescriptorError.localResourceIsNotRemoteRangeEligible
    }

    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        // Try bundled .m4a file first
        if let bundledURL = Bundle.main.url(forResource: videoId, withExtension: "m4a") {
            return (url: bundledURL.absoluteString, contentLength: nil)
        }

        // No bundled file available — throw so the player can show an appropriate message
        throw DemoError.streamingNotAvailable
    }

    func resolveVideoStreamURL(videoId: String) async throws -> (
        url: String, contentLength: Int64?
    )? {
        // No video playback in demo mode
        nil
    }
}
