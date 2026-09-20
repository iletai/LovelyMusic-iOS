#!/usr/bin/env python3
"""Generate demo_catalog.json from MANIFEST.json so the app UI always reflects
the actual licensed tracks. Eliminates fabricated artist names that triggered
App Review Guideline 5.2.3 concern.

Groups 22 Kevin MacLeod tracks into 4 thematic albums.
"""

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "LovelyMusic/Resources/DemoContent/Audio/MANIFEST.json"
CATALOG = REPO_ROOT / "LovelyMusic/Resources/DemoContent/demo_catalog.json"

# Thematic grouping: slot -> (album_id, album_title)
ALBUM_ASSIGN = {
    # Ambient / Ethereal
    "demo_song_aurora":           ("demo_album_ethereal", "Ethereal Atmospheres"),
    "demo_song_nebula_drift":     ("demo_album_ethereal", "Ethereal Atmospheres"),
    "demo_song_cosmic_waves":     ("demo_album_ethereal", "Ethereal Atmospheres"),
    "demo_song_starfield":        ("demo_album_ethereal", "Ethereal Atmospheres"),
    "demo_song_starlit_path":     ("demo_album_ethereal", "Ethereal Atmospheres"),
    "demo_song_solar_wind":       ("demo_album_ethereal", "Ethereal Atmospheres"),
    # Cinematic / Epic
    "demo_song_epic_rise":        ("demo_album_cinematic", "Cinematic Intensity"),
    "demo_song_battle_drums":     ("demo_album_cinematic", "Cinematic Intensity"),
    "demo_song_heroic_theme":     ("demo_album_cinematic", "Cinematic Intensity"),
    "demo_song_dark_tension":     ("demo_album_cinematic", "Cinematic Intensity"),
    "demo_song_victory_march":    ("demo_album_cinematic", "Cinematic Intensity"),
    "demo_song_final_stand":      ("demo_album_cinematic", "Cinematic Intensity"),
    "demo_song_event_horizon":    ("demo_album_cinematic", "Cinematic Intensity"),
    # Calm / Ambient piano
    "demo_song_morning_light":    ("demo_album_peaceful", "Peaceful Moments"),
    "demo_song_gentle_breeze":    ("demo_album_peaceful", "Peaceful Moments"),
    "demo_song_quiet_moments":    ("demo_album_peaceful", "Peaceful Moments"),
    "demo_song_evening_calm":     ("demo_album_peaceful", "Peaceful Moments"),
    # Retro / Comedy / Chiptune
    "demo_song_scheming_weasel":  ("demo_album_retro", "Retro Playful"),
    "demo_song_monkeys_spinning": ("demo_album_retro", "Retro Playful"),
    "demo_song_fluffing_duck":    ("demo_album_retro", "Retro Playful"),
    "demo_song_pixel_peeker":     ("demo_album_retro", "Retro Playful"),
    "demo_song_the_builder":      ("demo_album_retro", "Retro Playful"),
}

ALBUM_DESCRIPTIONS = {
    "demo_album_ethereal":  "Ambient compositions for focus and relaxation.",
    "demo_album_cinematic": "Epic orchestral pieces for dramatic moments.",
    "demo_album_peaceful":  "Gentle melodies perfect for calm moments.",
    "demo_album_retro":     "Playful and quirky tunes with a vintage feel.",
}

ARTIST_ID = "demo_artist_kevin_macleod"
ARTIST_NAME = "Kevin MacLeod"
ARTIST_DESC = (
    "Composer of over 2,000 royalty-free music pieces. "
    "All tracks in this demo catalog are sourced from his Internet Archive "
    "collection (https://archive.org/details/Incompetech) and licensed under "
    "Creative Commons Attribution 3.0 (https://creativecommons.org/licenses/by/3.0/)."
)


def display_title(slot: str, manifest_title: str) -> str:
    return manifest_title


