import SwiftUI

struct QueueView: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode
    @State private var songForPlaylist: Song?

    private var fittedHeight: CGFloat {
        let rowHeight: CGFloat = 64
        let nowPlaying: CGFloat = playerVM.currentSong != nil ? 90 : 0
        let upNextHeader: CGFloat = !upNextSongs.isEmpty ? 32 : 0
        let autoplayHeader: CGFloat = !autoplaySongs.isEmpty ? 32 : 0
        let visibleUpNext = CGFloat(min(upNextSongs.count, 6))
        let visibleAutoplay = CGFloat(min(autoplaySongs.count, 3))
        let chrome: CGFloat = 96
        return chrome + nowPlaying + upNextHeader + visibleUpNext * rowHeight
            + autoplayHeader + visibleAutoplay * rowHeight
    }

    var body: some View {
        // MARK: SafeArea — presented inside FullPlayerView (modal); dock not visible. Bottom controls live above this list inside FullPlayerView.
        NavigationStack {
            ScrollViewReader { proxy in
                if playerVM.currentSong == nil && upNextSongs.isEmpty {
                    EmptyStateView(
                        icon: "list.bullet",
                        title: "Queue is Empty",
                        message: "Play a song or add songs to the queue to see them here"
                    )
                } else {
                List {
                    if let currentSong = playerVM.currentSong {
                        Section {
                            SongRowView(
                                song: currentSong,
                                isPlaying: true,
                                onTap: {}
                            )
                            .listRowBackground(Theme.Colors.surfaceSelected)
                        } header: {
                            Text("Now Playing")
                        }
                    }

                    if !upNextSongs.isEmpty {
                        Section {
                            ForEach(Array(upNextSongs.enumerated()), id: \.element.id) { offset, song in
                                upNextRow(song: song, offset: offset)
                            }
                            .onMove { source, destination in
                                let base = playerVM.currentIndex + 1
                                playerVM.moveInQueue(
                                    from: IndexSet(source.map { $0 + base }),
                                    to: destination + base
                                )
                            }
                        } header: {
                            Text("Up Next")
                        }
                    }

                    // Autoplay section — system-suggested songs with dimmed styling
                    if !autoplaySongs.isEmpty {
                        Section {
                            ForEach(Array(autoplaySongs.enumerated()), id: \.element.id) { offset, song in
                                autoplayRow(song: song, offset: offset)
                            }
                        } header: {
                            autoplayHeader
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.Colors.backgroundPrimary)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation {
                            editMode?.wrappedValue = editMode?.wrappedValue == .active
                                ? .inactive : .active
                        }
                    } label: {
                        Text(
                            editMode?.wrappedValue == .active
                                ? String(localized: "Done")
                                : String(localized: "Edit")
                        )
                        .fontWeight(.semibold)
                    }
                    .foregroundStyle(Theme.Colors.brandGradientStart)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CustomCloseButton()
                }
            }
            .sheet(item: $songForPlaylist) { song in
                AddToPlaylistSheet(
                    song: song,
                    managePlaylistUseCase: container.managePlaylistUseCase
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.backgroundPrimary)
            }
        }
        .presentationDetents([.height(fittedHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Colors.backgroundPrimary)
    }

    private var upNextSongs: [Song] {
        let queue = playerVM.queue
        let idx = playerVM.currentIndex
        guard idx + 1 < queue.count else { return [] }
        return ContentPreferences.filteredSongs(Array(queue[(idx + 1)...]))
    }

    private var autoplaySongs: [Song] {
        guard playerVM.isAutoplayEnabled else { return [] }
        return ContentPreferences.filteredSongs(playerVM.autoplayQueue)
    }

    @ViewBuilder
    private var autoplayHeader: some View {
        HStack {
            Label("Autoplay", systemImage: "sparkles")
            Spacer()
            Button { playerVM.toggleAutoplay() } label: {
                Image(systemName: playerVM.isAutoplayEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Theme.Colors.brandGradientStart)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func autoplayRow(song: Song, offset: Int) -> some View {
        SongRowView(song: song, isPlaying: false, onTap: {
            playerVM.playFromAutoplayQueue(at: offset)
            dismiss()
        })
        .opacity(0.7)
        .contextMenu {
            Button { playerVM.moveToTop(song: song) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { playerVM.addToQueue(song) } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button { songForPlaylist = song } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { playerVM.addToQueue(song) } label: {
                Label("Add to Queue", systemImage: "plus")
            }
            .tint(Theme.Colors.brandGradientStart)
        }
        .listRowBackground(Theme.Colors.backgroundSecondary)
        .staggeredAppear(index: offset)
    }

    @ViewBuilder
    private func upNextRow(song: Song, offset: Int) -> some View {
        let idx = playerVM.currentIndex + 1 + offset
        HStack(spacing: Theme.Spacing.sm) {
            Text("\(offset + 1)")
                .font(Theme.Typography.caption2)
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 20, alignment: .trailing)
                .monospacedDigit()
            SongRowView(song: song, isPlaying: false, onTap: {
                playerVM.playFromQueue(at: idx)
                dismiss()
            })
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Theme.Colors.textTertiary)
                .font(Theme.Typography.subheadline)
                .accessibilityLabel("Reorder")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.title) by \(song.artistName)")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { playerVM.removeFromQueue(at: idx) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { playerVM.moveToTop(song: song) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button(role: .destructive) { playerVM.removeFromQueue(at: idx) } label: {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button { songForPlaylist = song } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
        .listRowBackground(Theme.Colors.backgroundSecondary)
        .staggeredAppear(index: offset)
    }
}
