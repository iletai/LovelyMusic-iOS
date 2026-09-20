# LovelyMusic — Current Features

> **Status:** Proof of Concept (POC)
> **Platform:** iOS · SwiftUI · YouTube InnerTube API (ANDROID_VR client)

## Home Feed

**What it does:** Displays personalized music recommendations in horizontally scrollable sections. Each section contains a mix of songs, albums, artists, and playlists fetched via the InnerTube browse endpoint. Includes pull-to-refresh and shimmer loading placeholders.

**Current limitations:**

- No continuation/pagination for loading additional sections
- No offline fallback or cached home content
- Error state exists but provides no retry action beyond pull-to-refresh
- Section layout is uniform — no editorial cards or hero banners

**Quality:** ⭐⭐⭐

## Search

**What it does:** Full-text search across songs, albums, artists, and playlists via InnerTube. Features include debounced search suggestions (300 ms delay), filter chips for result type narrowing (`SearchFilter` enum with encoded tokens), pagination via continuation tokens, and a cancel button with animated transitions.

**Current limitations:**

- No search history persistence — previous queries are lost on view dismissal
- Suggestion fetch errors fail silently with no user feedback
- Album, artist, and playlist results appear in the result model but only song rows are rendered in the current UI
- No voice search or barcode/QR scanning

**Quality:** ⭐⭐⭐⭐

## Music Playback

**What it does:** Streams audio via the InnerTube ANDROID_VR client. The `AudioEngine` resolves stream URLs lazily through a configurable `streamURLResolver` closure, selects the best `audio/mp4` format based on the user's quality preference (64/128/256 kbps), and plays via `AVPlayer` with custom HTTP headers (User-Agent, Origin, Referer).

**Current limitations:**

- Only `audio/mp4` formats are supported — WebM/Opus streams are skipped (AVPlayer limitation)
- No retry or fallback mechanism if stream URL resolution fails
- No streaming quality indicator in the UI
- Stream URLs can expire, requiring re-resolution with no automatic handling

**Quality:** ⭐⭐⭐

## Queue Management

**What it does:** Maintains an ordered playback queue with full control: next, previous, add, remove, and reorder (via `IndexSet`). Shuffle mode picks a random index from the queue. Repeat supports three modes: off, repeat all, and repeat one. Previous track restarts the current song if more than 3 seconds have elapsed.

**Current limitations:**

- Shuffle uses a naive random index — no Fisher-Yates or history-aware shuffle
- No "Up Next" vs "Queue" distinction
- Queue is not persisted across app launches
- No drag-to-reorder UI exposed in the current views

**Quality:** ⭐⭐⭐

## Mini Player

**What it does:** Persistent bottom bar that appears when a track is loaded. Shows a thin progress bar (2 px, primary color), song thumbnail (44×44), title, artist name, play/pause button, and next button. Tapping the bar opens the full player. Displays a buffering spinner during stream resolution and a red error icon with tooltip on playback errors.

**Current limitations:**

- No swipe gestures (e.g., swipe to skip)
- No previous track button — only next
- Progress bar is not interactive (no tap-to-seek)
- Glass morphism background may have performance implications on older devices

**Quality:** ⭐⭐⭐⭐

## Full Player

**What it does:** Full-screen player presented as a sheet with drag-to-dismiss (threshold: 150 pt). Features a blurred thumbnail background with gradient overlay, large artwork with shadow, song title and artist, a seekable progress slider with time labels, and a full control row: shuffle, previous, play/pause, next, and repeat. Shuffle and repeat buttons change color to indicate active state.

**Current limitations:**

- No lyrics display integrated into this view yet (lyrics toggle exists in the view model but is not wired to the full player UI)
- No volume slider or AirPlay picker
- No song info sheet (album, artist, add-to-playlist actions)
- Artwork uses a simple `AsyncImage` with no caching strategy beyond URL cache
- No animation on track change

**Quality:** ⭐⭐⭐

## Artist Page

**What it does:** Displays an artist profile with a full-width header image (300 pt height) overlaid with a dark gradient, artist name, and subscriber count. Below the header, the top 5 songs are listed as tappable rows. An albums section shows horizontally scrollable cards (150×150) with title and year, each navigating to the album detail page.

**Current limitations:**

- Only the first 5 songs are shown with no "Show All" option
- Singles section exists in the data model (`Artist.singles`) but is not rendered
- No artist bio or description
- No error state UI — only loading spinner or content
- No "Play All" or "Shuffle" button for the artist's catalog

