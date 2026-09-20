# LovelyMusic — Roadmap

> Phases 1–3 (Foundation, Core Playback, Content Browsing) are complete and captured in [FEATURES.md](FEATURES.md).
> This document covers the planned work from Phase 4 onward.

## Phase 4: UI/UX Overhaul

The current UI is functional but uses default SwiftUI styling. This phase focuses on a polished, music-app-quality experience.

- Complete visual redesign with a custom design system (typography, color palette, spacing tokens)
- Smooth view transitions and matched geometry animations for player open/close
- Dark and light theme support with system appearance tracking
- Haptic feedback on interactive elements (play/pause, skip, queue actions)
- Skeleton loading states replaced with richer shimmer and placeholder artwork
- Responsive layouts for all iPhone screen sizes and orientations
- Gesture-driven interactions (swipe-to-skip on mini player, long-press context menus)

## Phase 5: Core Features Enhancement

Deepen the core music experience beyond basic streaming.

### Offline Downloads

- Download tracks for offline playback with DRM-free local storage
- Download queue management with progress indicators
- Automatic cleanup of expired or unused downloads
- Storage usage dashboard in Settings

### Smart Queue

- Auto-play related tracks when the queue ends via the InnerTube `/next` endpoint
- "Up Next" vs "Queue" separation with distinct UI sections
- History-aware shuffle using Fisher-Yates algorithm (no immediate repeats)
- Drag-to-reorder queue UI

### Search Improvements

- Search history persistence across sessions (stored locally)
- Recent searches displayed below the search bar
- Trending searches fetched from InnerTube

### Play History

- Recently played tracks, albums, and artists
- Listening statistics (play count, total time)
- "Pick up where you left off" on app launch

### Audio Enhancements

- Equalizer with Audio Unit presets (Bass Boost, Vocal, Rock, etc.)
- Sleep timer with configurable duration and fade-out
- Crossfade between tracks with adjustable overlap duration
- Gapless playback for album listening
- Volume normalization (ReplayGain-style)

## Phase 6: Social and Discovery

Connect with YouTube Music's social features and improve content discovery.

### YouTube Integration (Authenticated)

- Sync YouTube Music playlists (read and write) for logged-in users
- Sync liked songs and listening history
- Access personalized mixes (Your Mix, Discover Mix)

### Sharing

- Share songs, albums, and playlists via deep links
- Universal Links for opening shared content in-app
- Share sheet integration with rich link previews

### Discovery

- Charts and trending music by region
- Genre-based browsing and mood playlists
- "Fans Also Like" artist recommendations
- New releases feed

## Phase 7: Platform Integration

Leverage Apple platform capabilities for a native-feeling experience.

### CarPlay

- CarPlay audio app with simplified browsing (Home, Search, Library, Queue)
- Voice-driven search via CarPlay's built-in dictation
- Now Playing screen with album art and controls

### Home Screen Widgets (WidgetKit)

- Now Playing widget (small, medium) showing current track
- Recently Played widget for quick access to recent music
- Quick Play widget for favorite playlists

### Live Activities (Dynamic Island)

- Live Activity for active playback showing song title and progress
- Dynamic Island compact and expanded views with playback controls
- Lock screen Live Activity with elapsed time and artwork

### Siri Shortcuts and App Intents

- "Play music" Siri intent with natural language song/artist matching
- Shortcut actions: Play, Pause, Skip, Search, Play Playlist
- Spotlight integration for indexing songs and playlists

### Apple Watch Companion

- Standalone Watch app with playback controls
- Queue browsing and track skipping from the wrist
- Bluetooth audio output from Watch
- Complications for Now Playing status

## Phase 8: Polish and Localization

Prepare the app for a wider audience with accessibility, localization, and performance work.

### Localization

- Vietnamese (vi) — full UI translation
- English (en) — full UI translation
- String Catalog (`.xcstrings`) for all user-facing text
- RTL layout support groundwork

### Accessibility

- Full VoiceOver support with meaningful labels and hints
- Dynamic Type support across all views
- Reduce Motion support for animation-sensitive users
- High contrast mode compatibility
- Keyboard navigation for external keyboard users

### Performance

- Memory optimization: image caching with size limits, view recycling
- Battery optimization: reduced background polling, efficient audio buffering
- Network optimization: request deduplication, smarter prefetching
- Launch time optimization: lazy dependency initialization

### Stability

- Crash reporting integration (Firebase Crashlytics or Sentry)
- Analytics for feature usage and engagement
- Automated UI testing with XCUITest
- Unit test coverage for all ViewModels and UseCases

## Phase 9: Distribution

Ship the app to real users.

### TestFlight Beta

- Internal testing with a small group of testers
- Feedback collection via TestFlight's built-in mechanism
- Iterate on crash reports and user feedback
- Beta expiration and update management

### App Store Submission Considerations

- InnerTube API usage falls outside YouTube's official Terms of Service — this is a significant risk for App Store review
- Evaluate alternatives: YouTube Data API v3 (official, quota-limited), YouTube IFrame Player API
- Prepare a clear app description that does not reference "YouTube" branding inappropriately
- Review Apple's guidelines on streaming content from third-party services (section 5.2.3)

### Privacy Policy Requirements

- Disclose data collection: search queries, playback history, cookies (if logged in)
- Declare App Privacy nutrition labels (Data Linked to You, Data Not Linked to You)
- GDPR and CCPA considerations for cookie-based authentication
- No user data sold or shared with third parties — document this clearly

### Legal

- Ensure compliance with DMCA and content licensing considerations
- Add proper attribution for open-source dependencies (LrcLib, etc.)
- Terms of Service for the app itself
