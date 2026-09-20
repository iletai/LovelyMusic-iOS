import CarPlay
import MediaPlayer
import Nuke

// MARK: - CarPlay Scene Delegate

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var nowPlayingTab: CPListTemplate?
    private var searchTemplate: CPSearchTemplate?

    /// Idempotency guard for `CPNowPlayingTemplate.shared.add(self)` (F4).
    /// `CPNowPlayingTemplate` is a process-wide singleton; without this flag
    /// every CarPlay reconnect would attach a fresh observer.
    private var isNowPlayingObserverAttached = false

    /// Set to `false` from `didDisconnect` to halt the re-arming observation
    /// loop introduced by A2 (`observeAudioEngineState`).
    private var isObservationActive = false

    /// Round 2 — Fix 3 (review-codex HIGH #2): cache of the most recent
    /// search results so `searchTemplate(_:selectedResult:completionHandler:)`
    /// can route taps through `handleSongTap` (same path as other tabs)
    /// instead of acknowledging the tap with no playback effect. Refreshed on
    /// every `updatedSearchText` callback. CPListItem instances are mapped to
    /// `Song` via `item.userInfo`.
    private var latestSearchSongs: [Song] = []

    /// Round 2 — Fix 4 (review-codex MED #4): one-shot observer token used
    /// when CarPlay attaches before `DIContainer.shared` becomes non-nil
    /// (first-install bootstrap race). Removed as soon as it fires or the
    /// scene disconnects, whichever comes first.
    private var bootstrapObserver: NSObjectProtocol?

    /// Thumbnail size for CarPlay list items (2x for Retina)
    private let thumbnailSize = CGSize(width: 90, height: 90)

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        // Round 2 — Fix 4 (review-codex MED #4): CarPlay can attach during
        // the first-install splash gate (LovelyMusicApp.runBootstrapGate),
        // before `DIContainer.shared` is non-nil. Building the UI here would
        // produce empty tabs that never refresh because all `container?…`
        // accessors short-circuit on nil. Defer the build until DI lands by
        // listening for `.lovelyMusicDIContainerReady` (posted at the end of
        // `DIContainer.init`). When the container is already up, build
        // immediately. Notification path chosen over `Task` polling because
        // it is event-driven and single-shot.
        if DIContainer.shared != nil {
            buildRootUI(on: interfaceController)
        } else {
            print("🚗 [CarPlay] DIContainer not ready at didConnect — awaiting bootstrap")
            bootstrapObserver = NotificationCenter.default.addObserver(
                forName: .lovelyMusicDIContainerReady,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if let token = self.bootstrapObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.bootstrapObserver = nil
                }
                guard let controller = self.interfaceController else { return }
                print("🚗 [CarPlay] DIContainer ready — building deferred UI")
                self.buildRootUI(on: controller)
            }
        }
    }

    /// Round 2 — Fix 4: extracted root-UI construction so it can run either
    /// inline at `didConnect` (DI ready) or from the bootstrap-ready
    /// notification (DI deferred during first-install splash gate).
    private func buildRootUI(on interfaceController: CPInterfaceController) {
        // Configure shared Now Playing template (system shows it automatically during playback)
        configureNowPlaying()

        let tabBar = CPTabBarTemplate(templates: [
            makeNowPlayingTab(),
            makeSearchTab(),
            makeBrowseTab(),
            makePlaylistsTab(),
            makeSuggestionsTab(),
        ])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        // A2 — start observing AudioEngine state so plays initiated outside
        // CarPlay (phone, lock screen, AirPods, remote command center) refresh
        // the Now Playing tab + buttons + album-artist gating.
        isObservationActive = true
        observeAudioEngineState()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        // F4 — explicitly remove the singleton observer so reconnects don't
        // accumulate stale delegates.
        if isNowPlayingObserverAttached {
            CPNowPlayingTemplate.shared.remove(self)
            isNowPlayingObserverAttached = false
        }
        // Round 2 — Fix 4: clean up the deferred bootstrap observer if the
        // scene disconnects before DI lands (e.g. user yanks the cable
        // during the splash gate).
        if let token = bootstrapObserver {
            NotificationCenter.default.removeObserver(token)
            bootstrapObserver = nil
        }
        isObservationActive = false
        self.interfaceController = nil
        self.nowPlayingTab = nil
        self.searchTemplate = nil
    }

    // MARK: - Now Playing Configuration

    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = true
        // F6 / A4 — derive album-artist enabled state from the current track.
        template.isAlbumArtistButtonEnabled = isValidAlbumBrowseId(
            container?.audioEngine.currentTrack?.albumId
        )
        template.updateNowPlayingButtons(makeNowPlayingButtons())
        if !isNowPlayingObserverAttached {
            template.add(self)
            isNowPlayingObserverAttached = true
        }
    }

    // MARK: - A2 — AudioEngine state observation

    /// Re-arming `withObservationTracking` (D-5). Each tracked-property read
    /// installs a one-shot tracker; the `onChange` closure fires on the next
    /// mutation, schedules a UI refresh, and re-arms by calling self.
    private func observeAudioEngineState() {
        guard isObservationActive, let engine = container?.audioEngine else { return }
        withObservationTracking {
            _ = engine.currentTrack
            _ = engine.isPlaying
            _ = engine.shuffleEnabled
            _ = engine.repeatMode
            _ = engine.queue
            _ = engine.currentIndex
        } onChange: { [weak self] in
            // `onChange` may fire off-main; hop to MainActor for UI work.
            Task { @MainActor [weak self] in
                guard let self, self.isObservationActive else { return }
                self.refreshNowPlayingTab()
                self.refreshNowPlayingButtons()
                self.refreshAlbumArtistGating()
                self.observeAudioEngineState()  // re-arm
            }
        }
    }

    private func refreshAlbumArtistGating() {
        let track = container?.audioEngine.currentTrack
        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = isValidAlbumBrowseId(
            track?.albumId)
    }

    /// F6 / A4 — only enable album/artist navigation when the current song
    /// carries a real InnerTube browse id. `MPRE…` is the canonical album
    /// prefix; `OLAK5…` is the legacy album-as-playlist prefix that
    /// `getAlbumUseCase` accepts.
    private func isValidAlbumBrowseId(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return id.hasPrefix("MPRE") || id.hasPrefix("OLAK5")
    }

    // MARK: - Tab: Now Playing

    /// Now Playing tab uses a CPListTemplate wrapper.
    /// CPNowPlayingTemplate cannot be a tab — it must be pushed.
    /// Ref: https://developer.apple.com/documentation/carplay/cpnowplayingtemplate
    private func makeNowPlayingTab() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "Now Playing"),
            sections: buildNowPlayingTabSections()
        )
        template.tabTitle = String(localized: "Now Playing")
        template.tabImage = UIImage(systemName: "play.circle.fill")
        nowPlayingTab = template
        return template
    }

    private func buildNowPlayingTabSections() -> [CPListSection] {
        // F7 — read `currentTrack` directly so prefetch / autoplay queue
        // mutations don't desync this view from actual playback.
        guard let engine = container?.audioEngine, let song = engine.currentTrack else {
            // Empty state when nothing is playing
            let hint = CPListItem(
                text: String(localized: "Nothing playing"),
                detailText: String(localized: "Pick a song from Browse or For You"),
                image: UIImage(systemName: "play.slash")
            )
            return [CPListSection(items: [hint])]
        }

        // Current song — tap to open full Now Playing screen
        let currentItem = CPListItem(
            text: song.title,
            detailText: "\(song.artistName) · \(song.formattedDuration)",
            image: UIImage(systemName: "music.note")
        )
        currentItem.isPlaying = true
        currentItem.handler = { [weak self] _, completion in
            self?.openNowPlaying()
            completion()
        }
        loadThumbnail(for: song, into: currentItem)

        // Queue shortcut
        let queueItem = makeListImageItem(
            text: String(localized: "Queue"),
            image: UIImage(systemName: "list.bullet")
        ) { [weak self] in self?.showQueue() }

        return [
            CPListSection(
                items: [currentItem],
                header: String(localized: "Playing now"),
                sectionIndexTitle: nil
            ),
            CPListSection(items: [queueItem]),
        ]
    }

    /// Push the full Now Playing screen onto the current tab's navigation stack.
    /// Pops first to prevent duplicate stacks if already showing.
    private func openNowPlaying() {
        guard let controller = interfaceController else { return }
        // Prevent stacking multiple NowPlaying templates
        if controller.topTemplate is CPNowPlayingTemplate { return }
        controller.pushTemplate(
            CPNowPlayingTemplate.shared,
            animated: true,
            completion: nil
        )
    }

    /// Refresh the Now Playing tab to show current track info
    private func refreshNowPlayingTab() {
        nowPlayingTab?.updateSections(buildNowPlayingTabSections())
    }

    private func makeNowPlayingButtons() -> [CPNowPlayingButton] {
        var buttons: [CPNowPlayingButton] = []

        let shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
            Task { @MainActor in
                self?.container?.audioEngine.shuffleEnabled.toggle()
                self?.refreshNowPlayingButtons()
            }
        }
        buttons.append(shuffleButton)

        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            Task { @MainActor in
                guard let engine = self?.container?.audioEngine else { return }
                switch engine.repeatMode {
                case .off: engine.repeatMode = .all
                case .all: engine.repeatMode = .one
                case .one: engine.repeatMode = .off
                }
                self?.refreshNowPlayingButtons()
            }
        }
        buttons.append(repeatButton)

        return buttons
    }

    private func refreshNowPlayingButtons() {
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(makeNowPlayingButtons())
    }

    // MARK: - Tab: Search (A5 / F5)

    /// Full YouTube Music catalog search via `searchMusicUseCase`. The previous
    /// inline comment claimed audio apps cannot use `CPSearchTemplate` \u2014 that
    /// is incorrect for iOS 14+ CarPlay (audio category supports search).
    private func makeSearchTab() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        template.tabTitle = String(localized: "Search")
        template.tabImage = UIImage(systemName: "magnifyingglass")
        searchTemplate = template
        return template
    }

    // MARK: - Tab: Browse (Recently Played + Favorites)

    private func makeBrowseTab() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "Browse"),
            sections: [
                CPListSection(items: [
                    makeListImageItem(
                        text: String(localized: "Recently Played"),
                        image: UIImage(systemName: "clock.fill")
                    ) { [weak self] in self?.showRecentlyPlayed() },
                    makeListImageItem(
                        text: String(localized: "Favorites"),
                        image: UIImage(systemName: "heart.fill")
                    ) { [weak self] in self?.showFavorites() },
                ])
            ]
        )
        template.tabTitle = String(localized: "Browse")
        template.tabImage = UIImage(systemName: "music.note.house.fill")
        return template
    }

    private func showRecentlyPlayed() {
        guard let container else { return }
        let title = String(localized: "Recently Played")
        let loadingTemplate = CPListTemplate(
            title: title,
            sections: [CPListSection(items: [makeLoadingItem()])]
        )
        interfaceController?.pushTemplate(loadingTemplate, animated: true, completion: nil)

        Task { @MainActor in
            do {
                let songs = try await container.managePlaylistUseCase.getRecentlyPlayed()
                if songs.isEmpty {
                    loadingTemplate.updateSections([
                        CPListSection(items: [makeEmptyItem()])
                    ])
                    return
                }
                let songList = Array(songs.prefix(50))
                var sections: [CPListSection] = [
                    CPListSection(items: makePlayAllItems(songs: songList))
                ]
                let items = songList.map { song in
                    self.makeSongItem(song, fromQueue: songList)
                }
                sections.append(CPListSection(items: items))
                loadingTemplate.updateSections(sections)
            } catch {
                loadingTemplate.updateSections([
                    CPListSection(items: [makeErrorItem(error)])
                ])
            }
        }
    }

    private func showFavorites() {
        guard let container else { return }
        let title = String(localized: "Favorites")
        let loadingTemplate = CPListTemplate(
            title: title,
            sections: [CPListSection(items: [makeLoadingItem()])]
        )
        interfaceController?.pushTemplate(loadingTemplate, animated: true, completion: nil)

        Task { @MainActor in
            do {
                let songs = try await container.manageFavoritesUseCase.getAllFavorites()
                if songs.isEmpty {
                    loadingTemplate.updateSections([
                        CPListSection(items: [makeEmptyItem()])
                    ])
                    return
                }
                let songList = Array(songs.prefix(50))
                var sections: [CPListSection] = [
                    CPListSection(items: makePlayAllItems(songs: songList))
                ]
                let items = songList.map { song in
                    self.makeSongItem(song, fromQueue: songList)
                }
                sections.append(CPListSection(items: items))
                loadingTemplate.updateSections(sections)
            } catch {
                loadingTemplate.updateSections([
                    CPListSection(items: [makeErrorItem(error)])
                ])
            }
        }
    }

    private func showQueue() {
        guard let container else { return }
        Task { @MainActor in
            let queue = container.audioEngine.queue
            let currentIndex = container.audioEngine.currentIndex

            if queue.isEmpty {
                let template = CPListTemplate(
                    title: String(localized: "Queue"),
                    sections: [CPListSection(items: [makeEmptyItem()])]
                )
                self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
                return
            }

            let items: [CPListItem] = queue.enumerated().map { index, song in
                let item = CPListItem(
                    text: song.title,
                    detailText: song.artistName,
                    image: UIImage(
                        systemName: index == currentIndex ? "speaker.wave.2.fill" : "music.note")
                )
                if index == currentIndex {
                    item.isPlaying = true
                }
                item.handler = { [weak self] _, completion in
                    self?.handleSongTap(
                        song, fromQueue: queue,
                        completion: {
                            completion()
                            self?.interfaceController?.popToRootTemplate(
                                animated: true, completion: nil)
                        })
                }
                loadThumbnail(for: song, into: item)
                return item
            }
            let template = CPListTemplate(
                title: "\(String(localized: "Queue")) (\(queue.count))",
                sections: [CPListSection(items: items)]
            )
            self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
        }
    }

    // MARK: - Tab: Playlists

    private func makePlaylistsTab() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "Playlists"),
            sections: [CPListSection(items: [makeLoadingItem()])]
        )
        template.tabTitle = String(localized: "Playlists")
        template.tabImage = UIImage(systemName: "list.bullet.rectangle.fill")
        loadPlaylists(into: template)
        return template
    }

    private func loadPlaylists(into template: CPListTemplate) {
        guard let container else { return }
        Task { @MainActor in
            do {
                let playlists = try await container.managePlaylistUseCase.getAllPlaylists()
                if playlists.isEmpty {
                    template.updateSections([
                        CPListSection(items: [makeEmptyItem()])
                    ])
                    return
                }
                let items = playlists.map { playlist in
                    let songCount = playlist.songs.count
                    let item = CPListItem(
                        text: playlist.title,
                        detailText: String(localized: "\(songCount) songs"),
                        image: UIImage(systemName: "music.note.list")
                    )
                    item.handler = { [weak self] _, completion in
                        self?.showPlaylistDetail(playlist)
                        completion()
                    }
                    return item
                }
                template.updateSections([CPListSection(items: items)])
            } catch {
                template.updateSections([
                    CPListSection(items: [makeErrorItem(error)])
                ])
            }
        }
    }

    private func showPlaylistDetail(_ playlist: Playlist) {
        let songs = playlist.songs
        let songList = Array(songs.prefix(100))
        let items = songList.map { song in
            makeSongItem(song, fromQueue: songs)
        }

        var sections: [CPListSection] = []

        if !songs.isEmpty {
            sections.append(CPListSection(items: makePlayAllItems(songs: songs)))
        }

        if items.isEmpty {
            sections.append(CPListSection(items: [makeEmptyItem()]))
        } else {
            sections.append(CPListSection(items: items))
        }

        let detail = CPListTemplate(title: playlist.title, sections: sections)
        interfaceController?.pushTemplate(detail, animated: true, completion: nil)
    }

    // MARK: - Tab: Suggestions

    /// Audio apps cannot use CPSearchTemplate (navigation-only).
    /// Load home sections (Featured Mix, Chill Vibes, etc.) as browsable suggestions.
    private func makeSuggestionsTab() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "For You"),
            sections: [CPListSection(items: [makeLoadingItem()])]
        )

        template.tabTitle = String(localized: "For You")
        template.tabImage = UIImage(systemName: "sparkles")
        loadHomeSections(into: template)
        return template
    }

    private func loadHomeSections(into template: CPListTemplate) {
        guard let container else { return }
        Task { @MainActor in
            do {
                let result = try await container.browseHomeUseCase.execute()
                if result.sections.isEmpty {
                    template.updateSections([
                        CPListSection(items: [makeEmptyItem()])
                    ])
                    return
                }
                let sections: [CPListSection] = result.sections.prefix(4).map { section in
                    let sectionItems: [CPListItem] = section.items.prefix(12).compactMap { item in
                        switch item {
                        case .song(let song):
                            return self.makeSongItem(
                                song,
                                fromQueue: section.items.compactMap {
                                    if case .song(let s) = $0 { return s }
                                    return nil
                                }
                            )
                        case .album(let album):
                            let albumItem = CPListItem(
                                text: album.title,
                                detailText: album.artistName,
                                image: UIImage(systemName: "square.stack")
                            )
                            albumItem.handler = { [weak self] _, completion in
                                self?.showAlbumDetail(album)
                                completion()
                            }
                            return albumItem
                        case .playlist(let playlist):
                            let plItem = CPListItem(
                                text: playlist.title,
                                detailText: "\(playlist.songs.count) songs",
                                image: UIImage(systemName: "music.note.list")
                            )
                            plItem.handler = { [weak self] _, completion in
                                self?.showPlaylistDetail(playlist)
                                completion()
                            }
                            return plItem
                        case .artist:
                            return nil
                        case .audiobook, .userChannel:
                            return nil
                        }
                    }
                    return CPListSection(
                        items: sectionItems,
                        header: section.title,
                        sectionIndexTitle: nil
                    )
                }
                template.updateSections(sections)
            } catch {
                // Fallback to recently played
                let songs = (try? await container.managePlaylistUseCase.getRecentlyPlayed()) ?? []
                if songs.isEmpty {
                    template.updateSections([
                        CPListSection(items: [makeEmptyItem()])
                    ])
                    return
                }
                let songList = Array(songs.prefix(24))
                let items = songList.map { self.makeSongItem($0, fromQueue: songList) }
                template.updateSections([
                    CPListSection(
                        items: items, header: String(localized: "Recently Played"),
                        sectionIndexTitle: nil)
                ])
            }
        }
    }

    private func showAlbumDetail(_ album: Album) {
        guard let container else { return }
        let loadingTemplate = CPListTemplate(
            title: album.title,
            sections: [CPListSection(items: [makeLoadingItem()])]
        )
        interfaceController?.pushTemplate(loadingTemplate, animated: true, completion: nil)

        Task { @MainActor in
            do {
                let result = try await container.getAlbumUseCase.execute(browseId: album.id)
                let songs = result.album.songs
                if songs.isEmpty {
                    loadingTemplate.updateSections([CPListSection(items: [makeEmptyItem()])])
                    return
                }
                var sections: [CPListSection] = [
                    CPListSection(items: makePlayAllItems(songs: songs))
                ]
                let items = songs.prefix(100).map { self.makeSongItem($0, fromQueue: songs) }
                sections.append(CPListSection(items: items))
                loadingTemplate.updateSections(sections)
            } catch {
                loadingTemplate.updateSections([CPListSection(items: [makeErrorItem(error)])])
            }
        }
    }

    // MARK: - Play All / Shuffle All

    private func makePlayAllItems(songs: [Song]) -> [CPListItem] {
        let playAll = CPListItem(
            text: "▶ \(String(localized: "Play All"))",
            detailText: String(localized: "\(songs.count) songs")
        )
        playAll.handler = { [weak self] _, completion in
            guard let first = songs.first else {
                completion()
                return
            }
            self?.handleSongTap(first, fromQueue: songs, completion: completion)
        }

        let shuffleAll = CPListItem(
            text: "🔀 \(String(localized: "Shuffle All"))",
            detailText: String(localized: "\(songs.count) songs")
        )
        shuffleAll.handler = { [weak self] _, completion in
            let shuffled = songs.shuffled()
            guard let first = shuffled.first else {
                completion()
                return
            }
            // Mirror the existing shuffle-all behavior: pass the shuffled
            // queue verbatim. `AudioEngine.play(song:fromQueue:)` finds the
            // index of the chosen song and uses the supplied queue order.
            self?.handleSongTap(first, fromQueue: shuffled, completion: completion)
        }

        return [playAll, shuffleAll]
    }

    // MARK: - Helpers

    private var container: DIContainer? {
        DIContainer.shared
    }

    /// A3 / D-4 — unified tap handler for any song-tappable row.
    ///
    /// 1. Snapshots `lastError` so we can detect a *new* failure that occurs
    ///    during stream resolution (the failure mode that previously made
    ///    CarPlay taps look unresponsive).
    /// 2. Kicks off `AudioEngine.play(…)` synchronously on the main thread
    ///    (the handler already runs on main — dropping the redundant
    ///    `Task { @MainActor }` wrapper used previously).
    /// 3. Polls AudioEngine state on the main actor, holding `completion()`
    ///    until either: (a) playback starts (`isPlaying && currentTrack ==
    ///    song`), (b) `lastError` changes (failure path — surface a
    ///    `CPAlertTemplate`), or (c) an 8s safety timeout elapses (failsafe).
    ///    The 8s ceiling matches the InnerTube fallback-chain timeout; auto-
    ///    skip behavior in `AudioEngine` is preserved by the recovery service
    ///    independently of this handler.
    private func handleSongTap(
        _ song: Song,
        fromQueue queue: [Song],
        completion: @escaping () -> Void
    ) {
        guard let engine = container?.audioEngine else {
            completion()
            return
        }
        let baselineError = engine.lastError
        engine.play(song: song, fromQueue: queue)
        // Refresh the wrapper Now Playing tab eagerly so the user sees
        // the new track lit up before the indicator dismisses. The
        // observation re-arming pattern (A2) will keep it in sync after.
        refreshNowPlayingTab()

        Task { @MainActor [weak self] in
            // Poll for resolution / failure with a hard 8s ceiling.
            let deadline = Date().addingTimeInterval(8.0)
            while Date() < deadline {
                if let err = engine.lastError, err != baselineError {
                    self?.presentPlaybackErrorAlert(message: err)
                    completion()
                    return
                }
                if engine.currentTrack?.id == song.id, engine.isPlaying {
                    completion()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            // Safety: timed out. Dismiss the indicator regardless.
            completion()
        }
    }

    /// D-4 — surface a `CPAlertTemplate` when stream resolution fails so the
    /// user gets visible feedback instead of a silent tap. Dismiss action
    /// pops the alert; auto-skip in `AudioEngine` is unaffected.
    private func presentPlaybackErrorAlert(message: String) {
        guard let controller = interfaceController else { return }
        // Avoid stacking duplicate alerts on rapid repeated failures.
        if controller.presentedTemplate is CPAlertTemplate {
            controller.dismissTemplate(animated: false, completion: nil)
        }
        let dismiss = CPAlertAction(
            title: String(localized: "Dismiss"),
            style: .cancel,
            handler: { _ in }
        )
        let alert = CPAlertTemplate(
            titleVariants: [
                String(localized: "Cannot play this song"),
                String(localized: "Playback failed"),
            ],
            actions: [dismiss]
        )
        controller.presentTemplate(alert, animated: true, completion: nil)
        // Brief diagnostic log (visible message is the localized fallback).
        print("🚗 [CarPlay] Playback error alert presented: \(message)")
    }

    private func makeSongItem(_ song: Song, fromQueue queue: [Song]) -> CPListItem {
        let item = CPListItem(
            text: song.title,
            detailText: "\(song.artistName) · \(song.formattedDuration)",
            image: UIImage(systemName: "music.note")
        )
        item.handler = { [weak self] _, completion in
            self?.handleSongTap(song, fromQueue: queue, completion: completion)
        }
        loadThumbnail(for: song, into: item)
        return item
    }

    private func makeListImageItem(
        text: String,
        image: UIImage?,
        handler: @escaping () -> Void
    ) -> CPListItem {
        let item = CPListItem(text: text, detailText: nil, image: image)
        item.handler = { _, completion in
            handler()
            completion()
        }
        return item
    }

    private func makeLoadingItem() -> CPListItem {
        CPListItem(
            text: String(localized: "Loading…"),
            detailText: nil,
            image: UIImage(systemName: "arrow.trianglehead.2.clockwise")
        )
    }

    private func makeEmptyItem() -> CPListItem {
        CPListItem(
            text: String(localized: "No items"),
            detailText: String(localized: "Nothing here yet"),
            image: UIImage(systemName: "tray")
        )
    }

    private func makeErrorItem(_ error: Error) -> CPListItem {
        CPListItem(
            text: String(localized: "Failed to load"),
            detailText: error.localizedDescription,
            image: UIImage(systemName: "exclamationmark.triangle")
        )
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail(for song: Song, into item: CPListItem) {
        guard let urlString = song.thumbnailURL, let url = URL(string: urlString) else { return }
        let request = ImageRequest(
            url: url,
            processors: [.resize(size: thumbnailSize, crop: true)]
        )
        Task {
            guard let image = try? await ImagePipeline.shared.image(for: request) else { return }
            Task { @MainActor in
                item.setImage(image)
            }
        }
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showQueue()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let container else { return }
        // F7 — prefer `currentTrack` over queue index lookup.
        guard let song = container.audioEngine.currentTrack else { return }
        guard let albumId = song.albumId, isValidAlbumBrowseId(albumId) else { return }
        let album = Album(
            id: albumId,
            title: song.albumName ?? "",
            artistName: song.artistName,
            artistId: song.artistId,
            year: nil,
            thumbnailURL: song.thumbnailURL,
            songs: []
        )
        showAlbumDetail(album)
    }
}

// MARK: - CPSearchTemplateDelegate (A5 / F5)

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    /// Live-as-you-type query. CarPlay calls this on each text edit; we
    /// dispatch the query and reply through `completionHandler` with at most
    /// `maximumItemCount` rows (CarPlay enforces this; we cap defensively).
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let useCase = container?.searchMusicUseCase else {
            completionHandler([])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler([])
                return
            }
            do {
                let result = try await useCase.execute(query: trimmed, filter: .songs)
                let songs = Array(result.songs.prefix(CPListTemplate.maximumItemCount))
                // Round 2 — Fix 3: cache results for `selectedResult` routing.
                self.latestSearchSongs = songs
                let items: [CPListItem] = songs.map { song in
                    let item = CPListItem(
                        text: song.title,
                        detailText: "\(song.artistName) · \(song.formattedDuration)",
                        image: UIImage(systemName: "music.note")
                    )
                    // Round 2 — Fix 3: associate the Song with the row so
                    // `selectedResult` can recover it without index lookups.
                    item.userInfo = song
                    item.handler = { [weak self] _, completion in
                        self?.handleSongTap(song, fromQueue: songs, completion: completion)
                    }
                    self.loadThumbnail(for: song, into: item)
                    return item
                }
                completionHandler(items)
            } catch {
                // Surface a single placeholder row so the user sees that
                // the search executed but yielded no usable results.
                let errItem = self.makeErrorItem(error)
                completionHandler([errItem])
            }
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        // Round 2 — Fix 3 (review-codex HIGH #2): funnel the tap through
        // `handleSongTap` so the search tab uses the same play / error /
        // timeout pipeline as every other tab. Previously this method
        // acknowledged the tap with `completionHandler()` and relied on
        // `item.handler` firing — but `CPSearchTemplate` does NOT invoke
        // row handlers; selection routes here instead, so taps were silent.
        guard let song = item.userInfo as? Song else {
            completionHandler()
            return
        }
        // Snapshot the queue so the engine receives the same ordered list
        // the user saw at tap time (avoids races if the user keeps typing).
        let queue = latestSearchSongs.isEmpty ? [song] : latestSearchSongs
        handleSongTap(song, fromQueue: queue, completion: completionHandler)
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        // Live-as-you-type already shows results; explicit Search button
        // is a no-op in our flow.
    }
}