def main() -> int:
    manifest = json.loads(MANIFEST.read_text())
    tracks = {t["slot"]: t for t in manifest["tracks"]}

    # Build per-album song lists in manifest CSV order (deterministic)
    albums: dict[str, dict] = {}
    for slot, (aid, atitle) in ALBUM_ASSIGN.items():
        if slot not in tracks:
            raise SystemExit(f"Slot {slot} missing from MANIFEST.json")
        albums.setdefault(aid, {
            "id": aid,
            "title": atitle,
            "artistName": ARTIST_NAME,
            "artistId": ARTIST_ID,
            "year": "2024",
            "thumbnailURL": aid,
            "description": ALBUM_DESCRIPTIONS[aid],
            "songs": [],
        })
        t = tracks[slot]
        dur = int(round(t.get("duration_sec") or 0))
        albums[aid]["songs"].append({
            "id": slot,
            "title": display_title(slot, t["display_title"]),
            "artistName": ARTIST_NAME,
            "artistId": ARTIST_ID,
            "albumName": atitle,
            "albumId": aid,
            "duration": dur,
            "thumbnailURL": aid,
        })

    album_list = [albums[k] for k in [
        "demo_album_peaceful", "demo_album_cinematic",
        "demo_album_retro", "demo_album_ethereal",
    ]]

    # Featured sections draw from different albums
    def song_item(slot: str) -> dict:
        aid, atitle = ALBUM_ASSIGN[slot]
        t = tracks[slot]
        return {
            "type": "song",
            "id": slot,
            "title": t["display_title"],
            "artistName": ARTIST_NAME,
            "artistId": ARTIST_ID,
            "albumName": atitle,
            "albumId": aid,
            "duration": int(round(t.get("duration_sec") or 0)),
            "thumbnailURL": aid,
        }

    def album_item(aid: str) -> dict:
        a = albums[aid]
        return {
            "type": "album",
            "id": aid,
            "title": a["title"],
            "artistName": ARTIST_NAME,
            "artistId": ARTIST_ID,
            "year": "2024",
            "thumbnailURL": aid,
        }

    sections = [
        {
            "title": "Featured Mix",
            "items": [
                song_item("demo_song_aurora"),
                song_item("demo_song_morning_light"),
                song_item("demo_song_epic_rise"),
                song_item("demo_song_scheming_weasel"),
                song_item("demo_song_nebula_drift"),
                album_item("demo_album_peaceful"),
            ],
        },
        {
            "title": "Chill Vibes",
            "items": [
                song_item("demo_song_gentle_breeze"),
                song_item("demo_song_quiet_moments"),
                song_item("demo_song_cosmic_waves"),
                song_item("demo_song_starlit_path"),
                song_item("demo_song_evening_calm"),
                album_item("demo_album_ethereal"),
            ],
        },
        {
            "title": "Retro Picks",
            "items": [
                song_item("demo_song_fluffing_duck"),
                song_item("demo_song_pixel_peeker"),
                song_item("demo_song_monkeys_spinning"),
                song_item("demo_song_the_builder"),
                song_item("demo_song_scheming_weasel"),
                album_item("demo_album_retro"),
            ],
        },
        {
            "title": "Epic & Cinematic",
            "items": [
                song_item("demo_song_battle_drums"),
                song_item("demo_song_heroic_theme"),
                song_item("demo_song_dark_tension"),
                song_item("demo_song_victory_march"),
                song_item("demo_song_final_stand"),
                album_item("demo_album_cinematic"),
            ],
        },
    ]

    catalog = {
        "_generated": "scripts/generate_demo_catalog.py from MANIFEST.json",
        "_license": (
            "All tracks: CC BY 3.0 by Kevin MacLeod (incompetech.com). "
            "See Resources/DemoContent/Audio/MANIFEST.json for provenance."
        ),
        "artists": [
            {
                "id": ARTIST_ID,
                "name": ARTIST_NAME,
                "thumbnailURL": "demo_artist_kevin_macleod",
                "subscriberCount": "Public Domain · CC BY 3.0",
                "description": ARTIST_DESC,
            },
        ],
        "albums": album_list,
        "sections": sections,
    }

    CATALOG.write_text(json.dumps(catalog, indent=4, ensure_ascii=False) + "\n")
    total_songs = sum(len(a["songs"]) for a in album_list)
    print(f"✅ Wrote {CATALOG.relative_to(REPO_ROOT)}: "
          f"{len(album_list)} albums, {total_songs} songs, 1 artist.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
