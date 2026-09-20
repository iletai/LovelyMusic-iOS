# LovelyMusic Design Specification

> Comprehensive UI/UX redesign specification for a production-quality iOS music streaming app.
> Inspired by Spotify, Apple Music, and YouTube Music.

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Color Palette](#color-palette)
- [Typography Scale](#typography-scale)
- [Spacing System](#spacing-system)
- [Corner Radius](#corner-radius)
- [Shadow System](#shadow-system)
- [Screen-by-Screen Redesign](#screen-by-screen-redesign)
- [Component Library](#component-library)
- [Animation Specifications](#animation-specifications)
- [SwiftUI-Specific Patterns](#swiftui-specific-patterns)

## Design Philosophy

### Core Principles

1. **Dark-First, Album-Centric** — Music apps live in dark mode. The UI recedes so album artwork becomes the visual hero. Every screen should feel like a stage for the content.
2. **Fluid Motion** — Every interaction should feel alive. Spring animations, matched geometry transitions, and micro-interactions create a sense of physicality.
3. **Glassmorphism for Layers** — Overlays (mini player, sheets, modals) use translucent materials to maintain context while presenting controls.
4. **8pt Grid Discipline** — All spacing, sizing, and layout decisions align to an 8pt base grid for visual harmony.
5. **Adaptive Theming** — Extract dominant colors from album artwork to tint the player, creating a unique atmosphere for every song.

### What's Wrong with the Current Design

The current implementation is a functional POC that relies heavily on system defaults:

- **Generic system colors** — No distinct brand identity; uses `systemBackground` and `AccentColor` without personality.
- **Flat, uniform surfaces** — No visual hierarchy between content layers; everything sits at the same elevation.
- **Minimal animation** — Basic spring animations exist but transitions between screens feel abrupt.
- **No adaptive theming** — The player uses hardcoded dark gradient colors instead of extracting palette from album art.
- **Undersized touch targets** — Some interactive elements are below the 44pt minimum.
- **Missing semantic colors** — No defined error/success/warning palette.
- **No greeting or personalization** — Home screen shows a static title without time-of-day context.

## Color Palette

### Brand Colors

```swift
enum Colors {
    // MARK: - Brand Gradient
    static let brandGradientStart = Color(hex: "#8B5CF6") // Vibrant purple
    static let brandGradientEnd   = Color(hex: "#EC4899") // Hot pink
    static let brandGradient = LinearGradient(
        colors: [brandGradientStart, brandGradientEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Backgrounds
    static let backgroundPrimary   = Color(hex: "#0A0A0A") // Near-black
    static let backgroundSecondary = Color(hex: "#1A1A1A") // Elevated surface
    static let backgroundTertiary  = Color(hex: "#2A2A2A") // Card surface
    static let backgroundElevated  = Color(hex: "#1E1E1E") // Sheets/modals

    // MARK: - Surfaces (with transparency)
    static let surfaceCard       = Color.white.opacity(0.05)  // Card fill
    static let surfaceHover      = Color.white.opacity(0.08)  // Hover/press state
    static let surfaceSelected   = Color.white.opacity(0.12)  // Active selection
    static let surfaceOverlay    = Color.black.opacity(0.60)  // Scrim overlay

    // MARK: - Text
    static let textPrimary    = Color.white                  // Titles, body
    static let textSecondary  = Color.white.opacity(0.70)    // Subtitles, metadata
    static let textTertiary   = Color.white.opacity(0.40)    // Timestamps, hints
    static let textDisabled   = Color.white.opacity(0.25)    // Disabled controls

    // MARK: - Semantic
    static let success = Color(hex: "#22C55E") // Green — downloaded, saved
    static let error   = Color(hex: "#EF4444") // Red — errors, destructive
    static let warning = Color(hex: "#F59E0B") // Amber — warnings, offline
    static let info    = Color(hex: "#3B82F6") // Blue — informational

    // MARK: - Player
    static let playerGradientTop    = Color(hex: "#1A1025") // Deep purple-black
    static let playerGradientBottom = Color(hex: "#0A0A0F") // Near-black
    static let miniPlayerBg = Color(hex: "#1A1A1A").opacity(0.95)
    static let progressGlow = Color(hex: "#8B5CF6").opacity(0.60)

    // MARK: - Dividers
    static let divider = Color.white.opacity(0.08)
}
```

### Dynamic Album-Based Theming

Extract dominant color from album artwork and use it to tint the player:

```swift
struct DynamicTheme {
    let dominant: Color       // Primary extracted color
    let vibrant: Color        // Most saturated variant
    let muted: Color          // Desaturated variant
    let gradientTop: Color    // Dominant at 40% opacity
    let gradientBottom: Color // backgroundPrimary
}

// Usage in FullPlayerView background:
ZStack {
    LinearGradient(
        colors: [dynamicTheme.gradientTop, Colors.backgroundPrimary],
        startPoint: .top,
        endPoint: .bottom
    )
    .ignoresSafeArea()
}
```

## Typography Scale

All typography uses SF Pro (system font) with precise weight control.

| Token | Size | Weight | Line Height | Use Case |
|-------|------|--------|-------------|----------|
| `largeTitle` | 34pt | Bold | 41pt | Section hero headers |
| `title` | 22pt | Bold | 28pt | Screen titles |
| `title2` | 20pt | Semibold | 25pt | Card titles, album names |
| `title3` | 17pt | Semibold | 22pt | Song title in player |
| `headline` | 17pt | Semibold | 22pt | Song titles in lists |
| `body` | 17pt | Regular | 22pt | Descriptions, lyrics |
| `subheadline` | 15pt | Regular | 20pt | Artist names, subtitles |
| `caption` | 12pt | Regular | 16pt | Metadata, durations |
| `caption2` | 11pt | Regular | 13pt | Timestamps, minor labels |

```swift
enum Typography {
    static let largeTitle   = Font.system(size: 34, weight: .bold, design: .default)
    static let title        = Font.system(size: 22, weight: .bold)
    static let title2       = Font.system(size: 20, weight: .semibold)
    static let title3       = Font.system(size: 17, weight: .semibold)
    static let headline     = Font.system(.headline)
    static let body         = Font.system(.body)
    static let subheadline  = Font.system(.subheadline)
    static let caption      = Font.system(size: 12, weight: .regular)
    static let caption2     = Font.system(size: 11, weight: .regular)
}
```

### Current Issues

- The current theme defines only 7 type styles. Missing `title3` for player song titles.
- `largeTitle` is defined but barely used — should be the hero element on Home.
- No explicit line-height control; relying on system defaults.

## Spacing System

An 8pt base grid with half-unit increments for fine control.

| Token | Value | Use Case |
|-------|-------|----------|
| `xxxs` | 2pt | Hairline gaps, icon padding |
| `xxs` | 4pt | Tight inline spacing |
| `xs` | 6pt | Compact chip padding |
| `sm` | 8pt | List item internal spacing |
| `md` | 12pt | Component internal padding |
| `lg` | 16pt | Standard content padding |
| `xl` | 24pt | Section spacing |
| `xxl` | 32pt | Major section gaps |
| `xxxl` | 48pt | Hero section separation |

```swift
enum Spacing {
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat  = 4
    static let xs: CGFloat   = 6
    static let sm: CGFloat   = 8
    static let md: CGFloat   = 12
    static let lg: CGFloat   = 16
    static let xl: CGFloat   = 24
    static let xxl: CGFloat  = 32
    static let xxxl: CGFloat = 48
}
```

### Current Issues

- Missing `xxxs` (2pt) and `xs` (6pt) tokens — some fine spacing requires arbitrary values.
- Missing `xxxl` (48pt) — hero sections use `xxl` (32pt), which is too tight.

## Corner Radius

| Token | Value | Use Case |
|-------|-------|----------|
| `small` | 8pt | Buttons, tags, chips, search bar |
| `medium` | 12pt | Cards, thumbnails, album art |
| `large` | 16pt | Sheets, modals, player artwork |
| `xl` | 20pt | Featured cards, hero images |
| `full` | 9999pt | Pills, circular avatars, capsules |

```swift
enum CornerRadius {
    static let small: CGFloat     = 8
    static let medium: CGFloat    = 12
    static let large: CGFloat     = 16
    static let xl: CGFloat        = 20
    static let full: CGFloat      = 9999
}
```

### Current Issues

- Missing `xl` (20pt) for hero cards — only jumps from 16pt to 24pt (`extraLarge`).
- No `full` radius token for pill buttons and circular elements.

## Shadow System

| Token | Radius | Y Offset | Opacity | Use Case |
|-------|--------|----------|---------|----------|
| `small` | 4pt | 2pt | 0.10 | Subtle card elevation |
| `medium` | 8pt | 4pt | 0.15 | Raised components |
| `large` | 16pt | 8pt | 0.20 | Floating elements |
| `glow` | 20pt | 0pt | 0.40 | Active player artwork |
| `colored` | 24pt | 12pt | 0.30 | Album art on player |

```swift
enum Shadow {
    static func small(_ content: some View) -> some View {
        content.shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
    }
    static func glow(_ content: some View, color: Color) -> some View {
        content.shadow(color: color.opacity(0.40), radius: 20, x: 0, y: 0)
    }
    static func colored(_ content: some View) -> some View {
        content.shadow(color: .black.opacity(0.30), radius: 24, x: 0, y: 12)
    }
}
```

## Screen-by-Screen Redesign

### Home Screen

#### Current Problems

- Static "LovelyMusic" title with no personality or time-awareness.
- All sections look identical — no visual hierarchy between featured and regular content.
- Cards are small (150pt) and feel cramped.
- No hero/featured carousel — missed opportunity for editorial content.
- Loading skeleton is basic shimmer rectangles without realistic shapes.

#### Redesigned Layout

```text
┌─────────────────────────────────────┐
│  Good Evening, User        [⚙️] [🔔]│  (time-based greeting)
│                                     │
│  ┌─────────────────────────────┐    │
│  │  ★ FEATURED CAROUSEL ★     │    │  (full-width, 220pt tall)
│  │  [Hero Card with gradient]  │    │  (paging scroll)
│  │  • • ○ ○                    │    │  (page indicator)
│  └─────────────────────────────┘    │
│                                     │
│  Quick Play                         │
│  [Chip] [Chip] [Chip] [Chip]  →     │  (recently played pills)
│                                     │
│  New Releases                       │
│  [180pt Card] [180pt Card]    →     │  (horizontal scroll)
│                                     │
│  Popular Right Now                  │
│  [Song Row] [Song Row] [Song Row]   │  (vertical list, top 5)
│                                     │
│  Artists You Might Like             │
│  (●) (●) (●) (●) (●)         →     │  (circular avatars)
│                                     │
└─────────────────────────────────────┘
```

#### Component Hierarchy

```swift
ScrollView {
    LazyVStack(spacing: Spacing.xl) {
        // 1. Greeting Header
        GreetingHeader(userName: user.name)

        // 2. Featured Carousel
        FeaturedCarousel(items: featured)
            .frame(height: 220)
            .scrollTargetBehavior(.viewAligned)

        // 3. Quick Play Chips
        QuickPlaySection(recentItems: recents)

        // 4. Content Sections
        ForEach(sections) { section in
            switch section.layout {
            case .horizontalLarge:
                HorizontalCardSection(section)  // 180pt cards
            case .horizontalSmall:
                HorizontalCardSection(section)  // 150pt cards
            case .verticalList:
                VerticalSongList(section)        // Song rows
            case .circularAvatars:
                ArtistAvatarRow(section)         // Circular chips
            }
        }
    }
    .padding(.horizontal, Spacing.lg)
}
```

#### Animation Specs

- **Greeting**: Fade in with 0.3s delay on appear.
- **Featured Carousel**: Auto-scroll every 5s with spring animation; `.scrollTargetBehavior(.viewAligned)`.
- **Quick Play chips**: Scale bounce on tap (0.92 → 1.0, spring 0.6 damping).
- **Section reveal**: Staggered fade-in as sections scroll into view using `scrollTransition`.
- **Pull-to-refresh**: Native `.refreshable` with haptic on completion.

### Search Screen

#### Current Problems

- Search bar is custom-built but lacks the polish of native search (no rounded fill).
- Filter chips are small and hard to tap — some may be below 44pt height.
- No search suggestions with thumbnails — just plain text strings.
- Results show only songs, not mixed content types.
- Missing trending/browse categories when search is empty.

#### Redesigned Layout

```text
┌─────────────────────────────────────┐
│  [🔍 Search songs, artists...]      │  (prominent rounded bar)
│                                     │
│  ── EMPTY STATE (no query) ──       │
│  Browse Categories                  │
│  ┌──────┐ ┌──────┐ ┌──────┐       │
│  │ Pop  │ │ Rock │ │ R&B  │       │  (2-column grid)
│  │ 🎵   │ │ 🎸   │ │ 🎤   │       │
│  └──────┘ └──────┘ └──────┘       │
│  ┌──────┐ ┌──────┐ ┌──────┐       │
│  │Hip   │ │ Jazz │ │K-Pop │       │
│  │Hop   │ │ 🎹   │ │ 💜   │       │
│  └──────┘ └──────┘ └──────┘       │
│                                     │
│  ── TYPING STATE ──                 │
│  [All] [Songs] [Albums] [Artists]   │  (filter chips)
│  Recent Searches                    │
│  [🕐 search term 1]          [✕]   │
│  [🕐 search term 2]          [✕]   │
│  Suggestions                        │
│  [🎵 Song Title — Artist]          │  (with thumbnail)
│  [👤 Artist Name]                   │
│                                     │
│  ── RESULTS STATE ──                │
│  [Song Row with Play Button]        │
│  [Album Card → navigate]           │
│  [Artist Row → navigate]           │
│  [Loading more...]                  │
└─────────────────────────────────────┘
```

#### Component Hierarchy

```swift
VStack(spacing: 0) {
    // Search Bar
    SearchBar(query: $query, isFocused: $isFocused)
        .padding(.horizontal, Spacing.lg)

    // Filter Chips (visible when query non-empty)
    if !query.isEmpty {
        FilterChipRow(selected: $selectedFilter, options: SearchFilter.allCases)
            .padding(.vertical, Spacing.sm)
    }

    // Content
    ScrollView {
        LazyVStack(spacing: Spacing.sm) {
            if query.isEmpty && !isFocused {
                BrowseCategoryGrid(categories: categories)
            } else if query.isEmpty && isFocused {
                RecentSearches(items: recents, onDelete: deleteRecent)
            } else {
                SearchResultsList(
                    results: results,
                    filter: selectedFilter,
                    onLoadMore: loadMore
                )
            }
        }
    }
}
```

#### Animation Specs

- **Search bar focus**: Expand with `.easeInOut(0.25)`; cancel button slides in from trailing edge.
- **Filter chips**: Capsule fill animates with `.spring(response: 0.3)` on selection change.
- **Results**: Rows fade in with staggered delay (index × 0.05s).
- **Category grid**: Scale on press (0.95), spring bounce on release.
- **Skeleton loading**: Shimmer gradient sweeps left-to-right at 1.5s interval using `GeometryReader` for proper sizing.

### Library Screen

#### Current Problems

- Uses `Form`/`List` style which looks like iOS Settings, not a music library.
- No visual distinction between playlists and recently played.
- No grid/list view toggle.
- No sorting or filtering options.
- "New Playlist" via alert is not visually appealing.
- Missing "Liked Songs" hero card.

#### Redesigned Layout

```text
┌─────────────────────────────────────┐
│  Your Library            [≡] [⊞]   │  (sort + grid toggle)
│                                     │
│  ┌─────────────────────────────┐    │
│  │  ❤️ Liked Songs             │    │  (gradient hero card)
│  │  142 songs                  │    │  (full-width, 80pt tall)
│  └─────────────────────────────┘    │
│                                     │
│  Recently Played                    │
│  [●] [●] [●] [●]            →     │  (circular recent items)
│                                     │
│  Playlists                          │
│  ┌──────┐ ┌──────┐                 │
│  │[Art] │ │[Art] │  (grid mode)    │  (2-column grid)
│  │Name  │ │Name  │                 │
│  │5 sng │ │12 sng│                 │
│  └──────┘ └──────┘                 │
│  ┌──────┐ ┌──────┐                 │
│  │ [+]  │ │[Art] │                 │  (+ card to create new)
│  │Create│ │Name  │                 │
│  │ New  │ │8 sng │                 │
│  └──────┘ └──────┘                 │
│                                     │
│  ── OR LIST MODE ──                 │
│  [Thumb] Playlist Name    [▸]      │
│          5 songs                    │
│  [Thumb] Playlist Name    [▸]      │
│          12 songs                   │
└─────────────────────────────────────┘
```

#### Component Hierarchy

```swift
ScrollView {
    LazyVStack(spacing: Spacing.xl) {
        // 1. Liked Songs Hero Card
        LikedSongsCard(count: likedCount)
            .frame(height: 80)
            .background(Colors.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large))

        // 2. Recently Played
        RecentlyPlayedRow(items: recentItems)

        // 3. Playlists Header with Controls
        HStack {
            Text("Playlists").font(Typography.title)
            Spacer()
            SortButton(sortOrder: $sortOrder)
            GridToggle(isGrid: $isGridView)
        }

        // 4. Playlist Grid or List
        if isGridView {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: Spacing.lg) {
                CreatePlaylistCard(action: showCreateSheet)
                ForEach(playlists) { playlist in
                    PlaylistGridCard(playlist: playlist)
                }
            }
        } else {
            ForEach(playlists) { playlist in
                PlaylistListRow(playlist: playlist)
            }
        }
    }
    .padding(.horizontal, Spacing.lg)
}
```

#### Animation Specs

- **Grid/List toggle**: `withAnimation(.spring(response: 0.4, dampingFraction: 0.8))` on layout switch; use `matchedGeometryEffect` for playlist thumbnails.
- **Liked Songs card**: Subtle gradient shimmer animation on the hero card.
- **Create playlist**: Present as `.sheet` with `.presentationDetents([.medium])` instead of alert.

### Mini Player

#### Current Problems

- Progress bar is a flat, thin line with no visual appeal.
- Background uses `.ultraThinMaterial` with no branded tint — looks generic.
- No swipe-up gesture hint or affordance.
- Play/pause button has no animation.
- No album art glow or color extraction.
- Missing left-swipe to dismiss and right-swipe for next.

#### Redesigned Layout

```text
┌─────────────────────────────────────────────┐
│ ▓▓▓▓▓▓▓░░░░░░░░░ (progress bar with glow)  │  2pt, brand gradient fill
├─────────────────────────────────────────────┤
│                                             │
│ [🎵 48pt]  Song Title         [⏸] [▶▶]     │  glassmorphic background
│  (shadow)  Artist Name         (bounce)     │  with album-tinted overlay
│                                             │
└─────────────────────────────────────────────┘
```

#### Component Hierarchy

```swift
VStack(spacing: 0) {
    // Glowing progress bar
    GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Colors.divider)
                .frame(height: 2)
            Capsule()
                .fill(Colors.brandGradient)
                .frame(width: geo.size.width * progress, height: 2)
                .shadow(color: Colors.progressGlow, radius: 4, y: 0)
        }
    }
    .frame(height: 2)

    // Content
    HStack(spacing: Spacing.md) {
        AsyncThumbnail(url: song.thumbnailURL, size: 48)
            .shadow(color: dominantColor.opacity(0.3), radius: 8)

        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            MarqueeText(song.title)
                .font(Typography.subheadline)
                .foregroundColor(Colors.textPrimary)
            Text(song.artist)
                .font(Typography.caption)
                .foregroundColor(Colors.textSecondary)
        }

        Spacer()

        PlayPauseButton(isPlaying: isPlaying, action: togglePlay)
            .buttonStyle(.bouncy)
            .frame(width: 44, height: 44)

        NextButton(action: playNext)
            .frame(width: 44, height: 44)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
}
.background(.ultraThinMaterial)
.background(dominantColor.opacity(0.08))
```

#### Animation Specs

- **Progress bar**: Continuous width animation with `.linear` timing; glow pulses subtly.
- **Play/Pause**: `symbolEffect(.bounce)` on SF Symbol; scale 0.85 → 1.0 with `spring(response: 0.3, dampingFraction: 0.6)`.
- **Tap to expand**: `matchedGeometryEffect(id: "albumArt")` for seamless artwork transition to full player.
- **Swipe gestures**: Horizontal swipe (>60pt) to skip track; vertical swipe up (>40pt) to expand.
- **Appear/disappear**: Slide up from bottom with `.move(edge: .bottom).combined(with: .opacity)`.
- **Long title**: `MarqueeText` scrolls horizontally when title exceeds available width.

### Full Player Screen

#### Current Problems

- Album artwork is limited to 80% screen width — should dominate the view.
- Background blur at 60pt is aggressive and loses detail.
- Drag indicator is barely visible (white 0.5 opacity).
- Slider is stock iOS with no custom styling.
- Missing lyrics panel, queue view, and share button.
- No `matchedGeometryEffect` transition from mini player.
- Song info text is small and hard to read.
- No animated equalizer or "now playing" visual feedback.

#### Redesigned Layout

```text
┌─────────────────────────────────────┐
│  [━━━ Drag Handle ━━━]              │  (capsule, white 0.3)
│  [▼]                        [⋯]    │  (dismiss + menu)
│                                     │
│                                     │
│     ┌───────────────────┐           │
│     │                   │           │  (album art, dynamic shadow)
│     │   Album Artwork   │           │  (85% width, matched geometry)
│     │   (with glow)     │           │  (corner radius: 12pt)
│     │                   │           │
│     └───────────────────┘           │
│                                     │
│  Song Title                    [❤️]  │  (title2, semibold)
│  Artist Name                        │  (subheadline, tappable)
│                                     │
│  ○━━━━━━━━━━━━━●━━━━━━━━━━━━━━○    │  (custom slider with glow)
│  1:23                    3:45       │  (elapsed / remaining)
│                                     │
│  [🔀]   [⏮]   [⏯]   [⏭]   [🔁]   │  (transport controls)
│                                     │
│  [📃 Lyrics]  [📋 Queue]  [📤 Share]│  (bottom action bar)
│                                     │
│  ┌─────────────────────────────┐    │
│  │  Lyrics slide-up panel      │    │  (drag up to reveal)
│  │  (synced, auto-scroll)      │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

Background: Album art extracted dominant color as gradient (top: dominant at 40% → bottom: `#0A0A0A`).

#### Component Hierarchy

```swift
ZStack {
    // Dynamic gradient background
    DynamicGradientBackground(dominantColor: extractedColor)
        .ignoresSafeArea()

    VStack(spacing: Spacing.xxl) {
        // Top bar
        HStack {
            DismissButton(action: dismiss)
            Spacer()
            MoreMenuButton(song: currentSong)
        }
        .padding(.horizontal, Spacing.lg)

        Spacer()

        // Album Artwork (hero)
        AsyncThumbnail(url: song.thumbnailURL, size: screenWidth * 0.85)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
            .shadow(color: extractedColor.opacity(0.40), radius: 24, y: 12)
            .matchedGeometryEffect(id: "albumArt", in: namespace)

        Spacer()

        // Song Info
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(song.title)
                    .font(Typography.title2)
                    .foregroundColor(Colors.textPrimary)
                    .lineLimit(1)
                Text(song.artist)
                    .font(Typography.subheadline)
                    .foregroundColor(Colors.textSecondary)
            }
            Spacer()
            LikeButton(isLiked: $isLiked)
        }
        .padding(.horizontal, Spacing.xl)

        // Progress Slider
        CustomProgressSlider(
            value: $progress,
            onEditingChanged: seekTo
        )
        .padding(.horizontal, Spacing.xl)

        // Time Labels
        HStack {
            Text(formatTime(currentTime))
                .font(Typography.caption2)
                .foregroundColor(Colors.textTertiary)
                .contentTransition(.numericText())
            Spacer()
            Text(formatTime(duration))
                .font(Typography.caption2)
                .foregroundColor(Colors.textTertiary)
        }
        .padding(.horizontal, Spacing.xl)

        // Transport Controls
        TransportControls(
            isPlaying: isPlaying,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            onShuffle: toggleShuffle,
            onPrevious: previousTrack,
            onPlayPause: togglePlay,
            onNext: nextTrack,
            onRepeat: cycleRepeat
        )

        // Bottom Action Bar
        HStack(spacing: Spacing.xxxl) {
            LyricsButton(action: showLyrics)
            QueueButton(action: showQueue)
            ShareButton(action: shareTrack)
        }
        .padding(.bottom, Spacing.lg)
    }
}
```

#### Animation Specs

- **Mini → Full transition**: `matchedGeometryEffect` on album art with `.spring(response: 0.5, dampingFraction: 0.85)`; controls fade in with 0.2s delay.
- **Drag to dismiss**: Interactive spring; dismiss threshold at 150pt vertical offset.
- **Play/Pause**: SF Symbol morph with `.symbolEffect(.replace)` (iOS 17+); fallback to `contentTransition(.symbolEffect(.replace))`.
- **Album art on song change**: Crossfade with `.transition(.asymmetric(insertion: .opacity, removal: .opacity))` and 0.3s animation.
- **Slider thumb**: Custom circle (14pt) with brand gradient fill and glow shadow; scale to 18pt when dragging.
- **Lyrics panel**: Slide up from bottom as `.sheet` with `.presentationDetents([.medium, .large])`.
- **Like button**: `symbolEffect(.bounce)` on toggle with haptic `.sensoryFeedback(.impact(weight: .light))`.

### Artist Page

#### Current Problems

- Hero image is 300pt tall but has no parallax scroll effect despite the `ParallaxEffect` modifier existing.
- Gradient overlay uses simple black — should incorporate artist's color palette.
- Only shows first 5 songs with no "See All" option.
- Albums section has small 150pt cards — should be larger for browsing.
- No "Similar Artists" or "About" section.
- No shuffle/play all button.

#### Redesigned Layout

```text
┌─────────────────────────────────────┐
│  ← Back                            │  (overlaid on hero)
│                                     │
│  ┌─────────────────────────────┐    │
│  │     HERO IMAGE (350pt)      │    │  (parallax on scroll)
│  │     (full-width, bleed)     │    │  (gradient overlay)
│  │                             │    │
│  │     Artist Name             │    │  (largeTitle, bold)
│  │     1.2M listeners         │    │  (subheadline)
│  │                             │    │
│  │   [▶ Play] [🔀 Shuffle]    │    │  (pill buttons)
│  └─────────────────────────────┘    │
│                                     │
│  Popular Songs                      │
│  [1] [Song Row]                     │  (numbered, top 5)
│  [2] [Song Row]                     │
│  [3] [Song Row]                     │
│  [4] [Song Row]                     │
│  [5] [Song Row]                     │
│  [See All ▸]                        │
│                                     │
│  Albums                             │
│  [180pt] [180pt] [180pt]     →     │  (horizontal scroll)
│  Title   Title    Title             │
│  2024    2022     2020              │
│                                     │
│  Similar Artists                    │
│  (●) (●) (●) (●)            →     │  (circular avatars)
│                                     │
└─────────────────────────────────────┘
```

#### Component Hierarchy

```swift
ScrollView {
    LazyVStack(spacing: Spacing.xl) {
        // Hero with Parallax
        GeometryReader { geo in
            let offset = geo.frame(in: .global).minY
            AsyncThumbnail(url: artist.imageURL, size: max(350, 350 + offset))
                .overlay(
                    LinearGradient(
                        colors: [.clear, .clear, Colors.backgroundPrimary],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(artist.name)
                            .font(Typography.largeTitle)
                            .foregroundColor(Colors.textPrimary)
                        if let subs = artist.subscriberCount {
                            Text(subs)
                                .font(Typography.subheadline)
                                .foregroundColor(Colors.textSecondary)
                        }
                        HStack(spacing: Spacing.md) {
                            PlayPillButton(label: "Play", action: playAll)
                            ShufflePillButton(label: "Shuffle", action: shuffleAll)
                        }
                    }
                    .padding(Spacing.lg)
                }
                .offset(y: offset > 0 ? -offset : 0)
        }
        .frame(height: 350)

        // Popular Songs (numbered)
        SectionHeader(title: "Popular Songs")
        ForEach(Array(songs.prefix(5).enumerated()), id: \.offset) { index, song in
            NumberedSongRow(number: index + 1, song: song)
        }
        if songs.count > 5 {
            SeeAllButton(action: showAllSongs)
        }

        // Albums
        SectionHeader(title: "Albums")
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Spacing.md) {
                ForEach(albums) { album in
                    AlbumCard(album: album, size: 180)
                }
            }
            .padding(.horizontal, Spacing.lg)
        }
    }
}
```

#### Animation Specs

- **Parallax hero**: Offset multiplier of 0.5 using `GeometryReader`; image scales up when pulled down (rubber-band effect).
- **Navigation bar**: Transparent initially, fills with blur material as user scrolls past hero (use `scrollPosition` or `GeometryReader`).
- **Song rows**: Staggered fade-in (index × 0.05s delay).
- **Album cards**: Pressure-scale on touch (0.95) with spring release.

### Album Page

#### Current Problems

- Album artwork is only 220pt — should be larger and more prominent.
- No sticky header behavior on scroll.
- Track numbers are plain text without visual weight.
- Play/Shuffle buttons use different button styles (`.borderedProminent` vs `.bordered`) — should be consistent pills.
- No total play time or release year display.
- Missing credits or description section.

#### Redesigned Layout

```text
┌─────────────────────────────────────┐
│  ← Back                            │
│                                     │
│        ┌─────────────────┐          │
│        │                 │          │
│        │  Album Artwork  │          │  (280pt, centered)
│        │  (shadow + glow)│          │  (colored shadow from art)
│        │                 │          │
│        └─────────────────┘          │
│                                     │
│     Album Title                     │  (title, bold, centered)
│     Artist Name                     │  (subheadline, tappable)
│     2024 · 12 songs · 42 min       │  (caption, tertiary)
│                                     │
│   [▶ Play All]  [🔀 Shuffle]       │  (pill buttons, brand color)
│                                     │
│  ─────────── Track List ──────────  │
│  1   Song Title              3:42   │  (track number prominent)
│      Artist                         │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  2   Song Title              4:01   │
│      Artist                         │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  3   Song Title              3:18   │
│      (Currently Playing) 🎵        │  (accent color + wave)
│  ...                                │
│                                     │
│  Release Date: Jan 15, 2024        │  (footer metadata)
│  ℗ 2024 Label Name                 │
└─────────────────────────────────────┘
```

#### Component Hierarchy

```swift
ScrollView {
    LazyVStack(spacing: 0) {
        // Album Header
        VStack(spacing: Spacing.md) {
            AsyncThumbnail(url: album.thumbnailURL, size: 280)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                .shadow(color: dominantColor.opacity(0.30), radius: 24, y: 12)

            Text(album.title)
                .font(Typography.title)
                .foregroundColor(Colors.textPrimary)
                .multilineTextAlignment(.center)

            NavigationLink(value: Route.artist(album.artistId)) {
                Text(album.artist)
                    .font(Typography.subheadline)
                    .foregroundColor(Colors.textSecondary)
            }

            if let year = album.year {
                Text("\(year) · \(album.songs.count) songs · \(album.formattedDuration)")
                    .font(Typography.caption)
                    .foregroundColor(Colors.textTertiary)
            }

            HStack(spacing: Spacing.lg) {
                PillButton(icon: "play.fill", label: "Play All", style: .primary)
                PillButton(icon: "shuffle", label: "Shuffle", style: .secondary)
            }
        }
        .padding(.vertical, Spacing.xl)

        // Track List
        Divider().background(Colors.divider)
        ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
            TrackRow(
                number: index + 1,
                song: song,
                isPlaying: song.id == currentSong?.id,
                onTap: { play(song, queue: album.songs) }
            )
            if index < album.songs.count - 1 {
                Divider()
                    .background(Colors.divider)
                    .padding(.leading, 56)
            }
        }

        // Footer
        AlbumFooter(releaseDate: album.releaseDate, label: album.label)
            .padding(.top, Spacing.xxl)
    }
    .padding(.horizontal, Spacing.lg)
}
```

#### Animation Specs

- **Sticky header**: Album artwork shrinks and blurs into navigation bar on scroll using `GeometryReader` offset tracking.
- **Track rows**: Playing track number replaced with `MusicWaveIndicator` using `contentTransition(.symbolEffect(.replace))`.
- **Play buttons**: `.sensoryFeedback(.impact(weight: .medium), trigger: isPlaying)` on tap.

### Settings Screen

#### Current Problems

- Generic iOS `Form` styling — looks like system Settings, not a music app.
- No account card with user avatar.
- Hard-coded version "1.0.0" not pulled from bundle.
- Sign out has no confirmation dialog.
- No visual hierarchy between sections.
- Missing app icon and branding in About section.

#### Redesigned Layout

```text
┌─────────────────────────────────────┐
│  Settings                           │
│                                     │
│  ┌─────────────────────────────┐    │
│  │  [👤 Avatar]                │    │  (account card)
│  │  User Name                  │    │  (glassmorphic card)
│  │  user@email.com             │    │
│  │  [Manage Account ▸]        │    │
│  └─────────────────────────────┘    │
│                                     │
│  PLAYBACK                          │
│  ┌─────────────────────────────┐    │
│  │ 🎵 Audio Quality    High ▸ │    │
│  │ 📱 Equalizer         Off ▸ │    │
│  │ advancement Crossfade  On  │    │
│  └─────────────────────────────┘    │
│                                     │
│  CONTENT                           │
│  ┌─────────────────────────────┐    │
│  │ 🌏 Region          VN ▸   │    │
│  │ 🔤 Language       Auto ▸   │    │
│  └─────────────────────────────┘    │
│                                     │
│  STORAGE                           │
│  ┌─────────────────────────────┐    │
│  │ 💾 Cache          123 MB   │    │
│  │ 🗑️ Clear Cache             │    │  (destructive)
│  └─────────────────────────────┘    │
│                                     │
│  ABOUT                             │
│  ┌─────────────────────────────┐    │
│  │ [App Icon] LovelyMusic      │    │
│  │            Version 1.0.0    │    │
│  │ 📋 Licenses                 │    │
│  │ ⭐ Rate App                 │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

#### Component Hierarchy

```swift
ScrollView {
    LazyVStack(spacing: Spacing.xl) {
        // Account Card
        AccountCard(user: currentUser)
            .background(Colors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large))

        // Playback Section
        SettingsGroup(header: "Playback") {
            SettingsRow(icon: "music.note", title: "Audio Quality", value: quality.displayName)
        }

        // Content Section
        SettingsGroup(header: "Content") {
            SettingsRow(icon: "globe", title: "Region", value: region.displayName)
            SettingsRow(icon: "textformat", title: "Language", value: language.displayName)
        }

        // Storage Section
        SettingsGroup(header: "Storage") {
            SettingsRow(icon: "internaldrive", title: "Cache", value: cacheSize)
            SettingsDestructiveRow(icon: "trash", title: "Clear Cache", action: clearCache)
        }

        // About Section
        SettingsGroup(header: "About") {
            AppInfoRow(version: appVersion, buildNumber: buildNumber)
            SettingsRow(icon: "doc.text", title: "Licenses")
            SettingsRow(icon: "star", title: "Rate App")
        }
    }
    .padding(.horizontal, Spacing.lg)
}
```

#### Design Notes

- Each `SettingsGroup` renders as a card with `Colors.backgroundTertiary` background and `CornerRadius.large`.
- SF Symbols for every row icon provide visual consistency.
- Version should be read from `Bundle.main.infoDictionary`.
- Sign out should trigger `.confirmationDialog` before proceeding.

## Component Library

### SongRow

The primary list item for displaying songs across the app.

```swift
struct SongRow: View {
    let song: Song
    var trackNumber: Int?
    var isPlaying: Bool = false
    var showThumbnail: Bool = true
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.md) {
                // Track number or thumbnail
                if let number = trackNumber {
                    if isPlaying {
                        MusicWaveIndicator()
                            .frame(width: 24)
                    } else {
                        Text("\(number)")
                            .font(Typography.subheadline)
                            .foregroundColor(Colors.textTertiary)
                            .frame(width: 24)
                    }
                } else if showThumbnail {
                    AsyncThumbnail(url: song.thumbnailURL, size: 48)
                        .overlay {
                            if isPlaying {
                                MusicWaveIndicator()
                                    .padding(Spacing.sm)
                                    .background(.black.opacity(0.4))
                                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                            }
                        }
                }

                // Song info
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(song.title)
                        .font(Typography.headline)
                        .foregroundColor(isPlaying ? Colors.brandGradientStart : Colors.textPrimary)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(Typography.caption)
                        .foregroundColor(Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                // Duration
                Text(song.formattedDuration)
                    .font(Typography.caption2)
                    .foregroundColor(Colors.textTertiary)

                // Menu
                Image(systemName: "ellipsis")
                    .foregroundColor(Colors.textTertiary)
                    .frame(width: 44, height: 44)
            }
            .padding(.vertical, Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

### AlbumCard

Horizontal-scroll card for album browsing.

```swift
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 180

    var body: some View {
        NavigationLink(value: Route.album(album.browseId)) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                AsyncThumbnail(url: album.thumbnailURL, size: size)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))

                Text(album.title)
                    .font(Typography.subheadline)
                    .foregroundColor(Colors.textPrimary)
                    .lineLimit(2)

                Text(album.artist)
                    .font(Typography.caption)
                    .foregroundColor(Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
    }
}
```

### ArtistChip

Circular artist avatar for horizontal rows.

```swift
struct ArtistChip: View {
    let artist: Artist
    var size: CGFloat = 80

    var body: some View {
        NavigationLink(value: Route.artist(artist.browseId)) {
            VStack(spacing: Spacing.sm) {
                AsyncThumbnail(url: artist.thumbnailURL, size: size)
                    .clipShape(Circle())

                Text(artist.name)
                    .font(Typography.caption)
                    .foregroundColor(Colors.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
    }
}
```

### PlayButton

Animated play/pause with scale bounce.

```swift
struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void
    var size: CGFloat = 64

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: size))
                .foregroundColor(Colors.textPrimary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bouncy)
        .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
    }
}
```

### ProgressSlider

Custom slider with glowing thumb and gradient track.

```swift
struct ProgressSlider: View {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Colors.surfaceCard)
                    .frame(height: 4)

                // Filled track
                Capsule()
                    .fill(Colors.brandGradient)
                    .frame(width: geo.size.width * CGFloat(value), height: 4)

                // Thumb
                Circle()
                    .fill(Colors.textPrimary)
                    .frame(width: isDragging ? 18 : 14, height: isDragging ? 18 : 14)
                    .shadow(color: Colors.brandGradientStart.opacity(0.5), radius: 8)
                    .offset(x: geo.size.width * CGFloat(value) - (isDragging ? 9 : 7))
                    .animation(.spring(response: 0.2), value: isDragging)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        value = max(0, min(1, Double(gesture.location.x / geo.size.width)))
                        onEditingChanged(true)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 44) // Touch target
    }
}
```

### MusicWaveIndicator

Animated equalizer bars for "now playing" state.

```swift
struct MusicWaveIndicator: View {
    var color: Color = Colors.brandGradientStart
    var barCount: Int = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveBar(color: color, delay: Double(index) * 0.15)
            }
        }
        .frame(width: CGFloat(barCount) * 5, height: 16)
    }
}

struct WaveBar: View {
    let color: Color
    let delay: Double

    @State private var animating = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 3)
            .scaleEffect(y: animating ? 1.0 : 0.3, anchor: .bottom)
            .animation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(delay),
                value: animating
            )
            .onAppear { animating = true }
    }
}
```

### GradientBackground

Dynamic gradient extracted from album art.

```swift
struct DynamicGradientBackground: View {
    let dominantColor: Color
    var opacity: Double = 0.40

    var body: some View {
        ZStack {
            Colors.backgroundPrimary

            LinearGradient(
                colors: [
                    dominantColor.opacity(opacity),
                    dominantColor.opacity(opacity * 0.5),
                    Colors.backgroundPrimary
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: dominantColor)
    }
}
```

### SkeletonLoader

Shimmer effect with proper geometry-aware sizing.

```swift
struct SkeletonLoader: View {
    var width: CGFloat? = nil
    var height: CGFloat = 16
    var cornerRadius: CGFloat = CornerRadius.small

    @State private var phase: CGFloat = -1.0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Colors.surfaceCard)
            .frame(width: width, height: height)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: geo.size.width * phase)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1.5
                }
            }
    }
}
```

## Animation Specifications

### Transition Map

| Transition | Trigger | Animation | Duration |
|------------|---------|-----------|----------|
| Mini → Full Player | Tap mini player | `matchedGeometryEffect` + spring | 0.5s, damping 0.85 |
| Full → Mini Player | Drag down >150pt | `interactiveSpring` | 0.4s |
| Song Change | New track starts | Crossfade album art with `opacity` | 0.3s |
| Play/Pause | Button tap | `symbolEffect(.replace)` | System default |
| Screen Push | Navigation link | Default push with fade | System default |
| Sheet Present | Bottom sheet | `.presentationDetents` slide | System default |
| List Item Appear | Scroll into view | `scrollTransition` opacity+offset | 0.3s |
| Button Press | Touch down | Scale 0.92 + opacity 0.8, spring | 0.3s, damping 0.6 |
| Chip Selection | Tap filter chip | Capsule fill with spring | 0.3s, damping 0.7 |
| Loading Shimmer | Data loading | Linear gradient sweep | 1.5s loop |
| Pull to Refresh | Pull gesture | Native refreshable | System default |

### Spring Presets

```swift
enum AnimationPresets {
    /// Button press feedback
    static let bouncy = Animation.spring(response: 0.3, dampingFraction: 0.6)

    /// UI state transitions (expand/collapse)
    static let smooth = Animation.spring(response: 0.4, dampingFraction: 0.8)

    /// Player expand/collapse
    static let playerTransition = Animation.spring(response: 0.5, dampingFraction: 0.85)

    /// Subtle property changes
    static let gentle = Animation.easeInOut(duration: 0.25)

    /// Content crossfade
    static let crossfade = Animation.easeInOut(duration: 0.3)

    /// Color/gradient transitions
    static let colorShift = Animation.easeInOut(duration: 0.8)
}
```

### Haptic Feedback Map

| Action | Haptic Type | iOS API |
|--------|-------------|---------|
| Play/Pause | `.impact(weight: .light)` | `.sensoryFeedback` |
| Skip Track | `.impact(weight: .medium)` | `.sensoryFeedback` |
| Like/Unlike | `.impact(weight: .light)` | `.sensoryFeedback` |
| Long Press Menu | `.impact(weight: .heavy)` | `.sensoryFeedback` |
| Slider Snap | `.selection` | `.sensoryFeedback` |
| Error | `.error` | `.sensoryFeedback` |
| Success (Download) | `.success` | `.sensoryFeedback` |
| Pull to Refresh | `.impact(weight: .medium)` | `.sensoryFeedback` |

## SwiftUI-Specific Patterns

### iOS 17+ APIs to Adopt

```swift
// 1. Sensory Feedback (replaces UIImpactFeedbackGenerator)
Button("Play") { play() }
    .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)

// 2. Numeric Text Transition (time displays)
Text(formatTime(currentTime))
    .contentTransition(.numericText())

// 3. View-Aligned Scroll (carousels)
ScrollView(.horizontal) {
    LazyHStack { /* cards */ }
}
.scrollTargetBehavior(.viewAligned)
.scrollTargetLayout()

// 4. Container Relative Frame (responsive sizing)
AsyncThumbnail(url: url)
    .containerRelativeFrame(.horizontal) { length, _ in
        length * 0.85  // 85% of container width
    }

// 5. SF Symbol Effects
Image(systemName: "play.fill")
    .symbolEffect(.bounce, value: triggerValue)

Image(systemName: isPlaying ? "pause.fill" : "play.fill")
    .contentTransition(.symbolEffect(.replace))

// 6. Scroll Transition (staggered reveals)
LazyVStack {
    ForEach(items) { item in
        SongRow(song: item)
            .scrollTransition { content, phase in
                content
                    .opacity(phase.isIdentity ? 1 : 0.3)
                    .offset(y: phase.isIdentity ? 0 : 20)
            }
    }
}

// 7. Phase Animator (complex state loops)
PhaseAnimator([false, true]) { value in
    MusicWaveBar()
        .scaleEffect(y: value ? 1.0 : 0.3)
} animation: { _ in
    .easeInOut(duration: 0.4)
}
```

### Architecture Patterns

```swift
// Matched Geometry for Mini → Full Player
struct PlayerContainer: View {
    @Namespace private var playerNamespace
    @State private var isExpanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // App content
            TabView { /* ... */ }

            if isExpanded {
                FullPlayerView(namespace: playerNamespace)
                    .transition(.move(edge: .bottom))
            } else {
                MiniPlayerView(namespace: playerNamespace)
                    .onTapGesture { withAnimation(AnimationPresets.playerTransition) { isExpanded = true } }
            }
        }
    }
}

// In both views, mark the album art:
AsyncThumbnail(url: song.thumbnailURL, size: artSize)
    .matchedGeometryEffect(id: "playerAlbumArt", in: namespace)
```

### Accessibility Requirements

- All interactive elements must have a minimum 44pt touch target.
- Every icon-only button must have an `accessibilityLabel`.
- Dynamic Type support: use `@ScaledMetric` for custom sizes.
- Color contrast ratio: minimum 4.5:1 for body text, 3:1 for large text.
- Support `accessibilityShowsLargeContentViewer` for small controls.

```swift
// Example: Accessible play button
Button(action: togglePlay) {
    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 24))
}
.frame(minWidth: 44, minHeight: 44)
.accessibilityLabel(isPlaying ? "Pause" : "Play")
.accessibilityHint("Double tap to \(isPlaying ? "pause" : "play") the current song")
```
