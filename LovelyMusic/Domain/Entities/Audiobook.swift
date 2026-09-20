import Foundation

struct Audiobook: Identifiable, Hashable {
    let id: String
    let title: String
    let authorName: String?
    let thumbnailURL: String?
    let browseId: String
}
