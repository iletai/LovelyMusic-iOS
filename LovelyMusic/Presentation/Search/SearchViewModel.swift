import Foundation

@MainActor @Observable
final class SearchViewModel {
    private let searchUseCase: SearchMusicUseCase
    private let browseHomeUseCase: BrowseHomeUseCase

    var query: String = "" {
        didSet { onQueryChanged() }
    }
    private(set) var selectedFilter: SearchFilter?

    private(set) var suggestions: [String] = []
    private(set) var results: SearchResult = .empty
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var paginationError: String?
    private(set) var hasCompletedSearch = false
    private(set) var resultRevision = 0

    var showSuggestions: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasCompletedSearch && !isSearching && error == nil
    }

    var hasResults: Bool {
        !results.songs.isEmpty || !results.albums.isEmpty
            || !results.artists.isEmpty || !results.playlists.isEmpty
    }

    private(set) var searchHistory: [String] = []
    private(set) var moodAndGenres: [MoodAndGenre] = []
    private(set) var exploreSections: [MusicSection] = []
    private(set) var isLoadingExplore = false

    private nonisolated static let historyKey = "search_history"

    private(set) var trendingSuggestions: [String] = []
    private(set) var isLoadingTrending = false
    @ObservationIgnored
    private var trendingTask: Task<Void, Never>?

    private func loadHistory() {
        // Migrate from legacy key if needed
        let defaults = UserDefaults.standard
        if let legacy = defaults.stringArray(forKey: "searchHistory"), !legacy.isEmpty,
            defaults.stringArray(forKey: Self.historyKey) == nil
        {
            defaults.set(Array(legacy.prefix(20)), forKey: Self.historyKey)
            defaults.removeObject(forKey: "searchHistory")
        }
        searchHistory = defaults.stringArray(forKey: Self.historyKey) ?? []
    }

    func addToHistory(_ query: String) {
        guard !UserDefaults.standard.bool(forKey: "pauseSearchHistory") else { return }

        var history = searchHistory
        history.removeAll { $0 == query }
        history.insert(query, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        searchHistory = history
        // M-01: Move UserDefaults write off main thread
        Task.detached(priority: .utility) {
            UserDefaults.standard.set(history, forKey: SearchViewModel.historyKey)
        }
    }

    /// Remove a single entry from search history
    func deleteFromHistory(_ term: String) {
        searchHistory.removeAll { $0 == term }
        Task.detached(priority: .utility) { [history = self.searchHistory] in
            UserDefaults.standard.set(history, forKey: SearchViewModel.historyKey)
        }
    }

    func clearHistory() {
        searchHistory = []
        // M-01: Move UserDefaults write off main thread
        Task.detached(priority: .utility) {
            UserDefaults.standard.removeObject(forKey: SearchViewModel.historyKey)
        }
    }

    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var searchExecuteTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored
    private var requestGeneration = 0
    @ObservationIgnored
    private var shouldApplyDefaultFilter = true
    @ObservationIgnored
    private var exploreTask: Task<Void, Never>?

    init(searchUseCase: SearchMusicUseCase, browseHomeUseCase: BrowseHomeUseCase) {
        self.searchUseCase = searchUseCase
        self.browseHomeUseCase = browseHomeUseCase
        loadHistory()
    }

    deinit {
        searchTask?.cancel()
        searchExecuteTask?.cancel()
        loadMoreTask?.cancel()
        exploreTask?.cancel()
        trendingTask?.cancel()
    }

    // MARK: - Actions

    func search() {
        let submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuery.isEmpty else { return }

        searchTask?.cancel()
        if selectedFilter == nil, shouldApplyDefaultFilter {
            selectedFilter = .songs
        }
        let submittedFilter = selectedFilter

        invalidateResultRequests()
        let generation = requestGeneration
        suggestions = []
        results = .empty
        hasCompletedSearch = false
        isSearching = true
        error = nil
        paginationError = nil

        searchExecuteTask = Task { [weak self] in
            guard let self, !Task.isCancelled, requestGeneration == generation else { return }
            defer {
                if requestGeneration == generation {
                    isSearching = false
                }
            }

            do {
                let result = try await searchUseCase.execute(
                    query: submittedQuery,
                    filter: submittedFilter
                )
                guard !Task.isCancelled, requestGeneration == generation else { return }

                results = normalizedResult(ContentPreferences.filtered(result))
                hasCompletedSearch = true
                resultRevision &+= 1
                addToHistory(submittedQuery)
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                self.error = error.localizedDescription
                hasCompletedSearch = true
            }
        }
    }

    func loadMore() {
        guard let continuation = results.continuation, !isLoadingMore else { return }
        loadMoreTask?.cancel()
        let generation = requestGeneration
        isLoadingMore = true
        paginationError = nil
        loadMoreTask = Task { [weak self] in
            guard let self, !Task.isCancelled, requestGeneration == generation else { return }
            defer {
                if requestGeneration == generation {
                    isLoadingMore = false
                }
            }

            do {
                let more = try await searchUseCase.continueSearch(token: continuation)
                guard !Task.isCancelled, requestGeneration == generation else { return }

                let merged = normalizedResult(
                    ContentPreferences.filtered(
                        SearchResult(
                            songs: results.songs + more.songs,
                            albums: results.albums + more.albums,
                            artists: results.artists + more.artists,
                            playlists: results.playlists + more.playlists,
                            continuation: more.continuation
                        )
                    )
                )
                results = cappedResult(merged)
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                paginationError = error.localizedDescription
            }
        }
    }

    func selectSuggestion(_ suggestion: String) {
        query = suggestion
        search()
    }

    func selectFilter(_ filter: SearchFilter?) {
        selectedFilter = filter
        shouldApplyDefaultFilter = false
    }

    func resetFilterToDefault() {
        selectedFilter = nil
        shouldApplyDefaultFilter = true
    }

    func clearSearch() {
        query = ""
        resetFilterToDefault()
    }

    func loadTrending() {
        guard trendingSuggestions.isEmpty else { return }
        trendingTask?.cancel()
        trendingTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoadingTrending = true
            do {
                let results = try await searchUseCase.suggestions(query: "")
                guard !Task.isCancelled else { return }
                trendingSuggestions = results
            } catch {
                guard !Task.isCancelled else { return }
                Log.ui.error("Failed to load trending suggestions: \(error)")
            }
            isLoadingTrending = false
        }
    }

    func loadExplore() {
        guard moodAndGenres.isEmpty && exploreSections.isEmpty else { return }
        exploreTask?.cancel()
        exploreTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoadingExplore = true
            do {
                let result = try await browseHomeUseCase.execute()
                guard !Task.isCancelled else { return }
                moodAndGenres = result.moodAndGenres
                exploreSections = Array(result.sections.prefix(3))
            } catch {
                guard !Task.isCancelled else { return }
                Log.ui.error("Failed to load explore content: \(error)")
            }
            isLoadingExplore = false
        }
    }

    // MARK: - Private

    private func invalidateResultRequests() {
        requestGeneration &+= 1
        searchExecuteTask?.cancel()
        loadMoreTask?.cancel()
        searchExecuteTask = nil
        loadMoreTask = nil
        isSearching = false
        isLoadingMore = false
    }

    private func normalizedResult(_ result: SearchResult) -> SearchResult {
        SearchResult(
            songs: unique(result.songs, by: \.id),
            albums: unique(result.albums, by: \.id),
            artists: unique(result.artists, by: \.id),
            playlists: unique(result.playlists, by: \.id),
            continuation: result.continuation
        )
    }

    private func unique<Element>(
        _ elements: [Element],
        by id: KeyPath<Element, String>
    ) -> [Element] {
        var seen = Set<String>()
        return elements.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private func cappedResult(_ result: SearchResult) -> SearchResult {
        let maxSongs = 200
        let maxOther = 50
        return SearchResult(
            songs: Array(result.songs.suffix(maxSongs)),
            albums: Array(result.albums.suffix(maxOther)),
            artists: Array(result.artists.suffix(maxOther)),
            playlists: Array(result.playlists.suffix(maxOther)),
            continuation: result.continuation
        )
    }

    private func onQueryChanged() {
        searchTask?.cancel()
        invalidateResultRequests()
        suggestions = []
        results = .empty
        hasCompletedSearch = false
        error = nil
        paginationError = nil

        let suggestionQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestionQuery.isEmpty else {
            resetFilterToDefault()
            return
        }

        let generation = requestGeneration
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            await fetchSuggestions(query: suggestionQuery, generation: generation)
        }
    }

    private func fetchSuggestions(query: String, generation: Int) async {
        guard !Task.isCancelled, requestGeneration == generation else { return }
        do {
            let result = try await searchUseCase.suggestions(query: query)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            suggestions = result
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            Log.ui.error("Failed to fetch suggestions: \(error)")
        }
    }
}
