import SwiftUI

struct EqualizerView: View {
    @Environment(EqualizerManager.self) private var eqManager
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.dismiss) private var dismiss
    @Namespace private var presetAnimation

    var body: some View {
        @Bindable var eq = eqManager

        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Enable toggle
                enableToggle

                // Presets
                presetsSection
                    .opacity(eqManager.isEnabled ? 1 : 0.4)
                    .allowsHitTesting(eqManager.isEnabled)

                // Band sliders
                bandsSection
                    .opacity(eqManager.isEnabled ? 1 : 0.4)
                    .allowsHitTesting(eqManager.isEnabled)

                // Reset button
                if eqManager.isEnabled {
                    Button {
                        withAnimation(Theme.AnimationPresets.smooth) {
                            eqManager.resetToFlat()
                        }
                    } label: {
                        Label("Reset to Flat", systemImage: "arrow.counterclockwise")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .padding(.bottom, Theme.Spacing.xl)
                }
            }
            .padding(.top, Theme.Spacing.md)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
        }
        .animation(Theme.AnimationPresets.smooth, value: eqManager.isEnabled)
        .onAppear {
            playerVM.isDockHidden = true
        }
        .onDisappear {
            playerVM.isDockHidden = false
        }
    }

    // MARK: - Enable Toggle

    private var enableToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                Text("Equalizer")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Adjust sound to your preference")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            @Bindable var eq = eqManager
            CustomToggle(isOn: $eq.isEnabled)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("PRESETS")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.horizontal, Theme.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(EqualizerPreset.allPresets) { preset in
                        presetCard(preset)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    private func presetCard(_ preset: EqualizerPreset) -> some View {
        let isSelected = eqManager.selectedPreset.id == preset.id

        return Button {
            withAnimation(Theme.AnimationPresets.smooth) {
                eqManager.selectPreset(preset)
            }
        } label: {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: preset.icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : Theme.Colors.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Theme.Colors.brandGradient)
                            : AnyShapeStyle(Theme.Colors.surfaceCard),
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                            .stroke(isSelected ? Theme.Colors.brandGradientStart.opacity(0.5) : Theme.Colors.textTertiary.opacity(0.15), lineWidth: isSelected ? 1.5 : 1)
                    )

                Text(preset.localizedName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isSelected ? Theme.Colors.brandGradientStart : Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    // MARK: - Band Sliders

    private var bandsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("FREQUENCY BANDS")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.horizontal, Theme.Spacing.lg)

            HStack(alignment: .bottom, spacing: Theme.Spacing.xxs) {
                ForEach(0..<10, id: \.self) { index in
                    bandSlider(index: index)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 220)

            // dB labels
            HStack {
                Text("+12 dB")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
                Text("0 dB")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
                Text("-12 dB")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
    }

    private func bandSlider(index: Int) -> some View {
        @Bindable var eq = eqManager

        return VStack(spacing: Theme.Spacing.xxs) {
            Text(String(format: "%+.0f", eq.customBands[index]))
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(height: 16)

            GeometryReader { geo in
                let totalHeight = geo.size.height
                let normalized = CGFloat((eq.customBands[index] + 12) / 24)
                let fillHeight = max(4, totalHeight * normalized)

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.Colors.surfaceCard)
                        .frame(width: 24)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [Theme.Colors.brandGradientEnd, Theme.Colors.brandGradientStart],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 24, height: fillHeight)
                        .animation(Theme.AnimationPresets.smooth, value: eq.customBands[index])
                }
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            let fraction = 1.0 - (value.location.y / totalHeight)
                            let clamped = min(max(fraction, 0), 1)
                            let db = Float(clamped * 24 - 12)
                            eq.customBands[index] = (db * 2).rounded() / 2
                        }
                )
            }

            Text(EqualizerPreset.frequencyLabels[index])
                .font(Theme.Typography.caption2)
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(height: 14)
        }
        // VoiceOver: expose each band as adjustable element
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EqualizerPreset.frequencyLabels[index])
        .accessibilityValue(String(format: "%+.1f dB", eq.customBands[index]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                eq.customBands[index] = min(12, eq.customBands[index] + 1)
            case .decrement:
                eq.customBands[index] = max(-12, eq.customBands[index] - 1)
            @unknown default: break
            }
        }
    }
}
