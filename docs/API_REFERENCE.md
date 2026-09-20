# LovelyMusic API Reference

This document covers every HTTP endpoint that LovelyMusic uses, including request/response
structures, headers, and error handling.

## Common Headers

All InnerTube endpoints share a common set of request headers:

```http
Content-Type: application/json
X-Goog-Api-Format-Version: 1
X-YouTube-Client-Name: {clientId}
X-YouTube-Client-Version: {clientVersion}
User-Agent: {client-specific user agent}
x-origin: https://music.youtube.com
```

## Common Context Object

Every InnerTube request body includes a `context` object:

```json
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20220606.03.00",
      "gl": "US",
      "hl": "en",
      "visitorData": "CgtsZG1ySnZiQWtSbyiMjuGSBg%3D%3D"
    }
  }
}
```

The `gl` (geolocation) and `hl` (host language) values are derived from the device locale
via `Locale.current`.

## InnerTube Client Configurations

| Client | clientName | clientId | clientVersion | API Key |
|---|---|---|---|---|
| WEB_REMIX | `WEB_REMIX` | `67` | `1.20220606.03.00` | `AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30` |
| IOS | `IOS` | `5` | `19.29.1` | `AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc` |
| ANDROID_VR | `ANDROID_VR` | `28` | `1.65.10` | `AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w` |
| TVHTML5 | `TVHTML5_SIMPLY_EMBEDDED_PLAYER` | `85` | `2.0` | `AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8` |
| ANDROID_MUSIC | `ANDROID_MUSIC` | `21` | `5.01` | `AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI` |
| WEB | `WEB` | `1` | `2.2021111` | `AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30` |

## Error Handling

All InnerTube endpoints use the same error model:

```swift
enum InnerTubeError: Error {
    case httpError(statusCode: Int)    // Non-2xx HTTP response
    case decodingError(Error)          // JSON decode failure
    case invalidURL                    // Malformed URL
    case noStreamAvailable             // No compatible audio format
}
```

HTTP status codes outside `200...299` throw `httpError`. The app does **not** retry
on HTTP errors except for the player endpoint (see endpoint 4).

---

## Endpoint 1: Search

Search YouTube Music for songs, albums, artists, and playlists.

### Request

```http
POST https://music.youtube.com/youtubei/v1/search?key={apiKey}&prettyPrint=false
```

**Client:** `WEB_REMIX`

**Headers:**

```http
Content-Type: application/json
X-YouTube-Client-Name: 67
X-YouTube-Client-Version: 1.20220606.03.00
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) ...
Referer: https://music.youtube.com/
x-origin: https://music.youtube.com
```

**Body:**

```json
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20220606.03.00",
      "gl": "US",
      "hl": "en",
      "visitorData": "CgtsZG1ySnZiQWtSbyiMjuGSBg%3D%3D"
    }
  },
  "query": "never gonna give you up",
  "params": null
}
```

### Search Filter Parameters

The `params` field accepts base64-encoded filter values:

| Filter | `params` Value (URL-encoded) | Description |
|---|---|---|
| Songs | `EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D` | Filter results to songs only |
| Albums | `EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D` | Filter results to albums only |
| Artists | `EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D` | Filter results to artists only |
| Playlists | `EgWKAQIoAWoKEAkQBRAKEAMQBA%3D%3D` | Filter results to playlists only |

When `params` is `null`, YouTube Music returns a mixed result set with all content types.

### Pagination (Continuation)

For paginated results, append continuation parameters as query items:

```http
POST https://music.youtube.com/youtubei/v1/search?key={apiKey}&prettyPrint=false&continuation={token}&ctoken={token}
```

### Response Structure

```json
{
  "contents": {
    "tabbedSearchResultsRenderer": {
      "tabs": [{
        "tabRenderer": {
          "content": {
            "sectionListRenderer": {
              "contents": [{
                "musicShelfRenderer": {
                  "title": { "runs": [{ "text": "Songs" }] },
                  "contents": [{
                    "musicResponsiveListItemRenderer": {
                      "flexColumns": [...],
                      "fixedColumns": [...],
                      "thumbnail": { ... },
                      "playlistItemData": { "videoId": "dQw4w9WgXcQ" },
                      "navigationEndpoint": { ... }
                    }
                  }],
                  "continuations": [{
                    "nextContinuationData": {
                      "continuation": "..."
                    }
                  }]
                }
              }]
            }
          }
        }
      }]
    }
  }
}
```

**Key response fields:**

