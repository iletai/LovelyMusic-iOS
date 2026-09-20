import Foundation

struct BrowseBody: Codable {
    let context: InnerTubeContext
    let browseId: String?
    let params: String?
    let continuation: String?

    init(context: InnerTubeContext, browseId: String? = nil, params: String? = nil, continuation: String? = nil) {
        self.context = context
        self.browseId = browseId
        self.params = params
        self.continuation = continuation
    }
}
