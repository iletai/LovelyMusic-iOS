import SwiftUI

/// Fully custom full-screen video player UI.
///
/// Replaces SwiftUI's `VideoPlayer` (which renders AVKit's default system
/// controls) with a bespoke control overlay so the experience matches the rest
/// of the app. The underlying frames are drawn by ``VideoSurfaceView`` (an
/// `AVPlayerLayer` with no chrome).
///
/// All playback mutations route through ``PlayerViewModel`` so the shared
/// `AVPlayer` driven by `AudioEngine` keeps audio and video in sync.
///
/// Performance: this view's body deliberately does **not** read
/// `PlaybackProgress` (which ticks ~2×/sec). The scrubber and time labels live
/// in ``FullScreenVideoProgressBar`` so only that small subtree re-renders on
/// each tick — the video surface and the rest of the chrome stay static.
struct FullScreenVideoPlayerView: View {
    @Environment(PlayerViewModel.self) private var playerVM

    /// Called when the user dismisses the full-screen viewer.
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var aspectFill = false

    private let autoHideDelay: Duration = .seconds(3.5)
    private let skipInterval: TimeInterval = 10

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playerVM.videoPlayer {
                VideoSurfaceView(
                    player: player,
                    videoGravity: aspectFill ? .resizeAspectFill : .resizeAspect
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.25), value: aspectFill)
            }

            // Transparent tap target — sits *below* the controls overlay so
            // button/slider gestures always win hit-testing.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .onAppear { scheduleAutoHide() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: playerVM.isPlaying) { _, _ in
            // Pausing should reveal controls and keep them up; playing arms the
            // auto-hide timer again.
            resetAutoHide()
        }
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .top)
                )

            Spacer()

            centerControls

            Spacer()

            bottomBar
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.md)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
        }
    }

    // MARK: Top Bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            controlButton(systemName: "chevron.down", size: 18) {
                hideTask?.cancel()
                onClose()
            }
            .accessibilityLabel("Exit full screen")

            VStack(alignment: .leading, spacing: 2) {
                Text(playerVM.currentSong?.title ?? "")
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = playerVM.currentSong?.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controlButton(
                systemName: aspectFill
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                size: 16
            ) {
                withAnimation(.easeInOut(duration: 0.25)) { aspectFill.toggle() }
                resetAutoHide()
            }
            .accessibilityLabel(aspectFill ? "Fit video to screen" : "Fill screen with video")
        }
    }

    // MARK: Center Controls

    private var centerControls: some View {
        HStack(spacing: Theme.Spacing.xxl) {
            controlButton(systemName: "gobackward.10", size: 26) {
                seekRelative(-skipInterval)
            }
            .accessibilityLabel("Skip back 10 seconds")

            Button {
                playerVM.playPause()
                resetAutoHide()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(playerVM.isPlaying ? "Pause" : "Play")

            controlButton(systemName: "goforward.10", size: 26) {
                seekRelative(skipInterval)
            }
            .accessibilityLabel("Skip forward 10 seconds")
        }
    }

    // MARK: Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            // Isolated so progress ticks don't re-render the whole overlay.
            FullScreenVideoProgressBar(onInteraction: { resetAutoHide() })

            HStack(spacing: Theme.Spacing.xxl) {
                controlButton(systemName: "backward.fill", size: 22) {
                    playerVM.previous()
                    resetAutoHide()
                }
                .accessibilityLabel("Previous track")

                controlButton(systemName: "forward.fill", size: 22) {
                    playerVM.next()
                    resetAutoHide()
                }
                .accessibilityLabel("Next track")
            }
            .padding(.top, Theme.Spacing.xs)
        }
    }

    // MARK: - Helpers

    private func controlButton(
        systemName: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func seekRelative(_ delta: TimeInterval) {
        // Read inside an action closure — does not register a body dependency.
        let target = min(max(playerVM.currentTime + delta, 0), playerVM.duration)
        playerVM.seek(to: target)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        resetAutoHide()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible {
            scheduleAutoHide()
        } else {
            hideTask?.cancel()
        }
    }

    private func resetAutoHide() {
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: autoHideDelay)
            } catch {
                return  // Cancelled — keep controls as-is.
            }
            guard !Task.isCancelled, playerVM.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

// MARK: - Isolated Progress Bar

/// Observes ``PlaybackProgress`` in isolation so only the scrubber and time
/// labels re-render on each ~2×/sec tick — not the whole video overlay. Mirrors
/// the seek/`isSeeking` handshake used by `PlayerProgressSection` so video and
/// audio stay in sync while scrubbing.
private struct FullScreenVideoProgressBar: View {
    @Environment(PlaybackProgress.self) private var playbackProgress
    @Environment(PlayerViewModel.self) private var playerVM

    /// Invoked on any scrub/seek interaction so the parent can reset auto-hide.
    let onInteraction: () -> Void

    @State private var sliderValue: Double = 0
    @State private var isSeeking = false

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ProgressSlider(
                value: Binding(
                    get: { isSeeking ? sliderValue : playbackProgress.progress },
                    set: { newValue in
                        sliderValue = newValue
                        isSeeking = true
                    }
                ),
                accentColor: .white,
                onEditingChanged: { editing in
                    if editing {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } else {
                        playerVM.seekToProgress(sliderValue)
                    }
                    onInteraction()
                },
                currentTimeLabel: formatTime(playbackProgress.currentTime),
                totalTimeLabel: formatTime(playbackProgress.duration),
                duration: playbackProgress.duration
            )

            HStack {
                Text(formatTime(playbackProgress.currentTime))
                    .contentTransition(.numericText())
                Spacer()
                Text(formatTime(playbackProgress.duration))
            }
            .font(Theme.Typography.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .onChange(of: playbackProgress.progress) { _, newProgress in
            if isSeeking, abs(newProgress - sliderValue) < 0.005 {
                isSeeking = false
            }
        }
        .onChange(of: playerVM.currentSong?.id) {
            isSeeking = false
            sliderValue = 0
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