- `musicShelfRenderer.title.runs[0].text` — category name (Songs, Albums, Artists, Playlists)
- `musicResponsiveListItemRenderer.flexColumns` — title (column 0), artist/album (column 1)
- `musicResponsiveListItemRenderer.fixedColumns` — duration text
- `playlistItemData.videoId` — unique video identifier
- `continuations[0].nextContinuationData.continuation` — pagination token

### Response Mapping

The `SearchResponseMapper` detects the category from the shelf title and maps each
`musicResponsiveListItemRenderer` to a `Song`, `Album`, `Artist`, or `Playlist` entity.

---

## Endpoint 2: Browse

Fetch home feed, artist pages, album details, and playlist contents.

### Request

```http
POST https://music.youtube.com/youtubei/v1/browse?key={apiKey}&prettyPrint=false
```

**Client:** `WEB_REMIX`

**Headers:** Same as Search endpoint.

**Body (Home Feed):**

```json
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20220606.03.00",
      "gl": "US",
      "hl": "en",
      "visitorData": "..."
    }
  },
  "browseId": "FEmusic_home"
}
```

**Body (Artist Page):**

```json
{
  "context": { ... },
  "browseId": "UCuAXFkgsw1L7xaCfnd5JJOw"
}
```

**Body (Album Page):**

```json
{
  "context": { ... },
  "browseId": "MPREb_..."
}
```

### Browse IDs

| Content Type | browseId Format | Example |
|---|---|---|
| Home feed | `FEmusic_home` | `FEmusic_home` |
| Artist | `UC{channelId}` | `UCuAXFkgsw1L7xaCfnd5JJOw` |
| Album | `MPREb_{id}` | `MPREb_K1MNMxx5RW5hQ` |
| Playlist | `VL{playlistId}` | `VLRDCLAK5uy_k...` |

### Pagination (Continuation)

```http
POST ...?key={apiKey}&prettyPrint=false&continuation={token}&ctoken={token}&type=next
```

### Response Structure (Home Feed)

```json
{
  "contents": {
    "singleColumnBrowseResultsRenderer": {
      "tabs": [{
        "tabRenderer": {
          "content": {
            "sectionListRenderer": {
              "contents": [{
                "musicCarouselShelfRenderer": {
                  "header": {
                    "musicCarouselShelfBasicHeaderRenderer": {
                      "title": { "runs": [{ "text": "Quick picks" }] }
                    }
                  },
                  "contents": [{
                    "musicTwoRowItemRenderer": {
                      "title": { "runs": [{ "text": "Song Title" }] },
                      "subtitle": { "runs": [{ "text": "Artist" }] },
                      "thumbnail": { ... },
                      "navigationEndpoint": {
                        "browseEndpoint": {
                          "browseId": "MPREb_...",
                          "browseEndpointContextSupportedConfigs": {
                            "browseEndpointContextMusicConfig": {
                              "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                            }
                          }
                        }
                      }
                    }
                  }]
                }
              }]
            }
          }
        }
      }]
    }
  }
}
```

**Key page types in navigation endpoints:**

- `MUSIC_PAGE_TYPE_ALBUM`
- `MUSIC_PAGE_TYPE_ARTIST`
- `MUSIC_PAGE_TYPE_PLAYLIST`

### Response Structure (Artist Page)

The artist page includes:

- `header.musicImmersiveHeaderRenderer` — artist name, thumbnail, subscriber count
- `contents.singleColumnBrowseResultsRenderer.tabs[0]` — sections containing:
  - `musicShelfRenderer` — top songs
  - `musicCarouselShelfRenderer` — albums, singles, related artists

### Response Structure (Album Page)

The album page includes:

- `header.musicDetailHeaderRenderer` — album title, artist (via subtitle runs), year, thumbnail
- `musicShelfRenderer.contents[]` — track listing with `playlistItemData.videoId`

### Response Mapping

- `BrowseResponseMapper.mapHome()` — extracts `MusicSection` items from carousels
- `BrowseResponseMapper.mapArtist()` — extracts songs, albums, and singles
- `BrowseResponseMapper.mapAlbum()` — extracts track listing with durations
- `BrowseResponseMapper.mapPlaylist()` — extracts playlist songs

---

## Endpoint 3: Next (Up Next / Related)

Fetch the "Up Next" queue and related tracks for a currently playing video.

### Request

```http
POST https://music.youtube.com/youtubei/v1/next?key={apiKey}&prettyPrint=false
```

