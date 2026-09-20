import Foundation

final class GetLyricsUseCase {
    private let repository: LyricsRepositoryProtocol

    init(repository: LyricsRepositoryProtocol) {
        self.repository = repository
    }

    func execute(title: String, artist: String, duration: Int? = nil) async throws -> SyncedLyrics? {
        try await repository.getLyrics(title: title, artist: artist, duration: duration)
    }
}
