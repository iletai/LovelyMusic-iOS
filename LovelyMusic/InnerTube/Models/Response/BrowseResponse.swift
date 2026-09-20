import Foundation

struct BrowseResponse: Codable {
    let header: Header?
    let contents: Contents?
    let background: MusicThumbnailRenderer?
    let continuationContents: ContinuationContents?

    struct Header: Codable {
        let musicImmersiveHeaderRenderer: MusicImmersiveHeaderRenderer?
        let musicDetailHeaderRenderer: MusicDetailHeaderRenderer?
        let musicVisualHeaderRenderer: MusicVisualHeaderRenderer?
        let musicEditablePlaylistDetailHeaderRenderer: MusicEditablePlaylistDetailHeaderRenderer?
    }

    struct MusicEditablePlaylistDetailHeaderRenderer: Codable {
        let header: EditablePlaylistHeader?
    }

    struct EditablePlaylistHeader: Codable {
        let musicDetailHeaderRenderer: MusicDetailHeaderRenderer?
        let musicResponsiveHeaderRenderer: MusicResponsiveHeaderRenderer?
    }

    struct MusicResponsiveHeaderRenderer: Codable {
        let title: Runs?
        let subtitle: Runs?
        let straplineTextOne: Runs?
        let thumbnail: MusicThumbnailRenderer?
        let secondSubtitle: Runs?
        let description: Runs?
        let menu: Menu?
    }

    struct MusicImmersiveHeaderRenderer: Codable {
        let title: Runs?
        let description: Runs?
        let thumbnail: MusicThumbnailRenderer?
        let subscriptionButton: SubscriptionButton?
    }

    struct MusicDetailHeaderRenderer: Codable {
        let title: Runs?
        let subtitle: Runs?
        let menu: Menu?
        let thumbnail: MusicThumbnailRenderer?
        let description: Runs?
    }

    struct MusicVisualHeaderRenderer: Codable {
        let title: Runs?
        let thumbnail: MusicThumbnailRenderer?
        let foregroundThumbnail: MusicThumbnailRenderer?
        let description: Runs?
    }

    struct SubscriptionButton: Codable {
        let subscribeButtonRenderer: SubscribeButtonRenderer?
    }

    struct SubscribeButtonRenderer: Codable {
        let subscriberCountText: Runs?
    }

    struct Contents: Codable {
        let singleColumnBrowseResultsRenderer: SingleColumnBrowseResultsRenderer?
        let twoColumnBrowseResultsRenderer: TwoColumnBrowseResultsRenderer?
        let sectionListRenderer: SectionListRenderer?
    }

    struct TwoColumnBrowseResultsRenderer: Codable {
        let tabs: [Tab]?
        let secondaryContents: SecondaryContents?
    }

    struct SecondaryContents: Codable {
        let sectionListRenderer: SectionListRenderer?
    }

    struct SingleColumnBrowseResultsRenderer: Codable {
        let tabs: [Tab]?
    }

    struct Tab: Codable {
        let tabRenderer: TabRenderer?
    }

    struct TabRenderer: Codable {
        let content: TabContent?
    }

    struct TabContent: Codable {
        let sectionListRenderer: SectionListRenderer?
    }

    struct SectionListRenderer: Codable {
        let contents: [SectionContent]?
        let continuations: [Continuation]?
        let header: SectionListHeader?
    }

    struct SectionListHeader: Codable {
        let chipCloudRenderer: ChipCloudRenderer?
    }

    struct ChipCloudRenderer: Codable {
        let chips: [ChipCloudChip]?
    }

    struct ChipCloudChip: Codable {
        let chipCloudChipRenderer: ChipCloudChipRenderer?
    }

    struct ChipCloudChipRenderer: Codable {
        let text: Runs?
        let navigationEndpoint: NavigationEndpoint?
        let isSelected: Bool?
    }

