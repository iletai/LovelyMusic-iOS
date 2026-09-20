import Foundation

enum NextResponseMapper {
    private static let decoder = JSONDecoder()

    static func map(_ data: Data) throws -> [Song] {
        let response = try decoder.decode(NextResponse.self, from: data)
        return mapSongs(response)
    }

    private static func mapSongs(_ response: NextResponse) -> [Song] {
        let tabs = response.contents?.singleColumnMusicWatchNextResultsRenderer?
            .tabbedRenderer?.watchNextTabbedResultsRenderer?.tabs ?? []

        guard let upNextTab = tabs.first else { return [] }

        let contents = upNextTab.tabRenderer?.content?.musicQueueRenderer?
            .content?.playlistPanelRenderer?.contents ?? []

        return contents.compactMap { content -> Song? in
            guard let renderer = content.playlistPanelVideoRenderer else { return nil }

            let title = renderer.title?.text ?? ""
            guard let videoId = renderer.videoId, !title.isEmpty else { return nil }

            let artistName = renderer.shortBylineText?.text
                ?? renderer.longBylineText?.text ?? ""
            let artistId = renderer.longBylineText?.runs?.first?
                .navigationEndpoint?.browseEndpoint?.browseId

            let thumbnailURL = renderer.thumbnail?.thumbnails?.last?.url

            let durationText = renderer.lengthText?.text
            let duration = SearchResponseMapper.parseDuration(durationText)

            let musicVideoType = renderer.navigationEndpoint?.watchEndpoint?
                .watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType

            return Song(
                id: videoId,
                title: title,
                artistName: artistName,
                artistId: artistId,
                albumName: nil,
                albumId: nil,
                duration: duration,
                thumbnailURL: thumbnailURL,
                musicVideoType: musicVideoType
            )
        }
    }
}
