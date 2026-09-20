import Foundation

struct MusicResponsiveListItemRenderer: Codable {
    let flexColumns: [FlexColumn]?
    let fixedColumns: [FixedColumn]?
    let thumbnail: MusicThumbnailRenderer?
    let overlay: Overlay?
    let navigationEndpoint: NavigationEndpoint?
    let playlistItemData: PlaylistItemData?
    let badges: [Badge]?
    let musicItemRendererDisplayPolicy: String?

    /// YouTube Music marks geo-restricted, deleted, or premium-locked items with the
    /// `MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT` policy. Such items are unplayable
    /// and should be filtered out before reaching the UI.
    var isPlayable: Bool {
        musicItemRendererDisplayPolicy != "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
    }

    struct FlexColumn: Codable {
        let musicResponsiveListItemFlexColumnRenderer: FlexColumnRenderer?
    }

    struct FlexColumnRenderer: Codable {
        let text: Runs?
    }

    struct FixedColumn: Codable {
        let musicResponsiveListItemFixedColumnRenderer: FixedColumnRenderer?
    }

    struct FixedColumnRenderer: Codable {
        let text: Runs?
    }

    struct Overlay: Codable {
        let musicItemThumbnailOverlayRenderer: MusicItemThumbnailOverlayRenderer?
    }

    struct MusicItemThumbnailOverlayRenderer: Codable {
        let content: OverlayContent?
    }

    struct OverlayContent: Codable {
        let musicPlayButtonRenderer: MusicPlayButtonRenderer?
    }

    struct MusicPlayButtonRenderer: Codable {
        let playNavigationEndpoint: NavigationEndpoint?
    }

    struct PlaylistItemData: Codable {
        let videoId: String?
        let playlistSetVideoId: String?
    }
}

struct MusicMultiRowListItemRenderer: Codable {
    let title: Runs?
    let subtitle: Runs?
    let thumbnail: MusicThumbnailRenderer?
    let onTap: NavigationEndpoint?
}

struct MusicTwoRowItemRenderer: Codable {
    let title: Runs?
    let subtitle: Runs?
    let thumbnail: MusicThumbnailRenderer?
    let thumbnailRenderer: MusicThumbnailRenderer?
    let navigationEndpoint: NavigationEndpoint?
    let thumbnailOverlay: ThumbnailOverlay?
    let aspectRatio: String?
    let subtitleBadges: [Badge]?

    var resolvedThumbnailURL: String? {
        let thumbs = (thumbnailRenderer ?? thumbnail)?.resolvedThumbnails ?? []
        return thumbs.last?.url
    }

    struct ThumbnailOverlay: Codable {
        let musicItemThumbnailOverlayRenderer: ThumbnailOverlayRenderer?
    }

    struct ThumbnailOverlayRenderer: Codable {
        let content: OverlayRendererContent?
    }

    struct OverlayRendererContent: Codable {
        let musicPlayButtonRenderer: MusicPlayButtonRenderer?
    }

    struct MusicPlayButtonRenderer: Codable {
        let playNavigationEndpoint: NavigationEndpoint?
    }
}
