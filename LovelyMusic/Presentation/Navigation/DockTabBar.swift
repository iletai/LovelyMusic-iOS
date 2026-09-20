import SwiftUI

struct DockTabBar: View {
    @Binding var selectedTab: AppTab
    var onReselect: ((AppTab) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = selectedTab == tab

                Button {
                    if isSelected {
                        onReselect?(tab)
                    } else {
                        withAnimation(
                            reduceMotion
                                ? Theme.AnimationPresets.crossfade
                                : Theme.AnimationPresets.smooth
                        ) {
                            selectedTab = tab
                        }
                    }
                } label: {
                    ZStack {
                        VStack(spacing: 3) {
                            // Pulse Line keeps one silhouette per destination. The
                            // gradient and dot communicate selection without swapping
                            // the icon's meaning or relying on color alone.
                            PulseIcon(
                                tab.pulseIcon,
                                size: Theme.SizeTokens.iconMedium,
                                color: Theme.Colors.textSecondary,
                                usesBrandGradient: isSelected
                            )

                            // Dot indicator
                            Circle()
                                .fill(Theme.Colors.brandGradient)
                                .frame(width: 4, height: 4)
                                .scaleEffect(
                                    reduceMotion ? 1 : (isSelected ? 1 : 0.01)
                                )
                                .opacity(isSelected ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab_\(tab.rawValue)")
                .accessibilityLabel("\(tab.label) tab")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
    }
}
