import Foundation

struct GetQueueBody: Codable {
    let context: InnerTubeContext
    let videoIds: [String]?
    let playlistId: String?
}