**Quality:** ⭐⭐⭐

## Album Page

**What it does:** Shows album artwork (220×220), title, artist name, year, and total duration. Provides "Play" and "Shuffle" action buttons. The full tracklist is displayed in a `LazyVStack` with index numbers, and tapping any song plays it within the album queue context.

**Current limitations:**

- No error state UI beyond loading spinner
- No "Add to Library" or "Add to Playlist" functionality
- No album description or credits
- Year and duration are optional and may not always be available from InnerTube

**Quality:** ⭐⭐⭐⭐

## Library

**What it does:** Local playlist management with full CRUD operations. Users can create playlists via an alert dialog with a text field, view all playlists in a list with thumbnails and song counts, navigate to playlist detail, and delete playlists via swipe. A "Recently Played" section shows songs the user has listened to.

**Current limitations:**

- No playlist editing (rename, reorder songs, remove songs)
- No playlist artwork customization
- Delete operations use `try?` and fail silently
- No import/export functionality
- Recently played list has no persistence guarantees mentioned
- No sorting or filtering options for playlists

**Quality:** ⭐⭐⭐

## Settings

**What it does:** Provides configuration for audio quality (Low 64 kbps / Medium 128 kbps / High 256 kbps), content region (VN, US, JP, KR), and language (Vietnamese, English). Includes cache size display with a clear cache button, account status with sign-in/sign-out, and a static version display (1.0.0). Settings are persisted via `UserDefaults` and broadcast changes through `Notification.Name.settingsChanged`.

**Current limitations:**

- Version is hardcoded, not read from the bundle
- Region and language options are limited to 4 regions and 2 languages
- No theme (dark/light) toggle
- No data export or privacy controls
- Audio quality changes do not affect the currently playing stream — only subsequent plays

**Quality:** ⭐⭐⭐

## YouTube Login

**What it does:** Optional Google Sign-In flow using a `WKWebView` that loads the Google ServiceLogin page scoped to YouTube. After the user authenticates and is redirected to `music.youtube.com` or `youtube.com`, the coordinator extracts `SAPISID` and `SID` cookies from the web view's non-persistent data store and passes them to `YouTubeAuthManager` for authenticated API requests.

**Current limitations:**

- Uses a non-persistent data store, so login state is cookie-based only
- No OAuth 2.0 token flow — relies on browser cookies
- Cookie extraction is fragile and depends on Google's redirect behavior
- No automatic re-authentication when cookies expire
- Account name display depends on the auth manager's parsing

**Quality:** ⭐⭐

## Now Playing

**What it does:** Integrates with `MPNowPlayingInfoCenter` via a `NowPlayingManager` to display song metadata (title, artist, artwork, duration, elapsed time, playback rate) on the lock screen and in Control Center. Remote commands (play, pause, next, previous, seek) are handled via `RemoteCommandManager` and mapped to `AudioEngine` methods.

**Current limitations:**

- Artwork is loaded from the thumbnail URL but caching behavior is unclear
- No rating or like/dislike integration with Now Playing controls
- Seek command granularity depends on the system default

**Quality:** ⭐⭐⭐⭐

## Lyrics

**What it does:** Fetches synced lyrics from LrcLib based on song title, artist name, and duration via `GetLyricsUseCase`. Lyrics are stored as `SyncedLyrics` in the `PlayerViewModel` with a loading state. The view model exposes an `isLyricsVisible` toggle for future UI integration.

**Current limitations:**

- Lyrics fetch errors fail silently — no "lyrics not found" feedback to the user
- Lyrics UI is not yet integrated into the full player view
- Only LrcLib is supported — no fallback providers
- Matching depends on exact title/artist strings which may differ from LrcLib's catalog

**Quality:** ⭐⭐

## Background Audio

**What it does:** The `AVAudioSession` is configured with the `.playback` category, enabling audio to continue when the app is backgrounded. The `AudioEngine` handles audio interruptions (phone calls, alarms) by pausing on interruption begin and resuming if the `.shouldResume` option is set. Route changes (e.g., headphone disconnect) automatically pause playback.

**Current limitations:**

- No background fetch for preloading the next track
- No handling of audio focus loss from other apps beyond system interruptions
- No battery optimization for long background playback sessions

**Quality:** ⭐⭐⭐⭐
