# LovelyMusic Technical Stack

LovelyMusic is a native iOS music streaming app built entirely with Apple frameworks.
It uses YouTube Music's private InnerTube API to search, browse, and stream audio content,
while LrcLib provides synchronized lyrics.

## Frameworks and Libraries

LovelyMusic ships with **zero third-party dependencies**. Every feature is implemented using
first-party Apple frameworks.

### SwiftUI (iOS 18+)

- Declarative UI with `@Observable` macro (Observation framework)
- Navigation via `NavigationStack` and `NavigationLink`
- Minimum deployment target: **iOS 18.0**
- Swift version: **5.9**

### AVFoundation

- `AVPlayer` / `AVPlayerItem` / `AVURLAsset` for audio playback
- `AVAudioSession` configured with `.playback` category for background audio
- Custom HTTP header injection via `AVURLAssetHTTPHeaderFieldsKey`

### MediaPlayer

- `MPNowPlayingInfoCenter` for Lock Screen / Control Center metadata
- `MPRemoteCommandCenter` for play, pause, next, previous, and seek commands

### CryptoKit

- `Insecure.SHA1` for SAPISIDHASH generation (YouTube authenticated requests)

### WebKit

- `WKWebView` for YouTube login flow (cookie extraction)

### Security (Keychain)

- `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` for auth cookie persistence

### Foundation

- `URLSession` for all HTTP networking
- `JSONEncoder` / `JSONDecoder` for InnerTube request/response serialization
- `HTTPCookieStorage.shared` for automatic cookie management

## YouTube InnerTube API Deep Dive

### What Is InnerTube?

InnerTube is YouTube's internal JSON-RPC API that powers all YouTube clients — web, mobile,
TV, and VR. Unlike the official YouTube Data API v3, InnerTube provides access to streaming
URLs, full search results with metadata, and browsing of YouTube Music's catalog without
quota limits or OAuth registration.

All InnerTube requests are `POST` requests with a JSON body containing a `context` object
that identifies the client. Different client identities unlock different capabilities and
face different restrictions.

### Base URLs

LovelyMusic uses two different YouTube domains depending on the operation:

| Domain | Used For | Reason |
|---|---|---|
| `music.youtube.com` | Search, browse, next, suggestions, queue | YouTube Music-specific responses with music metadata |
| `www.youtube.com` | Player (stream URL resolution) | ANDROID_VR client is blocked on the music domain |

### Client Types and Status

The app defines six client configurations. Each has a different `clientName`, `clientId`,
API key, and user agent:

| Client | ID | Status | Usage |
|---|---|---|---|
| `WEB_REMIX` | 67 | ✅ Active | Search, browse, next, suggestions, queue |
| `IOS` | 5 | ⚠️ Blocked for player | Defined but not used for streaming (returns 403) |
| `ANDROID_VR` | 28 | ✅ Active | Player endpoint (stream URL resolution) |
| `TVHTML5_SIMPLY_EMBEDDED_PLAYER` | 85 | ⚠️ Limited | Defined as fallback |
| `ANDROID_MUSIC` | 21 | ⚠️ Limited | Defined as fallback |
| `WEB` | 1 | ⚠️ Limited | Defined as fallback |

### Why ANDROID_VR?

YouTube has progressively blocked most client types from returning streaming URLs in the
`player` endpoint. As of 2024, the `IOS`, `ANDROID`, and `WEB` clients either return
`403` errors or encrypted signatures that require a JavaScript interpreter to decrypt.

The **ANDROID_VR** client (Oculus Quest) is one of the few remaining clients that returns
direct, unencrypted streaming URLs. LovelyMusic leverages this by:

1. Identifying as an Oculus Quest 3 running Android 12L
2. Setting the user agent to `com.google.android.apps.youtube.vr.oculus/1.65.10`
3. Sending requests to `www.youtube.com` (not `music.youtube.com`)
4. Including session cookies obtained from a prior webpage visit

### Session Cookie Flow

YouTube validates player requests using cookies. The flow is:

