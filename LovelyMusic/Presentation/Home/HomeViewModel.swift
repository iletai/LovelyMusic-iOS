import Foundation

@MainActor @Observable
final class HomeViewModel {
    private let browseHomeUseCase: BrowseHomeUseCase
    private let invalidateCache: (() async -> Void)?
    private let drainPolicy: HomeContinuationDrainPolicy
    private let minInitialSections = 8
    private let maxInitialPages = 3

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadMoreTask: Task<Void, Never>?

    /// Recently played songs for "Continue Listening" section
    private(set) var recentlyPlayed: [Song] = []
    /// Whether the user has dismissed the "Continue Listening" card this session
    private(set) var continueListeningDismissed = false
    private(set) var sections: [MusicSection] = []
    private(set) var moodAndGenres: [MoodAndGenre] = []
    private(set) var chips: [HomeChip] = []
    private(set) var selectedChipId: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: String?
    private(set) var error: String?
    /// Soft banner shown when the underlying InnerTube layer has been in
    /// `degradedVisitorState` for longer than `degradationGracePeriod`. Cleared
    /// immediately when the layer recovers. Set via the
    /// `.innerTubeDegradedStateChanged` notification from `InnerTubeAPI` (see
    /// polish-B2 acceptance #4 — consumer wiring closure).
    private(set) var degradationNotice: String?
    /// Timestamp of the most recent successful `loadHome()` or `refresh()`.
    /// Drives the "Updated …" subtitle in `HomeView` (polish-B5).
    private(set) var lastSuccessfulRefreshAt: Date?
    private var continuationToken: String?

    var hasMore: Bool { continuationToken != nil }

    @ObservationIgnored
    private var settingsObserver: Any?
    @ObservationIgnored
    private var recentlyPlayedObserver: Any?
    @ObservationIgnored
    private var degradationObserver: Any?
    @ObservationIgnored
    private var degradationGraceTask: Task<Void, Never>?
    @ObservationIgnored
    private let degradationGracePeriod: TimeInterval = 30

