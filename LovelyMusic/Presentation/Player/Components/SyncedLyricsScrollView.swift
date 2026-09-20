import SwiftUI
import Translation

/// Observes PlaybackProgress for current-line tracking so lyrics auto-scroll
/// doesn't force FullPlayerView to re-render every 0.5s.
///
/// This view fills whatever space its parent provides — no hardcoded maxHeight.
/// It replaces the vinyl disc in the same slot, so layout stays consistent.
struct SyncedLyricsScrollView: View {
    @Environment(PlaybackProgress.self) private var playbackProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lyrics: SyncedLyrics

    @State private var currentLineId: UUID?
    @State private var containerHeight: CGFloat = 300

    // User scroll lock state
    @State private var isUserScrolling = false
    @State private var autoScrollResumeTask: Task<Void, Never>?

    // Translation state
    @State private var showTranslation = false
    @State private var translatedLines: [UUID: String] = [:]
    @State private var isTranslating = false
    @State private var translationTrigger = false
    @State private var translationError: String?

    private var lyricsFingerprint: String {
        guard let first = lyrics.lines.first else { return "" }
        return "\(lyrics.lines.count)_\(first.text)"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: Theme.Spacing.md) {
                        // Small top padding — lyrics align near the top
                        Spacer().frame(height: Theme.Spacing.xl)
                        ForEach(lyrics.lines) { line in
                            lyricLine(line)
                                .id(line.id)
                        }
                        // Bottom spacer lets the last line scroll to center.
                        // Uses `containerRelativeFrame` so we no longer need
                        // an outer `GeometryReader` to read parent height —
                        // this avoids a layout invalidation per scroll frame.
                        Color.clear
                            .frame(height: 1)
                            .containerRelativeFrame(.vertical) { length, _ in
                                length * 0.5
                            }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .interacting {
                        withAnimation { isUserScrolling = true }
                        autoScrollResumeTask?.cancel()
                        autoScrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation { isUserScrolling = false }
                            }
                        }
                    }
                }
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .init(x: 0.5, y: 0.06))
                        Color.white
                        LinearGradient(colors: [.white, .clear], startPoint: .init(x: 0.5, y: 0.85), endPoint: .bottom)
                    }
                )
                .onChange(of: playbackProgress.currentTime) { _, newTime in
                    let newId = lyrics.lines.last { $0.time <= newTime }?.id
                    guard newId != currentLineId else { return }
                    currentLineId = newId
                    if let newId, !isUserScrolling {
                        if reduceMotion {
                            proxy.scrollTo(newId, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                proxy.scrollTo(newId, anchor: .center)
                            }
                        }
                    }
                }
            }

            // Translate button
            if showLyricsTranslationStored {
                translateButton
                    .padding(.trailing, Theme.Spacing.sm)
                    .padding(.top, Theme.Spacing.sm)
            }
        }
        .overlay(alignment: .bottom) {
            if isUserScrolling {
                Button {
                    withAnimation { isUserScrolling = false }
                    autoScrollResumeTask?.cancel()
                } label: {
                    Label("Follow lyrics", systemImage: "arrow.down.to.line")
                        .font(Theme.Typography.caption)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, Theme.Spacing.md)
            }
        }
        .onChange(of: lyricsFingerprint) { _, _ in
            translatedLines.removeAll()
            showTranslation = false
        }
        .modifier(LyricsTranslationModifier(
            lyrics: lyrics,
            targetLanguage: UserDefaults.standard.string(forKey: "language") ?? "vi",
            showTranslation: $showTranslation,
            translatedLines: $translatedLines,
            isTranslating: $isTranslating,
            trigger: $translationTrigger,
            translationError: $translationError
        ))
        .overlay(alignment: .top) {
            if let error = translationError {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.3), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { translationError = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Lyric Line

    @ViewBuilder
    private func lyricLine(_ line: LyricLine) -> some View {
        let isCurrent = line.id == currentLineId
        VStack(spacing: Theme.Spacing.xxs) {
            Text(line.text)
                .font(isCurrent ? currentLineFont : lineFont)
                .foregroundStyle(isCurrent ? Theme.Colors.textPrimary : Theme.Colors.textTertiary.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.3), value: isCurrent)

            if showLyricsTranslationStored, showTranslation, let translated = translatedLines[line.id] {
                Text(translated)
                    .font(translationFont)
                    .foregroundStyle(Theme.Colors.brandGradientStart.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.AnimationPresets.gentle, value: showTranslation)
    }

    // MARK: - Translate Button

    private var translateButton: some View {
        Button {
            triggerTranslation()
        } label: {
            Group {
                if isTranslating {
                    ProgressView()
                        .tint(Theme.Colors.textSecondary)
                } else {
                    Image(systemName: showTranslation ? "character.bubble.fill" : "character.bubble")
                        .foregroundStyle(
                            showTranslation ? Theme.Colors.brandGradientStart : Theme.Colors.textSecondary
                        )
                }
            }
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(showTranslation ? "Hide translation" : "Translate lyrics")
        .disabled(isTranslating)
    }

    // MARK: - Translation Trigger

    @AppStorage("lyricsFontSize") private var lyricsFontSizeRaw: String = "medium"
    @AppStorage("showLyricsTranslation") private var showLyricsTranslationStored: Bool = true

    private var lyricsFontSizePreference: LyricsFontSize {
        LyricsFontSize(rawValue: lyricsFontSizeRaw) ?? .medium
    }

    private var lineFont: Font {
        switch lyricsFontSizePreference {
        case .small:
            Theme.Typography.subheadline
        case .medium:
            Theme.Typography.body
        case .large:
            Theme.Typography.title3
        }
    }

    private var currentLineFont: Font {
        switch lyricsFontSizePreference {
        case .small:
            Theme.Typography.headline.weight(.bold)
        case .medium:
            Theme.Typography.title2.weight(.bold)
        case .large:
            Theme.Typography.title.weight(.bold)
        }
    }

    private var translationFont: Font {
        switch lyricsFontSizePreference {
        case .small:
            Theme.Typography.caption2
        case .medium:
            Theme.Typography.caption
        case .large:
            Theme.Typography.subheadline
        }
    }

    private func triggerTranslation() {
        guard showLyricsTranslationStored else { return }

        if showTranslation {
            withAnimation(Theme.AnimationPresets.gentle) {
                showTranslation = false
            }
            return
        }

        if !translatedLines.isEmpty {
            withAnimation(Theme.AnimationPresets.gentle) {
                showTranslation = true
            }
            return
        }

        translationTrigger.toggle()
    }
}

// MARK: - Translation Support

struct LyricsTranslationModifier: ViewModifier {
    let lyrics: SyncedLyrics?
    var targetLanguage: String?
    @Binding var showTranslation: Bool
    @Binding var translatedLines: [UUID: String]
    @Binding var isTranslating: Bool
    @Binding var trigger: Bool
    @Binding var translationError: String?

    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                await performTranslation(using: session)
            }
            .onChange(of: trigger) { _, _ in
                if config == nil {
                    if let lang = targetLanguage {
                        config = .init(target: Locale.Language(identifier: lang))
                    } else {
                        config = .init()
                    }
                } else {
                    config?.invalidate()
                }
            }
    }

    @MainActor
    private func performTranslation(using session: TranslationSession) async {
        guard let lyrics else { return }
        isTranslating = true
        defer { isTranslating = false }

        let translatableLines = lyrics.lines.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !(trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        }
        guard !translatableLines.isEmpty else { return }

        let requests = translatableLines.map {
            TranslationSession.Request(sourceText: $0.text)
        }

        do {
            let responses = try await session.translations(from: requests)
            var newTranslations: [UUID: String] = [:]
            for (index, response) in responses.enumerated() {
                newTranslations[translatableLines[index].id] = response.targetText
            }
            withAnimation(Theme.AnimationPresets.gentle) {
                translatedLines = newTranslations
                showTranslation = true
            }
        } catch {
            withAnimation {
                translationError = "Translation unavailable"
            }
        }
    }
}
