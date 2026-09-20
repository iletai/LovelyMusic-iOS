import Foundation

struct SearchResponse: Codable {
    let contents: Contents?
    let continuationContents: ContinuationContents?

    struct Contents: Codable {
        let tabbedSearchResultsRenderer: TabbedSearchResultsRenderer?
        let sectionListRenderer: SectionListRenderer?
    }

    struct TabbedSearchResultsRenderer: Codable {
        let tabs: [Tab]?
    }

    struct Tab: Codable {
        let tabRenderer: TabRenderer?
    }

    struct TabRenderer: Codable {
        let content: TabContent?
    }

    struct TabContent: Codable {
        let sectionListRenderer: SectionListRenderer?
    }

    struct SectionListRenderer: Codable {
        let contents: [SectionContent]?
    }

    struct SectionContent: Codable {
        let musicShelfRenderer: MusicShelfRenderer?
        let musicCardShelfRenderer: MusicCardShelfRenderer?
    }

    struct ContinuationContents: Codable {
        let musicShelfContinuation: MusicShelfContinuation?
    }

    struct MusicShelfContinuation: Codable {
        let contents: [MusicShelfContent]?
        let continuations: [Continuation]?
    }
}