    init(
        browseHomeUseCase: BrowseHomeUseCase,
        invalidateCache: (() async -> Void)? = nil,
        drainPolicy: HomeContinuationDrainPolicy = .default
    ) {
        self.browseHomeUseCase = browseHomeUseCase
        self.invalidateCache = invalidateCache
        self.drainPolicy = drainPolicy
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        // Auto-refresh recently played when history changes (e.g., user plays a new song)
        recentlyPlayedObserver = NotificationCenter.default.addObserver(
            forName: .recentlyPlayedChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadRecentlyPlayed()
            }
        }
        // Soft banner for prolonged InnerTube degraded state (polish-B2 #4).
        // Show only after a 30s grace period to avoid flashing the banner for
        // transient blips; clear immediately on recovery.
        degradationObserver = NotificationCenter.default.addObserver(
            forName: .innerTubeDegradedStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let degraded = (note.userInfo?["degraded"] as? Bool) ?? false
            Task { @MainActor [weak self] in
                self?.handleDegradedStateChange(degraded)
            }
        }
    }

    deinit {
        loadTask?.cancel()
        loadMoreTask?.cancel()
        degradationGraceTask?.cancel()
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = recentlyPlayedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = degradationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleDegradedStateChange(_ degraded: Bool) {
        degradationGraceTask?.cancel()
        guard degraded else {
            // Recovered — clear immediately.
            degradationNotice = nil
            return
        }
        // Schedule the soft banner after the grace period; keeps short blips invisible.
        let grace = degradationGracePeriod
        degradationGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.degradationNotice = String(
                localized: "Connection limited — recommendations may be reduced."
            )
        }
    }

    func loadHome() {
        loadRecentlyPlayed()
        guard sections.isEmpty else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoading = true
            error = nil

            var lastError: Error?
            let maxRetries = 3

            for attempt in 1...maxRetries {
                guard !Task.isCancelled else { return }
                do {
                    // First page — includes moods, chips, sections
                    let result = try await browseHomeUseCase.execute()
                    guard !Task.isCancelled else { return }
                    print(
                        "🎵 [HomeVM] browseHome returned \(result.sections.count) sections: \(result.sections.map { $0.title })"
                    )

                    var allSections = result.sections
                    moodAndGenres = result.moodAndGenres
                    chips = result.chips
                    var nextToken = result.continuation
                    var pagesLoaded = 1

                    if drainPolicy.isEnabled {
                        // Full drain-with-budget path
                        let drainResult = try await drainContinuations(
                            initialSections: allSections,
                            initialToken: nextToken,
                            policy: drainPolicy
                        )
                        guard !Task.isCancelled else { return }
                        allSections = drainResult.sections
                        nextToken = drainResult.continuation
                    } else {
                        // Legacy mini-drain: pre-fetch until minInitialSections
                        while allSections.count < minInitialSections,
                            let token = nextToken,
                            pagesLoaded < maxInitialPages,
                            !Task.isCancelled
                        {
                            let more = try await browseHomeUseCase.loadMore(token: token)
                            guard !Task.isCancelled else { return }
                            allSections.append(contentsOf: more.sections)
                            nextToken = more.continuation
                            pagesLoaded += 1
                        }
                    }

                    sections = ContentPreferences.filtered(allSections)
                    continuationToken = nextToken
                    lastSuccessfulRefreshAt = Date()
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < maxRetries && !Task.isCancelled {
                        // Exponential back-off: 2s, 4s between retries
                        let delayNs: UInt64 = 2_000_000_000 * UInt64(attempt)
                        try? await Task.sleep(nanoseconds: delayNs)
                    }
                }
            }

            if lastError != nil, sections.isEmpty {
                guard !Task.isCancelled else { return }
                self.error =
                    "Unable to load music right now. Check your connection and pull to refresh."
            }
            isLoading = false
        }
    }

    func refresh() {
        loadRecentlyPlayed()
        loadTask?.cancel()
        loadMoreTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await invalidateCache?()
            isLoading = true
            error = nil
            continuationToken = nil
            selectedChipId = nil
            do {
                // First page
                let result = try await browseHomeUseCase.execute()
                guard !Task.isCancelled else { return }

                var allSections = result.sections
                moodAndGenres = result.moodAndGenres
                chips = result.chips
                var nextToken = result.continuation
                var pagesLoaded = 1

                if drainPolicy.isEnabled {
                    let drainResult = try await drainContinuations(
                        initialSections: allSections,
                        initialToken: nextToken,
                        policy: drainPolicy
                    )
                    guard !Task.isCancelled else { return }
                    allSections = drainResult.sections
                    nextToken = drainResult.continuation
                } else {
                    // Pre-fetch additional pages
                    while allSections.count < minInitialSections,
                        let token = nextToken,
                        pagesLoaded < maxInitialPages,
                        !Task.isCancelled
                    {
                        let more = try await browseHomeUseCase.loadMore(token: token)
                        guard !Task.isCancelled else { return }
                        allSections.append(contentsOf: more.sections)
                        nextToken = more.continuation
                        pagesLoaded += 1
                    }
                }

                sections = ContentPreferences.filtered(allSections)
                continuationToken = nextToken
                lastSuccessfulRefreshAt = Date()
            } catch {
                guard !Task.isCancelled else { return }
                self.error =
                    "Unable to load music right now. Check your connection and pull to refresh."
            }
            isLoading = false
        }
    }

    func selectChip(_ chip: HomeChip) {
        // Cancel both load and pagination tasks so a stale `loadMore`
        // continuation cannot append unfiltered sections into the chip
        // view after the new chip's filtered results have committed
        // (mirrors the dual-cancel pattern in `refresh()`).
        loadTask?.cancel()
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
        // User tap should reflect the in-flight state on the same runloop tick;
        // the Task body runs on the next hop.
        isLoading = true
        error = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            // `defer` guarantees `isLoading = false` even when an early
            // `guard !Task.isCancelled` exits mid-loop, preventing a
            // stuck spinner if the task is cancelled before reaching the
            // explicit terminal assignment.
            defer { if !Task.isCancelled { self.isLoading = false } }
            guard !Task.isCancelled else { return }

            // Deselect path: chip was active, tap re-issues unfiltered home.
            if selectedChipId == chip.id {
                selectedChipId = nil
                do {
                    let result = try await browseHomeUseCase.execute()
                    guard !Task.isCancelled else { return }
                    var allSections = result.sections
                    moodAndGenres = result.moodAndGenres
                    if !result.chips.isEmpty { chips = result.chips }
                    var nextToken = result.continuation
                    var pagesLoaded = 1
                    if drainPolicy.isEnabled {
                        let drainResult = try await drainContinuations(
                            initialSections: allSections,
                            initialToken: nextToken,
                            policy: drainPolicy
                        )
                        guard !Task.isCancelled else { return }
                        allSections = drainResult.sections
                        nextToken = drainResult.continuation
                    } else {
                        while allSections.count < minInitialSections,
                            let token = nextToken,
                            pagesLoaded < maxInitialPages,
                            !Task.isCancelled
                        {
                            let more = try await browseHomeUseCase.loadMore(token: token)
                            guard !Task.isCancelled else { return }
                            allSections.append(contentsOf: more.sections)
                            nextToken = more.continuation
                            pagesLoaded += 1
                        }
                    }
                    sections = ContentPreferences.filtered(allSections)
                    continuationToken = nextToken
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error =
                        "Unable to load music right now. Check your connection and pull to refresh."
                }
                return
            }

            // Select path: apply chip filter.
            selectedChipId = chip.id
            do {
                let result = try await browseHomeUseCase.execute(params: chip.params)
                guard !Task.isCancelled else { return }
                var allSections = result.sections
                if !result.chips.isEmpty { chips = result.chips }
                var nextToken = result.continuation
                var pagesLoaded = 1
                if drainPolicy.isEnabled {
                    let drainResult = try await drainContinuations(
                        initialSections: allSections,
                        initialToken: nextToken,
                        policy: drainPolicy
                    )
                    guard !Task.isCancelled else { return }
                    allSections = drainResult.sections
                    nextToken = drainResult.continuation
                } else {
                    while allSections.count < minInitialSections,
                        let token = nextToken,
                        pagesLoaded < maxInitialPages,
                        !Task.isCancelled
                    {
                        let more = try await browseHomeUseCase.loadMore(token: token)
                        guard !Task.isCancelled else { return }
                        allSections.append(contentsOf: more.sections)
                        nextToken = more.continuation
                        pagesLoaded += 1
                    }
                }
                sections = ContentPreferences.filtered(allSections)
                continuationToken = nextToken
            } catch {
                guard !Task.isCancelled else { return }
                self.error =
                    "Unable to load music right now. Check your connection and pull to refresh."
            }
        }
    }

    // MARK: - Continuation Drain

    /// Fetches continuation pages until the budget is exhausted (page count or
    /// wall-clock time) or there are no more tokens. Resilient: a single page
    /// failure stops the loop but surfaces everything fetched so far.
    private func drainContinuations(
        initialSections: [MusicSection],
        initialToken: String?,
        policy: HomeContinuationDrainPolicy
    ) async throws -> (sections: [MusicSection], continuation: String?) {
        guard policy.isEnabled else {
            return (initialSections, initialToken)
        }

        var allSections = initialSections
        var nextToken = initialToken
        var pagesLoaded = 0
        let startTime = ContinuousClock.now

        while let token = nextToken,
              pagesLoaded < policy.maxPages,
              ContinuousClock.now - startTime < .seconds(policy.maxDuration),
              !Task.isCancelled
        {
            do {
                let more = try await browseHomeUseCase.loadMore(token: token)
                guard !Task.isCancelled else { return (allSections, nextToken) }
                allSections.append(contentsOf: more.sections)
                nextToken = more.continuation
                pagesLoaded += 1
            } catch {
                // Resilience: surface what we have so far
                Log.ui.warning("Drain page \(pagesLoaded) failed: \(error.localizedDescription)")
                break
            }
        }

        // Telemetry
        let elapsed = ContinuousClock.now - startTime
        let elapsedMs = Int(
            elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
        )
        let itemCount = allSections.reduce(0) { $0 + $1.items.count }

        if nextToken == nil {
            Log.ui.debug(
                "[Drain] completed: pages=\(pagesLoaded), duration=\(elapsedMs)ms, items=\(itemCount)"
            )
        } else {
            let reason = pagesLoaded >= policy.maxPages ? "maxPages" : "maxDuration"
            Log.ui.debug(
                "[Drain] budget exhausted: reason=\(reason), pages=\(pagesLoaded), duration=\(elapsedMs)ms"
            )
        }

        return (allSections, nextToken)
    }

    // MARK: - Recently Played

    /// Load recently played songs from local storage for "Continue Listening" section.
    /// Reads directly from UserDefaults to avoid coupling with ManagePlaylistUseCase,
    /// which is not injected into this view model.
    func loadRecentlyPlayed() {
        guard let data = UserDefaults.standard.data(forKey: "recently_played"),
            let songs = try? JSONDecoder().decode([Song].self, from: data)
        else {
            recentlyPlayed = []
            return
        }
        recentlyPlayed = Array(ContentPreferences.filteredSongs(songs).prefix(4))
    }

    /// Dismiss the "Continue Listening" card for this session
    func dismissContinueListening() {
        continueListeningDismissed = true
    }

    func loadMore() {
        guard let token = continuationToken, !isLoadingMore else { return }
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isLoadingMore = true
            loadMoreError = nil
            do {
                let result = try await browseHomeUseCase.loadMore(token: token)
                guard !Task.isCancelled else { return }
                sections.append(contentsOf: ContentPreferences.filtered(result.sections))
                if sections.count > AppConstants.Home.maxSections {
                    sections = Array(sections.suffix(AppConstants.Home.maxSections))
                }
                continuationToken = result.continuation
            } catch {
                guard !Task.isCancelled else { return }
                Log.ui.error("Failed to load more home content: \(error)")
                loadMoreError = error.localizedDescription
            }
            isLoadingMore = false
        }
    }
}
