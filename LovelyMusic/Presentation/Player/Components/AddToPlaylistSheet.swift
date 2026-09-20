import SwiftUI

struct AddToPlaylistSheet: View {
    let song: Song
    let managePlaylistUseCase: ManagePlaylistUseCase
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var addedMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text("No playlists yet")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(playlists) { playlist in
                        Button {
                            Task {
                                try? await managePlaylistUseCase.addSong(song, to: playlist.id)
                                addedMessage = String(localized: "Added to \(playlist.title)")
                                try? await Task.sleep(for: .seconds(0.8))
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                AsyncThumbnail(
                                    url: playlist.thumbnailURL,
                                    size: 44,
                                    cornerRadius: Theme.CornerRadius.small
                                )
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                                    Text(playlist.title)
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Text("\(playlist.songs.count) songs")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Theme.Colors.backgroundSecondary)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CustomCloseButton()
                }
            }
            .overlay {
                if let message = addedMessage {
                    Text(message)
                        .font(Theme.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Theme.Colors.brandGradientStart, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Theme.AnimationPresets.gentle, value: addedMessage)
        }
        .task {
            do {
                playlists = try await managePlaylistUseCase.getAllPlaylists()
            } catch {
                Log.ui.error("Failed to load playlists: \(error, privacy: .public)")
            }
            isLoading = false
        }
    }
}