**Client:** `WEB_REMIX`

**Headers:** Same as Search, plus `Cookie` header when authenticated.

**Body:**

```json
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20220606.03.00",
      "gl": "US",
      "hl": "en",
      "visitorData": "..."
    }
  },
  "videoId": "dQw4w9WgXcQ",
  "playlistId": "RDAMVMdQw4w9WgXcQ",
  "playlistSetVideoId": null,
  "index": null,
  "params": null,
  "continuation": null
}
```

### Response Structure

```json
{
  "contents": {
    "singleColumnMusicWatchNextResultsRenderer": {
      "tabbedRenderer": {
        "watchNextTabbedResultsRenderer": {
          "tabs": [{
            "tabRenderer": {
              "content": {
                "musicQueueRenderer": {
                  "content": {
                    "playlistPanelRenderer": {
                      "contents": [{
                        "playlistPanelVideoRenderer": {
                          "title": { "runs": [{ "text": "..." }] },
                          "longBylineText": { "runs": [...] },
                          "shortBylineText": { "runs": [...] },
                          "thumbnail": { "thumbnails": [...] },
                          "videoId": "...",
                          "lengthText": { "runs": [{ "text": "3:33" }] },
                          "selected": false
                        }
                      }],
                      "playlistId": "RDAMVM..."
                    }
                  }
                }
              }
            }
          }]
        }
      }
    }
  }
}
```

**Key response fields:**

- `playlistPanelVideoRenderer.videoId` — video ID for each queued track
- `playlistPanelVideoRenderer.title` — track title
- `playlistPanelVideoRenderer.shortBylineText` — artist name
- `playlistPanelVideoRenderer.lengthText` — duration (e.g., `"3:33"`)
- `playlistPanelVideoRenderer.selected` — whether this is the currently playing track

### Response Mapping

`NextResponseMapper.map()` extracts `Song` entities from the first tab's
`playlistPanelRenderer.contents`.

---

## Endpoint 4: Player (Stream URL Resolution)

Resolve a video ID to a playable audio stream URL using the ANDROID_VR client.

### Session Initialization

Before calling the player endpoint, the app initializes a session by visiting the
YouTube watch page:

```http
GET https://www.youtube.com/watch?v={videoId}&bpctr=9999999999&has_verified=1
```

**Headers:**

```http
User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
Accept-Language: en-us,en;q=0.5
```

**Pre-populated cookies:**

```text
PREF=hl=en&tz=UTC
SOCS=CAI
```

This request yields additional cookies (`VISITOR_INFO1_LIVE`, `YSC`, etc.) and the
`visitorData` string is extracted from the HTML response body.

### Player Request

```http
POST https://www.youtube.com/youtubei/v1/player?prettyPrint=false
```

> **Note:** This uses `www.youtube.com`, NOT `music.youtube.com`. No `key` parameter is
> sent for the ANDROID_VR player request.

**Client:** `ANDROID_VR`

**Headers:**

```http
Content-Type: application/json
X-Youtube-Client-Name: 28
X-Youtube-Client-Version: 1.65.10
Origin: https://www.youtube.com
User-Agent: com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip
X-Goog-Visitor-Id: {visitorData}
Cookie: PREF=hl=en&tz=UTC; SOCS=CAI; VISITOR_INFO1_LIVE=...; YSC=...
```

**Body:**

```json
{
  "context": {
    "client": {
      "clientName": "ANDROID_VR",
      "clientVersion": "1.65.10",
      "deviceMake": "Oculus",
      "deviceModel": "Quest 3",
      "osName": "Android",
      "osVersion": "12L",
      "androidSdkVersion": 32,
      "hl": "en",
      "gl": "US",
      "visitorData": "..."
    }
  },
  "videoId": "dQw4w9WgXcQ",
  "contentCheckOk": true,
  "racyCheckOk": true,
  "playlistId": null
}
```

### Response Structure

