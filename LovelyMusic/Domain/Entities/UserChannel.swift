import Foundation

struct UserChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let thumbnailURL: String?
    let browseId: String
}
