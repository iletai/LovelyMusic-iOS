import AVKit
import SwiftUI
import os

struct FullPlayerView: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PremiumManager.self) private var premiumManager
    @Environment(SleepTimerManager.self) private var sleepTimerManager
    @Environment(DIContainer.self) private var container
    @Environment(FeatureFlagManager.self) private var featureFlags
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var showAddToPlaylist = false
    @State private var showPaywall = false
    @State private var showYouTubeLogin = false
    @State private var showYouTubeLoginAlert = false
    @State private var isVideoFullScreen = false
    /// Snapshot of currentTime at last interaction — used in share menu
    /// to avoid re-evaluating the Menu body every ~0.5s as currentTime ticks.
    @State private var shareTimestamp: Int = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        playerContent
            .environment(\.colorScheme, .dark)
            .fullScreenCover(isPresented: $isVideoFullScreen) {
                videoFullScreenView
                    .onAppear {
                        // Force-rotate to landscape immediately; user can
                        // switch between landscapeLeft/Right freely while in
                        // fullscreen. Portrait is restored on dismiss.
                        OrientationLock.shared.enterFullscreen()
                    }
            }
            .onChange(of: isVideoFullScreen) { _, presented in
                if !presented {
                    OrientationLock.shared.set(.portrait)
                }
            }
            .onChange(of: playerVM.videoPlayer == nil) { _, isNil in
                // Defensive: if the underlying AVPlayer is torn down while
                // fullscreen is presented (e.g., user toggled off video
                // mode, or track switched to a non-video song), force-dismiss
                // the cover so the user isn't stranded with no controls.
                if isNil, isVideoFullScreen {
                    isVideoFullScreen = false
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                playerVM.updateTransferConsentPresentation(
                    applicationIsActive: newPhase == .active,
                    phoneUIAvailable: true
                )
                // Only pause/resume the video layer here. Seek-sync is
                // handled centrally inside AudioEngine, so don't double-call
                // it from the view (it would cause a visible jump-back when
                // the app returns from background).
                if newPhase == .background, playerVM.isVideoMode {
                    playerVM.videoPlayer?.pause()
                } else if newPhase == .active, playerVM.isVideoMode, playerVM.isPlaying {
                    playerVM.videoPlayer?.play()
                }
            }
            .onAppear {
                playerVM.updateTransferConsentPresentation(
                    applicationIsActive: scenePhase == .active,
                    phoneUIAvailable: true
                )
            }
            .onDisappear {
                playerVM.updateTransferConsentPresentation(
                    applicationIsActive: scenePhase == .active,
                    phoneUIAvailable: false
                )
            }
            .alert("Prepare this song for playback?", isPresented: transferConsentIsPresented) {
                Button("Not Now", role: .cancel) {
                    playerVM.respondToTransferConsent(.decline)
                }
                Button("Continue") {
                    playerVM.respondToTransferConsent(.accept)
                }
            } message: {
                if let consent = playerVM.transferConsentViewState {
                    Text(transferConsentMessage(consent))
                }
            }
            .overlay(alignment: .top) {
                if playerVM.showSkipLimitNudge {
                    skipLimitNudgeBanner
                }
            }
            .onChange(of: playerVM.showSkipLimitNudge) { _, shown in
                guard shown else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    playerVM.showSkipLimitNudge = false
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: playerVM.isPlaying)
            .sensoryFeedback(.selection, trigger: playerVM.currentSong?.id)
            .sensoryFeedback(.impact(weight: .light), trigger: playerVM.shuffleEnabled)
            .sensoryFeedback(.impact(weight: .light), trigger: playerVM.repeatMode)
    }

    private var skipLimitNudgeBanner: some View {
        VStack(spacing: Theme.Spacing.xxxs) {
            Text("You've reached your free skip limit")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Upgrade for unlimited skips")
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(Theme.Colors.brandGradientStart)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
        .padding(.top, Theme.Spacing.xxxl)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var playerContent: some View {
        GeometryReader { geo in
            ZStack {
                // Dynamic gradient background
                if let thumbnail = playerVM.currentSong?.thumbnailURL {
                    AsyncImage(url: URL(string: thumbnail)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 30)
                            .overlay(Theme.Colors.overlayHeavy)
                    } placeholder: {
                        ShimmerView(cornerRadius: 0)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .overlay(Theme.Colors.overlayHeavy)
                    }
                    .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [
                            Theme.Colors.playerGradientTop, Theme.Colors.playerGradientBottom,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }

                VStack(spacing: Theme.Spacing.xl) {
                    // Drag handle + top controls
                    VStack(spacing: Theme.Spacing.md) {
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 40, height: 5)
                            .padding(.top, Theme.Spacing.sm)

                        HStack {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Close player")
                            .accessibilityHint("Double tap to minimize to mini player")
                            Spacer()
                            Menu {
                                if let song = playerVM.currentSong {
                                    // Share with current timestamp deep link
                                    if song.hasYouTubeOrigin {
                                        if let shareURL = song.youtubeURL(atSecond: shareTimestamp)
                                        {
                                            ShareLink(
                                                item: shareURL,
                                                subject: Text(song.title),
                                                message: Text(
                                                    "🎵 \(song.title) - \(song.artistName) at \(Song.formatTimestamp(shareTimestamp))"
                                                )
                                            ) {
                                                Label(
                                                    "Share at \(Song.formatTimestamp(shareTimestamp))",
                                                    systemImage: "square.and.arrow.up")
                                            }
                                        }
                                        if let url = song.youtubeURL {
                                            ShareLink(
                                                item: url,
                                                subject: Text(song.title),
                                                message: Text(
                                                    "🎵 \(song.title) - \(song.artistName)")
                                            ) {
                                                Label("Share from Start", systemImage: "link")
                                            }
                                        }
                                    } else {
                                        // Local-only song — share text only
                                        ShareLink(item: "🎵 \(song.title) - \(song.artistName)") {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    if featureFlags.isDownloadEnabled {
                                        Button {
                                            if container.downloadManager.isDownloaded(
                                                songId: song.id)
                                            {
                                                container.downloadManager.removeDownload(
                                                    songId: song.id)
                                            } else if premiumManager.canDownload(
                                                currentCount: container.downloadManager
                                                    .downloadCount)
                                            {
                                                container.downloadManager.downloadSong(song)
                                            } else {
                                                showPaywall = true
                                            }
                                        } label: {
                                            if container.downloadManager.isDownloaded(
                                                songId: song.id)
                                            {
                                                Label("Remove Download", systemImage: "trash")
                                            } else if !premiumManager.canDownload(
                                                currentCount: container.downloadManager
                                                    .downloadCount)
                                            {
                                                Label(
                                                    "Download (Limit Reached)",
                                                    systemImage: "lock.fill")
                                            } else {
                                                Label(
                                                    downloadMenuLabel,
                                                    systemImage: "arrow.down.circle")
                                            }
                                        }
                                    }
                                }
                                Button("Add to Playlist", systemImage: "plus") {
                                    showAddToPlaylist = true
                                }
                                Button("View Artist", systemImage: "person") {
                                    if let artistId = playerVM.currentSong?.artistId {
                                        dismiss()
                                        Task {
                                            try? await Task.sleep(for: .milliseconds(500))
                                            NotificationCenter.default.post(
                                                name: .navigateToArtist,
                                                object: nil,
                                                userInfo: ["browseId": artistId]
                                            )
                                        }
                                    }
                                }
                                .disabled(playerVM.currentSong?.artistId == nil)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.title3)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("More options")
                            // Snapshot timestamp when the menu button area first appears
                            // and whenever the song changes. This avoids reading playerVM.currentTime
                            // inside the Menu closure (which would re-evaluate every ~0.5s).
                            .onAppear { shareTimestamp = Int(playerVM.currentTime) }
                            .onChange(of: playerVM.currentSong?.id) {
                                shareTimestamp = Int(playerVM.currentTime)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                    }
                    .padding(.top, Theme.Spacing.md)

                    // Content slot: lyrics / video / vinyl disc share the same flexible space
                    Group {
                        if playerVM.isLyricsVisible {
                            inlineLyricsView(geo: geo)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else if featureFlags.isVideoPlaybackEnabled, playerVM.isVideoMode,
                            let vp = playerVM.videoPlayer, !isVideoFullScreen
                        {
                            VStack {
                                Spacer()
                                VideoSurfaceView(player: vp)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: Theme.CornerRadius.large,
                                            style: .continuous)
                                    )
                                    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                                    .padding(.horizontal, Theme.Spacing.lg)
                                    .allowsHitTesting(false)
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.3)) {
                                                isVideoFullScreen = true
                                            }
                                        } label: {
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(Theme.Spacing.sm)
                                                .background(.ultraThinMaterial, in: Circle())
                                        }
                                        .padding(Theme.Spacing.sm)
                                        .accessibilityLabel("Expand video to full screen")
                                    }
                                Spacer()
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else if featureFlags.isVideoPlaybackEnabled, playerVM.isVideoMode,
                            playerVM.videoLoadState == .unavailable
                                || playerVM.videoLoadState != .loading
                                    && playerVM.videoPlayer == nil
                        {
                            VStack(spacing: Theme.Spacing.lg) {
                                Spacer()
                                Image(systemName: "video.slash.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                Text("Video unavailable")
                                    .font(Theme.Typography.headline)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                                Text("This track doesn't have a video stream")
                                    .font(Theme.Typography.subheadline)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                Button {
                                    playerVM.toggleVideoMode()
                                } label: {
                                    Text("Switch to Audio")
                                        .font(Theme.Typography.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, Theme.Spacing.xl)
                                        .padding(.vertical, Theme.Spacing.md)
                                        .background(Theme.Colors.brandGradient, in: Capsule())
                                }
                                Spacer()
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else {
                            VStack {
                                Spacer()

                                VinylDiscView(
                                    thumbnailURL: playerVM.currentSong?.thumbnailURL,
                                    size: geo.size.width * 0.85,
                                    isPlaying: playerVM.isPlaying,
                                    dominantColor: playerVM.dominantColor
                                )

                                Spacer()
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .animation(Theme.AnimationPresets.smooth, value: playerVM.isLyricsVisible)
                    .animation(Theme.AnimationPresets.smooth, value: playerVM.isVideoMode)

                    // Song info
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(playerVM.currentSong?.title ?? String(localized: "Not Playing"))
                                .font(Theme.Typography.title2)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .lineLimit(1)
                                .contentTransition(.interpolate)
                            Text(playerVM.currentSong?.artistName ?? "")
                                .font(Theme.Typography.subheadline)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .lineLimit(1)
                                .contentTransition(.interpolate)
                        }
                        Spacer()
                        if let song = playerVM.currentSong {
                            FavoriteButton(isFavorite: playerVM.isCurrentSongFavorite) {
                                Task { await playerVM.toggleFavorite(song: song) }
                            }
                        }
                        if sleepTimerManager.isActive {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.fill")
                                    .font(.caption2)
                                if sleepTimerManager.selectedOption != .endOfTrack {
                                    Text(sleepTimerManager.formattedRemaining)
                                        .font(.caption2)
                                        .monospacedDigit()
                                }
                            }
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: playerVM.currentSong?.id)
                    .animation(Theme.AnimationPresets.gentle, value: sleepTimerManager.isActive)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        playerVM.currentSong.map { "\($0.title) by \($0.artistName)" }
                            ?? "Not Playing")

                    // Progress slider + time labels (isolated sub-view to avoid 2x/sec re-renders)
                    PlayerProgressSection()

                    // Transport controls
                    PlayerControlsView(
                        isPlaying: playerVM.isPlaying,
                        isBuffering: playerVM.isBuffering,
                        bufferingTooLong: playerVM.bufferingTooLong,
                        shuffleEnabled: playerVM.shuffleEnabled,
                        repeatMode: playerVM.repeatMode,
                        dominantColor: playerVM.dominantColor,
                        isFreeUser: playerVM.isFreeUser,
                        remainingSkips: playerVM.remainingSkips,
                        currentSongId: playerVM.currentSong?.id,
                        onShuffle: { playerVM.toggleShuffle() },
                        onPrevious: { playerVM.previous() },
                        onPlayPause: { playerVM.playPause() },
                        onNext: { playerVM.next() },
                        onCycleRepeat: { playerVM.cycleRepeatMode() },
                        onRetry: { playerVM.retryCurrentSong() }
                    )

                    // Bottom action bar
                    PlayerBottomBarView(
                        playbackSpeedLabel: playerVM.playbackSpeedLabel,
                        playbackSpeed: playerVM.playbackSpeed,
                        isAutoplayEnabled: playerVM.isAutoplayEnabled,
                        isVideoMode: playerVM.isVideoMode,
                        isLyricsVisible: playerVM.isLyricsVisible,
                        canAccessFullLyrics: playerVM.canAccessFullLyrics,
                        isVideoPlaybackEnabled: featureFlags.isVideoPlaybackEnabled,
                        dominantColor: playerVM.dominantColor,
                        onCycleSpeed: { playerVM.cyclePlaybackSpeed() },
                        onToggleAutoplay: { playerVM.toggleAutoplay() },
                        onToggleVideo: {
                            withAnimation(Theme.AnimationPresets.bouncy) {
                                playerVM.toggleVideoMode()
                            }
                        },
                        onToggleLyrics: {
                            withAnimation(Theme.AnimationPresets.bouncy) {
                                playerVM.isLyricsVisible.toggle()
                            }
                        },
                        onShowQueue: { playerVM.isQueuePresented = true }
                    )
                    .padding(
                        .bottom,
                        max(Theme.Spacing.xl, geo.safeAreaInsets.bottom + Theme.Spacing.md)
                    )
                }

                // Error overlay
                if let error = playerVM.guardedPlaybackError {
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.Colors.error)
                        Text("Playback Paused")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text(playerVM.guardedPlaybackErrorMessage(error))
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                        if error.isRecoverable {
                            Button {
                                playerVM.retryGuardedPlayback()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(Theme.Typography.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, Theme.Spacing.xl)
                                    .padding(.vertical, Theme.Spacing.sm)
                                    .background(Theme.Colors.brandGradient, in: Capsule())
                            }
                            .buttonStyle(.bouncy)
                        }
                    }
                    .padding(Theme.Spacing.xl)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                    )
                    .padding(.horizontal, Theme.Spacing.xl)
                    .transition(.scale.combined(with: .opacity))
                } else if let error = playerVM.streamError {
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: playerVM.streamErrorCategory?.icon ?? "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.Colors.error)
                        Text(playerVM.streamErrorCategory?.title ?? "Playback Error")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text(error)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                        #if DEBUG
                        if let rawError = playerVM.playbackError {
                            Text("DEBUG: \(rawError)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                        #endif
                        if featureFlags.isYouTubeAuthEnabled && !container.authManager.isLoggedIn {
                            Button {
                                showYouTubeLogin = true
                            } label: {
                                Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                                    .font(Theme.Typography.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, Theme.Spacing.xl)
                                    .padding(.vertical, Theme.Spacing.sm)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.red, Color.orange],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.bouncy)
                        }
                        if playerVM.canRetry {
                            Button {
                                playerVM.retryCurrentSong()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(Theme.Typography.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, Theme.Spacing.xl)
                                    .padding(.vertical, Theme.Spacing.sm)
                                    .background(Theme.Colors.brandGradient, in: Capsule())
                            }
                            .buttonStyle(.bouncy)
                        }
                    }
                    .padding(Theme.Spacing.xl)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                    )
                    .padding(.horizontal, Theme.Spacing.xl)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { value in
                    // Only dismiss when vertical movement clearly dominates horizontal
                    // This prevents conflict with the horizontal ProgressSlider gesture
                    if value.translation.height > 0,
                        abs(value.translation.height) > abs(value.translation.width) * 1.5
                    {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 150 {
                        dismiss()
                    }
                    dragOffset = 0
                }
        )
        .offset(y: dragOffset)
        .transaction { transaction in
            transaction.animation = dragOffset != 0 ? .interactiveSpring() : nil
        }
        .sheet(
            isPresented: Binding(
                get: { playerVM.isQueuePresented },
                set: { playerVM.isQueuePresented = $0 }
            )
        ) {
            QueueView()
                .environment(playerVM)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = playerVM.currentSong {
                AddToPlaylistSheet(
                    song: song,
                    managePlaylistUseCase: container.managePlaylistUseCase
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.backgroundPrimary)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { playerVM.showSkipLimitPaywall },
                set: { playerVM.showSkipLimitPaywall = $0 }
            )
        ) {
            PaywallView()
                .environment(premiumManager)
        }
        .sheet(
            isPresented: Binding(
                get: { playerVM.showLyricsPaywall },
                set: { playerVM.showLyricsPaywall = $0 }
            )
        ) {
            PaywallView()
                .environment(premiumManager)
        }
        .sheet(isPresented: $showYouTubeLogin) {
            YouTubeLoginView(authManager: container.authManager) {
                NotificationCenter.default.post(name: .settingsChanged, object: nil)
                playerVM.retryCurrentSong()
            }
        }
        .onChange(of: playerVM.showYouTubeLoginPrompt) { _, shouldPrompt in
            if shouldPrompt && featureFlags.isYouTubeAuthEnabled && !container.authManager.isLoggedIn {
                showYouTubeLoginAlert = true
                playerVM.showYouTubeLoginPrompt = false
            }
        }
        .alert("Sign in required", isPresented: $showYouTubeLoginAlert) {
            Button("Sign in") {
                showYouTubeLogin = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This content requires signing in with a YouTube account. Would you like to sign in now?")
        }
    }

    private var transferConsentIsPresented: Binding<Bool> {
        Binding(
            get: { playerVM.transferConsentViewState != nil },
            set: { isPresented in
                if !isPresented, playerVM.transferConsentViewState != nil {
                    playerVM.respondToTransferConsent(.dismissed)
                }
            }
        )
    }

    private func transferConsentMessage(_ consent: TransferConsentViewState) -> String {
        let network = TransferEstimateFormatter.upperBoundString(
            bytes: consent.networkUpperBoundBytes
        )
        let storage = TransferEstimateFormatter.upperBoundString(
            bytes: consent.temporaryStorageUpperBoundBytes
        )
        let target = Song.formatTimestamp(Int(consent.targetSeconds.rounded(.down)))
        return "This may use \(network) of network data and \(storage) of temporary storage. Playback will resume near \(target)."
    }

    @ViewBuilder
    private func inlineLyricsView(geo: GeometryProxy) -> some View {
        if playerVM.canAccessFullLyrics {
            if let lyrics = playerVM.lyrics {
                SyncedLyricsScrollView(
                    lyrics: lyrics
                )
            } else if playerVM.isLoadingLyrics {
                VStack {
                    Spacer()
                    ProgressView()
                        .tint(Theme.Colors.textSecondary)
                    Spacer()
                }
            } else {
                VStack {
                    Spacer()
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text("No lyrics available")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    Spacer()
                }
            }
        } else {
            VStack {
                Spacer()
                VStack(spacing: Theme.Spacing.lg) {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.Colors.textTertiary.opacity(0.3))
                                .frame(height: 16)
                                .frame(maxWidth: CGFloat([200, 260, 180][i]))
                                .blur(radius: 4)
                        }
                    }

                    VStack(spacing: Theme.Spacing.sm) {
                        // Q2: gold scoped to paywall only — lock + CTA use brand purple here.
                        Image(systemName: "lock.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.Colors.brandGradientStart)

                        Text("Synced Lyrics")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.textPrimary)

                        Text("Unlock premium to follow along")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)

                        Button {
                            playerVM.showLyricsPaywall = true
                        } label: {
                            Text("Upgrade")
                                .font(Theme.Typography.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.Colors.onBrand)
                                .padding(.horizontal, Theme.Spacing.xl)
                                .padding(.vertical, Theme.Spacing.sm)
                                .background(
                                    Theme.Colors.brandGradient,
                                    in: Capsule()
                                )
                        }
                        .padding(.top, Theme.Spacing.xs)
                    }
                }
                Spacer()
            }
        }
    }

    private var downloadMenuLabel: String {
        if premiumManager.isPremium {
            return String(localized: "Download")
        }
        let remaining = premiumManager.freeDownloadLimit - container.downloadManager.downloadCount
        return String(localized: "Download (\(remaining)/\(premiumManager.freeDownloadLimit) left)")
    }

    // MARK: - Full Screen Video

    @ViewBuilder
    private var videoFullScreenView: some View {
        if playerVM.videoPlayer != nil {
            FullScreenVideoPlayerView(onClose: { isVideoFullScreen = false })
        }
    }
}