```json
{
  "playabilityStatus": {
    "status": "OK",
    "reason": null
  },
  "streamingData": {
    "formats": [...],
    "adaptiveFormats": [
      {
        "itag": 140,
        "url": "https://rr1---sn-....googlevideo.com/videoplayback?...",
        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
        "bitrate": 130859,
        "contentLength": "3889277",
        "quality": "tiny",
        "audioQuality": "AUDIO_QUALITY_MEDIUM",
        "audioSampleRate": "44100",
        "audioChannels": 2,
        "approxDurationMs": "213000"
      },
      {
        "itag": 251,
        "url": "https://rr1---sn-....googlevideo.com/videoplayback?...",
        "mimeType": "audio/webm; codecs=\"opus\"",
        "bitrate": 143859,
        "audioQuality": "AUDIO_QUALITY_MEDIUM",
        "audioSampleRate": "48000",
        "audioChannels": 2
      }
    ],
    "expiresInSeconds": "21540"
  },
  "videoDetails": {
    "videoId": "dQw4w9WgXcQ",
    "title": "Rick Astley - Never Gonna Give You Up",
    "lengthSeconds": "212",
    "channelId": "UCuAXFkgsw1L7xaCfnd5JJOw",
    "author": "Rick Astley",
    "thumbnail": {
      "thumbnails": [
        { "url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/...", "width": 120, "height": 90 }
      ]
    }
  }
}
```

### Stream Format Selection

The `StreamingData.bestAudioFormat` property:

1. Filters `adaptiveFormats` to only `audio/mp4` (AAC) — WebM/Opus is not supported by AVPlayer
2. Filters by user quality preference (max bitrate: 64k / 128k / 256k)
3. Selects the highest bitrate format within the limit
4. Falls back to the best available `audio/mp4` format if none are under the limit

Common audio itags:

| itag | MIME Type | Codec | Bitrate | Selected? |
|---|---|---|---|---|
| 139 | `audio/mp4` | AAC | ~48 kbps | Low quality |
| 140 | `audio/mp4` | AAC | ~128 kbps | Medium quality |
| 141 | `audio/mp4` | AAC | ~256 kbps | High quality |
| 249 | `audio/webm` | Opus | ~50 kbps | ❌ Skipped |
| 250 | `audio/webm` | Opus | ~70 kbps | ❌ Skipped |
| 251 | `audio/webm` | Opus | ~160 kbps | ❌ Skipped |

### Retry Logic

The `PlayerRepository` implements a retry strategy:

```text
1. Call playerWithSession(videoId:)
2. Check playabilityStatus.status
3. If NOT "OK":
   a. Reset session (clear cookies, force re-initialization)
   b. Call playerWithSession(videoId:) again
   c. If still NOT "OK" → throw noStreamAvailable
4. Map streamingData → StreamingData domain model
5. Select bestAudioFormat
6. Return URL or throw noStreamAvailable
```

---

## Endpoint 5: Search Suggestions

Fetch autocomplete suggestions for a search query.

### Request

```http
POST https://music.youtube.com/youtubei/v1/music/get_search_suggestions?key={apiKey}&prettyPrint=false
```

**Client:** `WEB_REMIX`

**Headers:** Same as Search endpoint.

**Body:**

```json
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20220606.03.00",
      "gl": "US",
      "hl": "en",
      "visitorData": "..."
    }
  },
  "input": "never gonna"
}
```

### Response Structure

```json
{
  "contents": [{
    "searchSuggestionsSectionRenderer": {
      "contents": [{
        "searchSuggestionRenderer": {
          "suggestion": {
            "runs": [
              { "text": "never gonna " },
              { "text": "give you up" }
            ]
          },
          "navigationEndpoint": {
            "searchEndpoint": {
              "query": "never gonna give you up"
            }
          }
        }
      }]
    }
  }]
}
```

**Key response fields:**

- `searchSuggestionRenderer.suggestion.runs` — concatenated to form the full suggestion text
- `searchSuggestionRenderer.navigationEndpoint.searchEndpoint.query` — the full query string

### Response Mapping

`SuggestionsMapper.map()` extracts an array of `String` suggestions by concatenating
each suggestion's `runs[].text`.

---

## Endpoint 6: Get Queue

Retrieve track details for one or more video IDs or an entire playlist.

### Request

```http
POST https://music.youtube.com/youtubei/v1/music/get_queue?key={apiKey}&prettyPrint=false
```

**Client:** `WEB_REMIX`

**Headers:** Same as Search endpoint.

**Body (by video IDs):**

```json
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20220606.03.00",
      "gl": "US",
      "hl": "en",
      "visitorData": "..."
    }
  },
  "videoIds": ["dQw4w9WgXcQ", "9bZkp7q19f0"],
  "playlistId": null
}
```

**Body (by playlist ID):**

```json
{
  "context": { ... },
  "videoIds": null,
  "playlistId": "RDAMVM..."
}
```

### Response Structure

The response contains `playlistPanelVideoRenderer` items (same structure as the Next
endpoint) with track title, artist, thumbnail, video ID, and duration.

