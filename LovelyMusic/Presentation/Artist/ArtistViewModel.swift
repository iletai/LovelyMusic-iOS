import Foundation

@MainActor @Observable
final class ArtistViewModel {
    private let getArtistUseCase: GetArtistUseCase

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadMoreTask: Task<Void, Never>?

    private(set) var artist: Artist?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var songsContinuation: String?

    var hasMoreSongs: Bool { songsContinuation != nil }

    init(getArtistUseCase: GetArtistUseCase) {
        self.getArtistUseCase = getArtistUseCase
    }

    deinit {
        loadTask?.cancel()
        loadMoreTask?.cancel()
    }

    func loadArtist(browseId: String) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoading = true
            error = nil
            do {
                let result = try await getArtistUseCase.execute(browseId: browseId)
                guard !Task.isCancelled else { return }
                self.artist = result.artist
                self.songsContinuation = result.songsContinuation
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    func loadMoreSongs() {
        guard let token = songsContinuation, !isLoadingMore else { return }
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoadingMore = true
            do {
                let result = try await getArtistUseCase.loadMoreSongs(continuation: token)
                guard !Task.isCancelled else { return }
                self.artist?.songs.append(contentsOf: result.songs)
                self.songsContinuation = result.continuation
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoadingMore = false
        }
    }
}
