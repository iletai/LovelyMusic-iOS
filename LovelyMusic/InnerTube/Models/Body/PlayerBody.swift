import Foundation

struct PlayerBody: Codable {
    let context: InnerTubeContext
    let videoId: String
    let playlistId: String?
    let racyCheckOk: Bool?
    let contentCheckOk: Bool?
    let cpn: String?

    init(
        context: InnerTubeContext,
        videoId: String,
        playlistId: String? = nil,
        racyCheckOk: Bool? = nil,
        contentCheckOk: Bool? = nil,
        cpn: String? = nil
    ) {
        self.context = context
        self.videoId = videoId
        self.playlistId = playlistId
        self.racyCheckOk = racyCheckOk
        self.contentCheckOk = contentCheckOk
        self.cpn = cpn
    }
}