    struct SectionContent: Codable {
        let musicCarouselShelfRenderer: MusicCarouselShelfRenderer?
        // Alias key: same body schema as `musicCarouselShelfRenderer`. Mirrors
        // InnerTune's `@JsonNames` fallthrough so home shelves keyed under
        // `musicImmersiveCarouselShelfRenderer` are not silently dropped.
        let musicImmersiveCarouselShelfRenderer: MusicCarouselShelfRenderer?
        let musicShelfRenderer: MusicShelfRenderer?
        let musicPlaylistShelfRenderer: MusicPlaylistShelfRenderer?
        let musicCardShelfRenderer: MusicCardShelfRenderer?
        let musicDescriptionShelfRenderer: MusicDescriptionShelfRenderer?
        let musicResponsiveHeaderRenderer: MusicResponsiveHeaderRenderer?
        let gridRenderer: GridRenderer?

        private enum CodingKeys: String, CodingKey {
            case musicCarouselShelfRenderer
            case musicImmersiveCarouselShelfRenderer
            case musicShelfRenderer
            case musicPlaylistShelfRenderer
            case musicCardShelfRenderer
            case musicDescriptionShelfRenderer
            case musicResponsiveHeaderRenderer
            case gridRenderer
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Strict decode for established keys — schema breaks here are real
            // bugs, not experimental drift, so we surface them.
            musicCarouselShelfRenderer = try c.decodeIfPresent(
                MusicCarouselShelfRenderer.self, forKey: .musicCarouselShelfRenderer)
            musicShelfRenderer = try c.decodeIfPresent(
                MusicShelfRenderer.self, forKey: .musicShelfRenderer)
            musicPlaylistShelfRenderer = try c.decodeIfPresent(
                MusicPlaylistShelfRenderer.self, forKey: .musicPlaylistShelfRenderer)
            musicDescriptionShelfRenderer = try c.decodeIfPresent(
                MusicDescriptionShelfRenderer.self, forKey: .musicDescriptionShelfRenderer)
            musicResponsiveHeaderRenderer = try c.decodeIfPresent(
                MusicResponsiveHeaderRenderer.self, forKey: .musicResponsiveHeaderRenderer)
            gridRenderer = try c.decodeIfPresent(GridRenderer.self, forKey: .gridRenderer)
            // Tolerant decode for experimental aliases — a malformed body
            // under these keys yields nil for that field instead of nuking
            // the entire BrowseResponse decode. The mapper already filters
            // out sections where every renderer is nil, so a nil here =
            // section silently skipped.
            musicCardShelfRenderer = try? c.decodeIfPresent(
                MusicCardShelfRenderer.self, forKey: .musicCardShelfRenderer)
            musicImmersiveCarouselShelfRenderer = try? c.decodeIfPresent(
                MusicCarouselShelfRenderer.self, forKey: .musicImmersiveCarouselShelfRenderer)
        }
    }

    struct MusicPlaylistShelfRenderer: Codable {
        let playlistId: String?
        let contents: [MusicShelfContent]?
        let continuations: [Continuation]?
    }

    struct MusicDescriptionShelfRenderer: Codable {
        let description: Runs?
    }

    struct GridRenderer: Codable {
        let items: [GridItem]?
    }

    struct GridItem: Codable {
        let musicTwoRowItemRenderer: MusicTwoRowItemRenderer?
    }

    struct ContinuationContents: Codable {
        let musicShelfContinuation: MusicShelfContinuation?
        let musicPlaylistShelfContinuation: MusicPlaylistShelfContinuation?
        let sectionListContinuation: SectionListContinuation?
        let gridContinuation: GridContinuation?
    }

    struct MusicShelfContinuation: Codable {
        let contents: [MusicShelfContent]?
        let continuations: [Continuation]?
    }

    struct MusicPlaylistShelfContinuation: Codable {
        let contents: [MusicShelfContent]?
        let continuations: [Continuation]?
    }

    struct SectionListContinuation: Codable {
        let contents: [SectionContent]?
        let continuations: [Continuation]?
    }

    struct GridContinuation: Codable {
        let items: [CarouselContent]?
        let continuations: [Continuation]?
    }

    struct Menu: Codable {
        let menuRenderer: MenuRenderer?
    }

    struct MenuRenderer: Codable {
        let items: [MenuItem]?
    }

    struct MenuItem: Codable {
        let menuNavigationItemRenderer: MenuNavigationItemRenderer?
    }

    struct MenuNavigationItemRenderer: Codable {
        let navigationEndpoint: NavigationEndpoint?
    }
}
