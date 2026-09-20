import Foundation

enum SuggestionsMapper {
    private static let decoder = JSONDecoder()

    static func map(_ data: Data) throws -> [String] {
        let response = try decoder.decode(GetSearchSuggestionsResponse.self, from: data)

        return response.contents?.flatMap { content in
            content.searchSuggestionsSectionRenderer?.contents?.compactMap { item in
                item.searchSuggestionRenderer?.suggestion?.text
            } ?? []
        } ?? []
    }
}