```text
1. App visits https://www.youtube.com/watch?v={videoId}
   └─ Pre-populates PREF and SOCS cookies
   └─ Uses Safari-like User-Agent
   └─ YouTube responds with Set-Cookie headers (VISITOR_INFO1_LIVE, YSC, etc.)

2. App extracts visitorData from the HTML response
   └─ Parses "visitorData":"..." from the page source
   └─ Stores it for use in subsequent API requests

3. App sends player request to www.youtube.com/youtubei/v1/player
   └─ Includes all session cookies in Cookie header
   └─ Includes visitorData in X-Goog-Visitor-Id header
   └─ Uses ANDROID_VR client identity
   └─ YouTube returns streaming URLs
```

The session is initialized lazily on the first `playerWithSession()` call and reused for
subsequent requests. If a request fails with a non-OK playability status, the session is
reset and retried once.

### Why Different Domains for Different Operations?

- **`music.youtube.com`** returns YouTube Music-specific response structures with music
  metadata (album art, artist pages, music shelves, carousels). The `WEB_REMIX` client
  is designed for this domain.
- **`www.youtube.com`** is required for the ANDROID_VR player because YouTube blocks VR
  client requests on the music subdomain. The player endpoint on `www.youtube.com` returns
  identical streaming data regardless of whether the content is a music video.

## Audio Playback Stack

### AVPlayer Pipeline

```text
Stream URL (googlevideo.com)
    │
    ▼
AVURLAsset(url:, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    │
    ▼
AVPlayerItem(asset:)
    │
    ▼
AVPlayer(playerItem:)
    │
    ▼
AVAudioSession(.playback)
```

### Why Custom Headers Are Required

YouTube's CDN (`googlevideo.com`) validates the `User-Agent`, `Origin`, and `Referer`
headers on streaming URLs. If these headers do not match the client that originally
requested the URL, the CDN returns `403 Forbidden`.

LovelyMusic injects these headers into `AVURLAsset`:

```swift
let headers: [String: String] = [
    "User-Agent": "com.google.android.apps.youtube.vr.oculus/1.65.10 ...",
    "Origin": "https://www.youtube.com",
    "Referer": "https://www.youtube.com/"
]

let asset = AVURLAsset(url: url, options: [
    "AVURLAssetHTTPHeaderFieldsKey": headers
])
```

### Format Compatibility

YouTube provides audio in two container formats:

| Format | MIME Type | Codec | AVPlayer Support |
|---|---|---|---|
| MP4 (AAC) | `audio/mp4` | AAC | ✅ Supported |
| WebM (Opus) | `audio/webm` | Opus | ❌ Not supported |

The `StreamingData.bestAudioFormat` property filters exclusively for `audio/mp4` formats,
then selects the highest bitrate within the user's quality preference:

| Quality | Max Bitrate |
|---|---|
| Low | 64 kbps |
| Medium | 128 kbps |
| High | 256 kbps |

### Audio Session Configuration

```swift
try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
try AVAudioSession.sharedInstance().setActive(true)
```

The `.playback` category enables background audio. The app's `Info.plist` includes the
`audio` background mode (`UIBackgroundModes: ["audio"]`).

### Now Playing Integration

The `NowPlayingManager` updates `MPNowPlayingInfoCenter.default().nowPlayingInfo` with:

- Title, artist name
- Album artwork (async thumbnail download)
- Duration, elapsed time
- Playback rate (0.0 paused, 1.0 playing)

### Remote Command Handling

The `RemoteCommandManager` registers handlers on `MPRemoteCommandCenter.shared()`:

- **Play / Pause** — toggles playback
- **Next Track** — advances queue
- **Previous Track** — restarts track (if > 3s) or goes to previous
- **Seek** — seeks to specified time

Audio interruptions (phone calls) and route changes (headphone disconnect) are handled
via `AVAudioSession.interruptionNotification` and `routeChangeNotification`.

## Authentication

### Anonymous Session (Default)

By default, LovelyMusic works without any YouTube login. The anonymous session flow:

1. Pre-populate `PREF` and `SOCS` cookies
2. Visit a YouTube watch page to obtain `VISITOR_INFO1_LIVE` and `YSC` cookies
3. Extract `visitorData` from the page HTML
4. Include cookies and visitorData in subsequent API requests

This provides full search, browse, and playback functionality.

### YouTube Login (Optional)

