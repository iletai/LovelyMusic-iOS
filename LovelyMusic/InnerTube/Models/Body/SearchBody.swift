import Foundation

struct SearchBody: Codable {
    let context: InnerTubeContext
    let query: String?
    let params: String?
    let continuation: String?

    init(context: InnerTubeContext, query: String? = nil, params: String? = nil, continuation: String? = nil) {
        self.context = context
        self.query = query
        self.params = params
        self.continuation = continuation
    }
}
