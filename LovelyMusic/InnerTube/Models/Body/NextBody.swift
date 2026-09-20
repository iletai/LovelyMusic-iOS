import Foundation

struct NextBody: Codable {
    let context: InnerTubeContext
    let videoId: String?
    let playlistId: String?
    let playlistSetVideoId: String?
    let index: Int?
    let params: String?
    let continuation: String?
}