For personalized recommendations and library access:

1. A `WKWebView` loads `https://accounts.google.com`
2. User completes the Google login flow
3. The app extracts authentication cookies from the web view:
   - `SAPISID`, `SID`, `HSID`, `SSID`, `APISID`
   - `LOGIN_INFO`, `__Secure-1PSID`, `__Secure-3PSID`
   - `VISITOR_INFO1_LIVE`
4. Cookies are serialized and stored in the iOS Keychain
5. On subsequent launches, cookies are restored from Keychain

### SAPISIDHASH Header Generation

Authenticated requests require a `SAPISIDHASH` authorization header:

```text
SAPISIDHASH = SHA1("{timestamp} {SAPISID} {origin}")

Authorization: SAPISIDHASH {timestamp}_{hash}
```

The hash is computed using `CryptoKit.Insecure.SHA1`:

```swift
let input = "\(timestamp) \(sapisid) https://music.youtube.com"
let hash = Insecure.SHA1.hash(data: input.data(using: .utf8)!)
```

### Keychain Storage

Auth cookies are stored under the service identifier `com.lovelymusic.youtube-auth`
using the Security framework (`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`).
This ensures credentials persist across app launches and are protected by the device
passcode / biometrics.

## Lyrics

### LrcLib Integration

LovelyMusic fetches synchronized lyrics from [LrcLib](https://lrclib.net), a free,
open-source lyrics API.

**Endpoint:** `GET https://lrclib.net/api/get`

**Query parameters:**

- `track_name` — song title
- `artist_name` — artist name
- `duration` — track duration in seconds (optional, improves matching accuracy)

**Response priority:**

1. **Synced lyrics** (`syncedLyrics` field) — LRC format with timestamps
2. **Plain lyrics** (`plainLyrics` field) — fallback with estimated timing

### LRC Format

Synced lyrics use the standard LRC timestamp format:

```text
[00:15.30] First line of lyrics
[00:19.85] Second line of lyrics
[00:24.10] Third line of lyrics
```

Each line is parsed into a `LyricLine(time: Double, text: String)` for real-time
display synchronized with `AVPlayer`'s current playback position.

## Build Configuration

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) with `project.yml`:

- **Bundle ID:** `com.lovelymusic.app`
- **Deployment target:** iOS 18.0
- **Swift version:** 5.9
- **Device families:** iPhone and iPad
- **Background modes:** Audio
- **Orientations:** Portrait (iPhone), Portrait + Landscape (iPad)
- **ATS:** `NSAllowsArbitraryLoads: true` (required for `googlevideo.com` CDN URLs)

## In-App Purchases (StoreKit 2)

LovelyMusic uses **StoreKit 2** for premium monetization — Apple's modern, Swift-native
purchase API with built-in transaction verification and async/await support.

### Product Catalog

| Product | Type | Price | Product ID |
| --- | --- | --- | --- |
| Premium Monthly | Auto-Renewable Subscription | $4.99/mo | `com.lovelymusic.premium.monthly` |
| Premium Yearly | Auto-Renewable Subscription | $29.99/yr (save 50%) | `com.lovelymusic.premium.yearly` |
| Premium Lifetime | Non-Consumable | $79.99 (one-time) | `com.lovelymusic.premium.lifetime.v2` |

### Subscription Group

All subscriptions belong to the group **"LovelyMusic Premium"** (ID: `21584156`).
The yearly plan has the highest `groupNumber` (1), making it the default upgrade path.

### Implementation Details

- **Transaction verification:** Uses `Transaction.currentEntitlements` and JWS verification
- **Entitlement checking:** `PremiumManager` provides `@Observable` `isPremium` state
- **Paywall UI:** `PaywallView` displays all plans with native SwiftUI
- **Receipt handling:** StoreKit 2 handles receipt validation automatically (no server needed)
- **Subscription management:** Deep link to `https://apps.apple.com/account/subscriptions`

### StoreKit Configuration

The file `LovelyMusic/Resources/LovelyMusic.storekit` (StoreKit Configuration v4.0) enables
local testing in Xcode without an App Store Connect sandbox. It defines all products,
subscription groups, and error simulation toggles for testing purchase flows.
