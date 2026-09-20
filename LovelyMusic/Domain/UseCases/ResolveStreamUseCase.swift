import Foundation

final class ResolveStreamUseCase {
    private let repository: PlayerRepositoryProtocol

    init(repository: PlayerRepositoryProtocol) {
        self.repository = repository
    }

    @available(
        *,
        deprecated,
        message: "Pass an explicit effective AudioQuality so format selection is stable"
    )
    func execute(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        try await repository.resolveStreamURL(videoId: videoId)
    }

    func execute(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String] = [:]
    ) async throws -> (url: String, contentLength: Int64?) {
        do {
            let descriptor = try await executeDescriptor(
                videoId: videoId,
                quality: quality,
                requestHeaders: requestHeaders
            )
            return (descriptor.remoteURL.absoluteString, descriptor.contentLength)
        } catch StreamDescriptorError.localResourceIsNotRemoteRangeEligible {
            // Review-mode tracks are bundled local files and deliberately have no
            // remote range descriptor. Preserve that local-only playback path;
            // every other descriptor failure must remain visible to the caller.
            return try await repository.resolveStreamURL(videoId: videoId)
        }
    }

    func executeDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String] = [:]
    ) async throws -> StreamDescriptor {
        try await repository.resolveStreamDescriptor(
            videoId: videoId,
            quality: quality,
            requestHeaders: requestHeaders
        )
    }
}
