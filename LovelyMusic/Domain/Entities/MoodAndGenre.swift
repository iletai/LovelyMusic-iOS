import Foundation

struct MoodAndGenre: Identifiable, Hashable {
    let id: String
    let title: String
    let color: Int64?
    let browseEndpoint: BrowseEndpointInfo

    struct BrowseEndpointInfo: Hashable {
        let browseId: String
        let params: String?
    }
}
