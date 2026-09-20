import Foundation
@testable import LovelyMusic

final class MockInnerTubeRepository: InnerTubeRepositoryProtocol {
    var searchResult: SearchResult = .empty
    var continuationResult: SearchResult = .empty
    var suggestions: [String] = []
    var homeResult: HomeResult = HomeResult(sections: [], continuation: nil)
    var shouldThrow = false
    var searchCallCount = 0
    var searchContinuationCallCount = 0
    var lastSearchFilter: SearchFilter?

    // Configurable artist result for pagination tests
    var artistResult: ArtistResult?
    // Configurable album result for pagination tests
    var albumResult: AlbumResult?
    // Track how many times browseContinuation is called
    var browseContinuationCallCount = 0
    // Track continuation calls through new methods
    var browseShelfContinuationCallCount = 0
    var shelfContinuationResult: (songs: [Song], continuation: String?) = (songs: [], continuation: nil)
    var browseContinuationHandler: ((String) async throws -> Data)?

    func search(query: String, filter: SearchFilter?) async throws -> SearchResult {
        searchCallCount += 1
        lastSearchFilter = filter
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return searchResult
    }

    func searchContinuation(token: String) async throws -> SearchResult {
        searchContinuationCallCount += 1
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return continuationResult
    }

    func searchSuggestions(query: String) async throws -> [String] {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return suggestions
    }

    func getStreamingData(videoId: String) async throws -> StreamingData {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return StreamingData(formats: [], adaptiveFormats: [], expiresAt: nil)
    }

    func browseHome(params: String? = nil) async throws -> HomeResult {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return homeResult
    }

    func getArtist(browseId: String) async throws -> ArtistResult {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if let result = artistResult {
            return result
        }
        let artist = Artist(id: browseId, name: "Test Artist", thumbnailURL: nil, subscriberCount: nil, songs: [], albums: [], singles: [])
        return ArtistResult(artist: artist, songsContinuation: nil)
    }

    func getAlbum(browseId: String) async throws -> AlbumResult {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if let result = albumResult {
            return result
        }
        let album = Album(id: browseId, title: "Test Album", artistName: "Artist", artistId: nil, year: nil, thumbnailURL: nil, songs: [])
        return AlbumResult(album: album, songsContinuation: nil)
    }

    func getPlaylist(playlistId: String) async throws -> PlaylistResult {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return PlaylistResult(playlist: Playlist(id: playlistId, title: "Test Playlist"), songsContinuation: nil)
    }

    func getNext(videoId: String?, playlistId: String?) async throws -> [Song] {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return []
    }

    func browseContinuation(token: String) async throws -> Data {
        browseContinuationCallCount += 1
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        if let handler = browseContinuationHandler {
            return try await handler(token)
        }
        return Data()
    }

    func browseHomeContinuation(token: String) async throws -> HomeResult {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return homeResult
    }

    func browseShelfContinuation(token: String) async throws -> (songs: [Song], continuation: String?) {
        browseShelfContinuationCallCount += 1
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return shelfContinuationResult
    }
}
