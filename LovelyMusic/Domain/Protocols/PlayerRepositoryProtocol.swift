import Foundation

protocol PlayerRepositoryProtocol {
    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)?
}

extension PlayerRepositoryProtocol {
    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        throw StreamDescriptorError.descriptorResolutionUnsupported
    }
}
