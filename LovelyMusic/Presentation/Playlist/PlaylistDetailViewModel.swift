import Foundation

@MainActor @Observable
final class PlaylistDetailViewModel {
    private let getPlaylistUseCase: GetPlaylistUseCase
    private let managePlaylistUseCase: ManagePlaylistUseCase?

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored
    private var removeSongsTask: Task<Void, Never>?

    private(set) var playlist: Playlist?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var songsContinuation: String?

    var searchText: String = "" {
        didSet { updateFilteredSongs() }
    }
    private(set) var filteredSongs: [Song] = []

    var hasMoreSongs: Bool { songsContinuation != nil }

    // Rename playlist
    var isRenamingPlaylist = false
    var renameText = ""

    init(getPlaylistUseCase: GetPlaylistUseCase, managePlaylistUseCase: ManagePlaylistUseCase? = nil) {
        self.getPlaylistUseCase = getPlaylistUseCase
        self.managePlaylistUseCase = managePlaylistUseCase
    }

    deinit {
        loadTask?.cancel()
        loadMoreTask?.cancel()
        removeSongsTask?.cancel()
    }

    func loadPlaylist(playlistId: String) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoading = true
            error = nil
            do {
                if let manageUseCase = managePlaylistUseCase {
                    let allPlaylists = try await manageUseCase.getAllPlaylists()
                    guard !Task.isCancelled else { return }
                    if let localPlaylist = allPlaylists.first(where: { $0.id == playlistId }) {
                        self.playlist = localPlaylist
                        self.updateFilteredSongs()
                        isLoading = false
                        return
                    }
                }
                let result = try await getPlaylistUseCase.execute(playlistId: playlistId)
                guard !Task.isCancelled else { return }
                self.playlist = result.playlist
                self.songsContinuation = result.continuation
                self.updateFilteredSongs()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    func loadMoreSongs() {
        guard let token = songsContinuation, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            guard let self, !Task.isCancelled else {
                self?.isLoadingMore = false
                return
            }
            do {
                let result = try await getPlaylistUseCase.loadMoreSongs(continuation: token)
                guard !Task.isCancelled else { return }
                self.playlist?.songs.append(contentsOf: result.songs)
                self.songsContinuation = result.nextContinuation
                self.updateFilteredSongs()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoadingMore = false
        }
    }

    func removeSongs(songIds: Set<String>) {
        guard let playlist, let managePlaylistUseCase else { return }
        let playlistId = playlist.id
        removeSongsTask?.cancel()
        removeSongsTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            for songId in songIds {
                guard !Task.isCancelled else { return }
                do {
                    try await managePlaylistUseCase.removeSong(songId: songId, from: playlistId)
                } catch {
                    Log.playlist.error("Failed to remove song \(songId, privacy: .public) from playlist: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard !Task.isCancelled else { return }
            loadPlaylist(playlistId: playlistId)
        }
    }

    private func updateFilteredSongs() {
        guard let songs = playlist?.songs else {
            filteredSongs = []
            return
        }

        let visibleSongs = ContentPreferences.filteredSongs(songs)
        if searchText.isEmpty {
            filteredSongs = visibleSongs
        } else {
            let query = searchText.lowercased()
            filteredSongs = visibleSongs.filter {
                $0.title.lowercased().contains(query)
                    || $0.artistName.lowercased().contains(query)
            }
        }
    }

    // MARK: - Rename

    func startRename() {
        guard let playlist, playlist.isLocal else { return }
        renameText = playlist.title
        isRenamingPlaylist = true
    }

    func confirmRename() async {
        let trimmedName = renameText.trimmingCharacters(in: .whitespaces)
        guard let playlist, !trimmedName.isEmpty else { return }
        guard let managePlaylistUseCase else {
            self.error = "Cannot rename: playlist management unavailable"
            isRenamingPlaylist = false
            return
        }
        do {
            try await managePlaylistUseCase.renamePlaylist(id: playlist.id, name: trimmedName)
            self.playlist?.title = trimmedName
            self.renameText = trimmedName
            NotificationCenter.default.post(name: .playlistsChanged, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
        isRenamingPlaylist = false
    }
}
