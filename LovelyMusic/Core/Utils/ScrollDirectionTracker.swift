import SwiftUI

/// Tracks vertical scroll direction globally for dock auto-hide.
///
/// UX behavior (matches Safari/Instagram):
/// - Scroll DOWN → dock hides
/// - Scroll UP → dock shows immediately
/// - Scroll stops → dock shows after a short delay
/// - At top of content → dock always visible
/// - Tab switch / navigation push → dock shows immediately
///
/// Usage: `.dockHidingOnScroll()` on any ScrollView.
@MainActor
@Observable
final class ScrollDirectionTracker {
    /// true when user is scrolling down → dock should hide
    private(set) var isScrollingDown = false

    /// Minimum accumulated scroll delta before toggling (prevents jitter)
    private let hideThreshold: CGFloat = 15
    private let showThreshold: CGFloat = 8

    private var lastOffset: CGFloat = 0
    private var accumulatedDelta: CGFloat = 0
    private var autoShowTask: Task<Void, Never>?

    /// When true, the next `update()` call records the offset as baseline
    /// without triggering any hide/show logic. Prevents a huge delta spike
    /// after tab switch or navigation push (where offset jumps from 0 → current).
    private var needsBaselineUpdate = true

    /// Time after scroll stops before dock auto-shows (seconds)
    private let autoShowDelay: TimeInterval = 1.5

    func update(offset: CGFloat) {
        // After a reset, absorb the first offset as baseline to avoid
        // a massive delta when the scroll view reports its current position.
        if needsBaselineUpdate {
            lastOffset = offset
            needsBaselineUpdate = false
            return
        }

        let delta = offset - lastOffset

        // Ignore tiny movements (noise)
        guard abs(delta) > 0.5 else {
            lastOffset = offset
            return
        }

        // Near top of content or overscrolled (pull-to-refresh) → always show dock
        if offset <= 10 {
            if isScrollingDown {
                showDock()
            }
            lastOffset = offset
            accumulatedDelta = 0
            return
        }

        // Accumulate delta in the same direction, reset on direction change
        if (delta > 0 && accumulatedDelta >= 0) || (delta < 0 && accumulatedDelta <= 0) {
            accumulatedDelta += delta
        } else {
            accumulatedDelta = delta
        }

        // Scrolling DOWN → hide dock
        if accumulatedDelta > hideThreshold && !isScrollingDown {
            hideDock()
        }
        // Scrolling UP → show dock immediately (lower threshold for responsiveness)
        else if accumulatedDelta < -showThreshold && isScrollingDown {
            showDock()
        }

        // Reset auto-show timer on any scroll activity
        scheduleAutoShow()

        lastOffset = offset
    }

    /// Force dock visible (tab switch, navigation push, pull-to-refresh)
    func resetToVisible() {
        autoShowTask?.cancel()
        accumulatedDelta = 0
        // Mark for baseline re-calibration instead of setting lastOffset = 0.
        // This prevents a large delta on the next scroll update.
        needsBaselineUpdate = true
        if isScrollingDown {
            withAnimation(Theme.AnimationPresets.smooth) {
                isScrollingDown = false
            }
        }
    }

    // MARK: - Private

    private func hideDock() {
        autoShowTask?.cancel()
        withAnimation(Theme.AnimationPresets.smooth) {
            isScrollingDown = true
        }
    }

    private func showDock() {
        autoShowTask?.cancel()
        accumulatedDelta = 0
        withAnimation(Theme.AnimationPresets.smooth) {
            isScrollingDown = false
        }
    }

    /// After scroll activity stops, auto-show dock after delay
    private func scheduleAutoShow() {
        autoShowTask?.cancel()
        autoShowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.autoShowDelay ?? 1.5))
            guard let self, !Task.isCancelled, self.isScrollingDown else { return }
            withAnimation(Theme.AnimationPresets.smooth) {
                self.isScrollingDown = false
            }
            self.accumulatedDelta = 0
        }
    }
}

// MARK: - Environment Key for Tab Active State

/// Tells child views whether their tab is currently visible.
/// Set by ContentView per NavigationStack, read by DockHidingScrollModifier.
private struct TabActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isTabActive: Bool {
        get { self[TabActiveKey.self] }
        set { self[TabActiveKey.self] = newValue }
    }
}

// MARK: - ScrollView Modifier (iOS 18+)

/// Attach directly to a ScrollView to track scroll direction for dock auto-hide.
/// Uses native `onScrollGeometryChange` — no coordinate spaces needed.
/// Automatically reads `isTabActive` from Environment to suppress ghost scroll
/// events from inactive tabs (e.g. ZStack-based tab switching with opacity).
struct DockHidingScrollModifier: ViewModifier {
    @Environment(ScrollDirectionTracker.self) private var scrollTracker
    @Environment(\.isTabActive) private var isTabActive

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newOffset in
                guard isTabActive else { return }
                scrollTracker.update(offset: newOffset)
            }
    }
}

extension View {
    /// Track scroll direction for dock auto-hide.
    /// Apply directly to a ScrollView (not its content).
    func dockHidingOnScroll() -> some View {
        modifier(DockHidingScrollModifier())
    }
}
