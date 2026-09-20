import SwiftUI

struct DownloadButton: View {
    let state: DownloadManager.DownloadState
    let onDownload: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button {
            switch state {
            case .notDownloaded, .failed:
                onDownload()
            case .downloaded:
                onRemove()
            case .downloading, .queued:
                break
            }
        } label: {
            ZStack {
                switch state {
                case .notDownloaded:
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Theme.Colors.textTertiary)

                case .queued:
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Theme.Colors.textTertiary)

                case .downloading(let progress):
                    ZStack {
                        Circle()
                            .stroke(Theme.Colors.textTertiary.opacity(0.3), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Theme.Colors.brandGradientStart, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Colors.brandGradientStart)
                    }
                    .animation(Theme.AnimationPresets.smooth, value: progress)

                case .downloaded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.success)

                case .failed:
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Theme.Colors.error)
                }
            }
            .font(.body)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .disabled(state.isDownloading)
    }
}

extension DownloadManager.DownloadState {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        if case .queued = self { return true }
        return false
    }
}
