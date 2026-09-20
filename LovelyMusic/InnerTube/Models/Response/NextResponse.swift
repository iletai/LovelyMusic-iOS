import Foundation

struct NextResponse: Codable {
    let contents: Contents?

    struct Contents: Codable {
        let singleColumnMusicWatchNextResultsRenderer: SingleColumnMusicWatchNextResultsRenderer?
    }

    struct SingleColumnMusicWatchNextResultsRenderer: Codable {
        let tabbedRenderer: TabbedRenderer?
    }

    struct TabbedRenderer: Codable {
        let watchNextTabbedResultsRenderer: WatchNextTabbedResultsRenderer?
    }

    struct WatchNextTabbedResultsRenderer: Codable {
        let tabs: [Tab]?
    }

    struct Tab: Codable {
        let tabRenderer: TabRenderer?
    }

    struct TabRenderer: Codable {
        let content: TabContent?
        let endpoint: NavigationEndpoint?
    }

    struct TabContent: Codable {
        let musicQueueRenderer: MusicQueueRenderer?
    }

    struct MusicQueueRenderer: Codable {
        let content: QueueContent?
    }

    struct QueueContent: Codable {
        let playlistPanelRenderer: PlaylistPanelRenderer?
    }
}
