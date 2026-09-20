import Foundation

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artistName: String
    let artistId: String?
    let year: String?
    let thumbnailURL: String?
    var description: String?
    var songs: [Song]

    var totalDuration: String {
        let total = songs.compactMap(\.duration).reduce(0, +)
        let minutes = total / 60
        return "\(minutes) min"
    }
}
