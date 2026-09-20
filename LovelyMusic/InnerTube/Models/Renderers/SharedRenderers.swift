import Foundation

// MARK: - Text / Runs

struct Runs: Codable {
    let runs: [Run]?

    var text: String {
        runs?.map(\.text).joined() ?? ""
    }
}

struct Run: Codable {
    let text: String
    let navigationEndpoint: NavigationEndpoint?
}

// MARK: - Thumbnails

struct ThumbnailContainer: Codable {
    let thumbnails: [Thumbnail]?
}

struct Thumbnail: Codable {
    let url: String
    let width: Int?
    let height: Int?
}

struct MusicThumbnailRenderer: Codable {
    let thumbnail: ThumbnailContainer?
    let musicThumbnailRenderer: MusicThumbnailRendererInner?

    struct MusicThumbnailRendererInner: Codable {
        let thumbnail: ThumbnailContainer?
    }

    var resolvedThumbnails: [Thumbnail] {
        thumbnail?.thumbnails ?? musicThumbnailRenderer?.thumbnail?.thumbnails ?? []
    }
}

// MARK: - Navigation

struct NavigationEndpoint: Codable {
    let watchEndpoint: WatchEndpoint?
    let browseEndpoint: BrowseEndpoint?
    let searchEndpoint: SearchEndpoint?
    let watchPlaylistEndpoint: WatchPlaylistEndpoint?
}

struct WatchEndpoint: Codable {
    let videoId: String?
    let playlistId: String?
    let playlistSetVideoId: String?
    let index: Int?
    let params: String?
    let watchEndpointMusicSupportedConfigs: WatchEndpointMusicSupportedConfigs?
}

struct WatchEndpointMusicSupportedConfigs: Codable {
    let watchEndpointMusicConfig: WatchEndpointMusicConfig?
}

struct WatchEndpointMusicConfig: Codable {
    let musicVideoType: String?
}

struct BrowseEndpoint: Codable {
    let browseId: String?
    let params: String?
    let browseEndpointContextSupportedConfigs: BrowseEndpointContextSupportedConfigs?
}

struct BrowseEndpointContextSupportedConfigs: Codable {
    let browseEndpointContextMusicConfig: BrowseEndpointContextMusicConfig?
}

struct BrowseEndpointContextMusicConfig: Codable {
    let pageType: String?
}

struct SearchEndpoint: Codable {
    let query: String?
    let params: String?
}

struct WatchPlaylistEndpoint: Codable {
    let playlistId: String?
    let params: String?
}

// MARK: - Continuation

struct Continuation: Codable {
    let nextContinuationData: NextContinuationData?
    let nextRadioContinuationData: NextContinuationData?
    /// Modern envelope (YouTube migration target). When present, takes
    /// precedence over the legacy `nextContinuationData` shape.
    /// See ExecPlan §Phase 1 task 1.2 and round-1 audit §gap-5.
    let continuationCommand: ContinuationCommand?

    var token: String? {
        // Modern-wins precedence: legacy is fallback only.
        continuationCommand?.token
            ?? nextContinuationData?.continuation
            ?? nextRadioContinuationData?.continuation
    }
}

struct NextContinuationData: Codable {
    let continuation: String?
}

struct ContinuationCommand: Codable {
    let token: String?
}

extension Array where Element == Continuation {
    var token: String? {
        first?.token
    }
}

// MARK: - Shelf Renderers

struct MusicShelfRenderer: Codable {
    let title: Runs?
    let contents: [MusicShelfContent]?
    let continuations: [Continuation]?
    let bottomEndpoint: NavigationEndpoint?
}

struct MusicShelfContent: Codable {
    let musicResponsiveListItemRenderer: MusicResponsiveListItemRenderer?
    let musicMultiRowListItemRenderer: MusicMultiRowListItemRenderer?
}

struct MusicCardShelfRenderer: Codable {
    let header: MusicCardShelfHeader?
    let title: Runs?
    let subtitle: Runs?
    let thumbnail: MusicThumbnailRenderer?
    let onTap: NavigationEndpoint?
    let contents: [MusicShelfContent]?
}

struct MusicCardShelfHeader: Codable {
    let musicCardShelfHeaderBasicRenderer: MusicCardShelfHeaderBasicRenderer?
}

struct MusicCardShelfHeaderBasicRenderer: Codable {
    let title: Runs?
}

struct MusicCarouselShelfRenderer: Codable {
    let header: MusicCarouselShelfHeader?
    let contents: [CarouselContent]?
    let continuations: [Continuation]?
}

struct MusicCarouselShelfHeader: Codable {
    let musicCarouselShelfBasicHeaderRenderer: MusicCarouselShelfBasicHeaderRenderer?
}

struct MusicCarouselShelfBasicHeaderRenderer: Codable {
    let title: Runs?
    let strapline: Runs?
    let moreContentButton: MoreContentButton?
}

struct MoreContentButton: Codable {
    let buttonRenderer: ButtonRenderer?
}

struct ButtonRenderer: Codable {
    let navigationEndpoint: NavigationEndpoint?
    let text: Runs?
}

struct CarouselContent: Codable {
    let musicTwoRowItemRenderer: MusicTwoRowItemRenderer?
    let musicResponsiveListItemRenderer: MusicResponsiveListItemRenderer?
    let musicNavigationButtonRenderer: MusicNavigationButtonRenderer?
}

// MARK: - Playlist Panel

struct PlaylistPanelRenderer: Codable {
    let contents: [PlaylistPanelContent]?
    let continuations: [Continuation]?
    let playlistId: String?
}

struct PlaylistPanelContent: Codable {
    let playlistPanelVideoRenderer: PlaylistPanelVideoRenderer?
    let automixPreviewVideoRenderer: AutomixPreviewVideoRenderer?
}

struct PlaylistPanelVideoRenderer: Codable {
    let title: Runs?
    let longBylineText: Runs?
    let shortBylineText: Runs?
    let thumbnail: ThumbnailContainer?
    let videoId: String?
    let lengthText: Runs?
    let navigationEndpoint: NavigationEndpoint?
    let selected: Bool?
}

struct AutomixPreviewVideoRenderer: Codable {
    let content: AutomixContent?
}

struct AutomixContent: Codable {
    let automixPlaylistVideoRenderer: AutomixPlaylistVideoRenderer?
}

struct AutomixPlaylistVideoRenderer: Codable {
    let navigationEndpoint: NavigationEndpoint?
}

// MARK: - Badges

struct Badge: Codable {
    let musicInlineBadgeRenderer: MusicInlineBadgeRenderer?
}

struct MusicInlineBadgeRenderer: Codable {
    let icon: IconRenderer?
    let accessibilityData: AccessibilityData?
}

struct IconRenderer: Codable {
    let iconType: String?
}

struct AccessibilityData: Codable {
    let accessibilityData: AccessibilityLabel?
}

struct AccessibilityLabel: Codable {
    let label: String?
}

// MARK: - Navigation Button (Mood/Genre chips)

struct MusicNavigationButtonRenderer: Codable {
    let buttonText: Runs?
    let solid: SolidColor?
    let clickCommand: NavigationEndpoint?
}

struct SolidColor: Codable {
    let leftStripeColor: Int64?
}
