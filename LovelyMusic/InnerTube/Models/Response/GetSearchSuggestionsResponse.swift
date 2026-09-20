import Foundation

struct GetSearchSuggestionsResponse: Codable {
    let contents: [SuggestionContent]?

    struct SuggestionContent: Codable {
        let searchSuggestionsSectionRenderer: SearchSuggestionsSectionRenderer?
    }

    struct SearchSuggestionsSectionRenderer: Codable {
        let contents: [SuggestionItem]?
    }

    struct SuggestionItem: Codable {
        let searchSuggestionRenderer: SearchSuggestionRenderer?
    }

    struct SearchSuggestionRenderer: Codable {
        let suggestion: Runs?
        let navigationEndpoint: NavigationEndpoint?
    }
}
