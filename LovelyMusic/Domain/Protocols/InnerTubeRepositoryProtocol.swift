import Foundation

protocol InnerTubeRepositoryProtocol {
    func search(query: String, filter: SearchFilter?) async throws -> SearchResult
    func searchContinuation(token: String) async throws -> SearchResult
    func searchSuggestions(query: String) async throws -> [String]
    func getStreamingData(videoId: String) async throws -> StreamingData
    func browseHome(params: String?) async throws -> HomeResult
    func getArtist(browseId: String) async throws -> ArtistResult
    func getAlbum(browseId: String) async throws -> AlbumResult
    func browseContinuation(token: String) async throws -> Data
    func browseHomeContinuation(token: String) async throws -> HomeResult
    func browseShelfContinuation(token: String) async throws -> (songs: [Song], continuation: String?)
    func getPlaylist(playlistId: String) async throws -> PlaylistResult
    func getNext(videoId: String?, playlistId: String?) async throws -> [Song]
}
