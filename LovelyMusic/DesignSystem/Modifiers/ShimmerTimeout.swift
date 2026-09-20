import SwiftUI

/// Caps a shimmer/loading placeholder to a maximum duration. After the
/// timeout elapses, the modifier swaps the shimmer for a neutral fallback
/// (typically a music-note icon) so the user stops seeing indefinite
/// shimmer that reads as "the app is broken".
///
/// Designed to wrap `ShimmerView` or any placeholder inside
/// `AsyncThumbnail` / `LazyImage`'s loading state branch. It is additive:
/// the caller still controls when the shimmer is shown (usually while the
/// image is `nil`), this modifier only decides "shimmer vs fallback icon"
/// while the parent still considers the content to be loading.
struct ShimmerTimeoutModifier<Fallback: View>: ViewModifier {
    let seconds: Double
    let fallback: () -> Fallback

    @State private var timedOut = false

    func body(content: Content) -> some View {
        Group {
            if timedOut {
                fallback()
                    .transition(.opacity)
            } else {
                content
                    .transition(.opacity)
            }
        }
        .task {
            // `.task` is cancelled if the view disappears, so the timer
            // resets automatically when the loading state ends (e.g. image
            // arrived and the branch is torn down).
            timedOut = false
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    timedOut = true
                }
            }
        }
    }
}

extension View {
    /// Shows the receiver (usually a shimmer) for at most `seconds`, then
    /// swaps to the supplied fallback. Typical use:
    ///
    /// ```swift
    /// ShimmerView()
    ///     .shimmerTimeout(seconds: 3) {
    ///         Image(systemName: "music.note")
    ///             .foregroundStyle(Theme.Colors.textTertiary)
    ///     }
    /// ```
    func shimmerTimeout<Fallback: View>(
        seconds: Double = 3,
        @ViewBuilder fallback: @escaping () -> Fallback
    ) -> some View {
        modifier(ShimmerTimeoutModifier(seconds: seconds, fallback: fallback))
    }
}
