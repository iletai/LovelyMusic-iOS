import Foundation

struct GetSearchSuggestionsBody: Codable {
    let context: InnerTubeContext
    let input: String
}