// MARK: - Isolated Sub-Views (prevent 2x/sec body re-evaluation)

/// Observes PlaybackProgress in isolation so only the slider and time labels
/// re-render when currentTime ticks — not the entire FullPlayerView tree.
private struct PlayerProgressSection: View {
    @Environment(PlaybackProgress.self) private var playbackProgress
    @Environment(PlayerViewModel.self) private var playerVM
    @State private var sliderValue: Double = 0
    @State private var isSeeking = false
    @State private var showRemainingTime = false

    var body: some View {
        VStack(spacing: 0) {
            ProgressSlider(
                value: Binding(
                    get: { isSeeking ? sliderValue : playbackProgress.progress },
                    set: { newValue in
                        sliderValue = newValue
                        isSeeking = true
                    }
                ),
                accentColor: playerVM.dominantColor,
                onEditingChanged: { editing in
                    if editing {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    if !editing {
                        playerVM.seekToProgress(sliderValue)
                    }
                },
                duration: playbackProgress.duration
            )
            .padding(.horizontal, Theme.Spacing.xl)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Progress: \(formatTime(playbackProgress.currentTime)) of \(formatTime(playbackProgress.duration))"
            )
            .accessibilityValue("\(Int(playbackProgress.progress * 100)) percent")

            HStack {
                Text(formatTime(playbackProgress.currentTime))
                    .font(Theme.Typography.caption2)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .contentTransition(.numericText())
                Spacer()
                Text(trailingTimeLabel)
                    .font(Theme.Typography.caption2)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .contentTransition(.numericText())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showRemainingTime.toggle()
                        }
                    }
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
        .onChange(of: playbackProgress.progress) { _, newProgress in
            // Release isSeeking once playback has caught up to the requested seek.
            if isSeeking, abs(newProgress - sliderValue) < 0.005 {
                isSeeking = false
            }
        }
        .onChange(of: playerVM.currentSong?.id) {
            isSeeking = false
            sliderValue = 0
        }
    }

    private var trailingTimeLabel: String {
        if showRemainingTime {
            let remaining = playbackProgress.duration - playbackProgress.currentTime
            return "-" + formatTime(max(0, remaining))
        }
        return formatTime(playbackProgress.duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
