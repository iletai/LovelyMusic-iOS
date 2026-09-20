import Foundation

protocol LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics?
}

struct SyncedLyrics {
    let lines: [LyricLine]
    let source: String
}

struct LyricLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}
