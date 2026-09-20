import Foundation

@MainActor @Observable
final class AlbumViewModel {
    private let getAlbumUseCase: GetAlbumUseCase

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadMoreTask: Task<Void, Never>?

    private(set) var album: Album?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var songsContinuation: String?

    var hasMoreSongs: Bool { songsContinuation != nil }

    init(getAlbumUseCase: GetAlbumUseCase) {
        self.getAlbumUseCase = getAlbumUseCase
    }

    deinit {
        loadTask?.cancel()
        loadMoreTask?.cancel()
    }

    func loadAlbum(browseId: String) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoading = true
            error = nil
            do {
                let result = try await getAlbumUseCase.execute(browseId: browseId)
                guard !Task.isCancelled else { return }
                self.album = result.album
                self.songsContinuation = result.continuation
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
                let result = try await getAlbumUseCase.loadMoreSongs(continuation: token)
                guard !Task.isCancelled else { return }
                self.album?.songs.append(contentsOf: result.songs)
                self.songsContinuation = result.nextContinuation
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoadingMore = false
        }
    }
}
