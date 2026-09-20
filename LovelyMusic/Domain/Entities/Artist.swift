import Foundation

struct Artist: Identifiable, Hashable {
    let id: String
    let name: String
    let thumbnailURL: String?
    let subscriberCount: String?
    var description: String?
    var songs: [Song]
    var albums: [Album]
    var singles: [Album]
}