---

## Endpoint 7: Session Initialization (Watch Page)

This is not an API endpoint but an HTML page visit used to establish cookies for the
player endpoint.

### Request

```http
GET https://www.youtube.com/watch?v={videoId}&bpctr=9999999999&has_verified=1
```

**Headers:**

```http
User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
Accept-Language: en-us,en;q=0.5
```

**Pre-populated cookies (set before request):**

| Cookie | Value | Purpose |
|---|---|---|
| `PREF` | `hl=en&tz=UTC` | Language/timezone preference |
| `SOCS` | `CAI` | Consent acknowledgement |

### Response

- **Status:** `200 OK`
- **Content-Type:** `text/html`
- **Set-Cookie headers:** `VISITOR_INFO1_LIVE`, `YSC`, and others
- **Body:** HTML containing `"visitorData":"..."` which is extracted via string parsing

### Extracted Data

- **Cookies** — stored in `HTTPCookieStorage.shared` and included in subsequent player requests
- **visitorData** — extracted from the HTML, used as `X-Goog-Visitor-Id` header and in the
  client context body

---

## Endpoint 8: Lyrics (LrcLib)

Fetch synchronized lyrics from the LrcLib API.

### Request

```http
GET https://lrclib.net/api/get?track_name={title}&artist_name={artist}&duration={seconds}
```

**Headers:**

```http
User-Agent: LovelyMusic/1.0
```

**Query Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `track_name` | Yes | Song title |
| `artist_name` | Yes | Artist name |
| `duration` | No | Track duration in seconds (improves match accuracy) |

### Response Structure

```json
{
  "trackName": "Never Gonna Give You Up",
  "artistName": "Rick Astley",
  "duration": 212.0,
  "syncedLyrics": "[00:15.30] We're no strangers to love\n[00:18.40] You know the rules and so do I\n...",
  "plainLyrics": "We're no strangers to love\nYou know the rules and so do I\n..."
}
```

**Key response fields:**

- `syncedLyrics` — LRC-format string with `[mm:ss.xx]` timestamps (preferred)
- `plainLyrics` — plain text fallback (displayed with estimated 3-second spacing)
- `trackName` — matched track name
- `artistName` — matched artist name
- `duration` — matched track duration

### Response Mapping

The `LrcLibService` handles two cases:

1. **Synced lyrics available:** parse LRC format into `[LyricLine(time:, text:)]`
2. **Plain lyrics only:** split by newlines, assign each line a 3-second offset
3. **No match:** return `nil`

### Error Handling

- Non-200 HTTP status → return `nil` (no lyrics available)
- Decode failure → throw error
- Empty `syncedLyrics` and `plainLyrics` → return `nil`

---

## Appendix: Request Body Swift Types

### SearchBody

```swift
struct SearchBody: Codable {
    let context: InnerTubeContext
    let query: String?
    let params: String?
}
```

### BrowseBody

```swift
struct BrowseBody: Codable {
    let context: InnerTubeContext
    let browseId: String?
    let params: String?
}
```

### NextBody

```swift
struct NextBody: Codable {
    let context: InnerTubeContext
    let videoId: String?
    let playlistId: String?
    let playlistSetVideoId: String?
    let index: Int?
    let params: String?
    let continuation: String?
}
```

### PlayerBody

```swift
struct PlayerBody: Codable {
    let context: InnerTubeContext
    let videoId: String
    let playlistId: String?
}
```

### AndroidVRPlayerBody

```swift
struct AndroidVRPlayerBody: Codable {
    let context: VRContext
    let videoId: String
    let contentCheckOk: Bool
    let racyCheckOk: Bool
    let playlistId: String?

    struct VRContext: Codable {
        let client: VRClient
    }

    struct VRClient: Codable {
        let clientName: String       // "ANDROID_VR"
        let clientVersion: String    // "1.65.10"
        let deviceMake: String       // "Oculus"
        let deviceModel: String      // "Quest 3"
        let osName: String           // "Android"
        let osVersion: String        // "12L"
        let androidSdkVersion: Int   // 32
        let hl: String
        let gl: String
        let visitorData: String?
    }
}
```

### GetSearchSuggestionsBody

```swift
struct GetSearchSuggestionsBody: Codable {
    let context: InnerTubeContext
    let input: String
}
```

### GetQueueBody

```swift
struct GetQueueBody: Codable {
    let context: InnerTubeContext
    let videoIds: [String]?
    let playlistId: String?
}
```
