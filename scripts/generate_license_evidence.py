#!/usr/bin/env python3
"""Regenerate docs/MUSIC_LICENSE_EVIDENCE.md from MANIFEST.json.

Single source of truth: the manifest. Document re-generated every time
tracks change so evidence and catalog never drift.
"""

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "LovelyMusic/Resources/DemoContent/Audio/MANIFEST.json"
OUT = REPO_ROOT / "docs/MUSIC_LICENSE_EVIDENCE.md"


def fmt_duration(seconds: float | None) -> str:
    if not seconds:
        return "—"
    m, s = divmod(int(round(seconds)), 60)
    return f"{m}:{s:02d}"


def fmt_bytes(n: int) -> str:
    return f"{n:,}"


def main() -> int:
    m = json.loads(MANIFEST.read_text())
    tracks = m["tracks"]
    gen_at = m["generated_at"]

    lines: list[str] = []
    lines.append("# Music License Evidence — LovelyMusic")
    lines.append("")
    lines.append("> **For**: Apple App Store Review Team  ")
    lines.append("> **App**: LovelyMusic (`com.lovelymusic.app`)  ")
    lines.append("> **Guidelines addressed**: 5.2.3 (Legal — Intellectual Property, Audio/Video)  ")
    lines.append(f"> **Evidence generated**: {gen_at}  ")
    lines.append(
        f"> **Source manifest**: "
        f"[`Resources/DemoContent/Audio/MANIFEST.json`]"
        f"(../LovelyMusic/Resources/DemoContent/Audio/MANIFEST.json) "
        "(single source of truth)"
    )
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(
        "Every audio track bundled in the submitted build of LovelyMusic is "
        "composed by **Kevin MacLeod** ([incompetech.com](https://incompetech.com)) "
        "and licensed under the **Creative Commons Attribution 3.0 Unported** "
        "license (CC BY 3.0). Files are sourced from Kevin MacLeod's public "
        "Internet Archive collection:"
    )
    lines.append("")
    lines.append("- **Source page**: <https://archive.org/details/Incompetech>")
    lines.append("- **License**: [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)")
    lines.append("- **Attribution statement** (shown in app): "
                 "_\"Music by Kevin MacLeod (incompetech.com), CC BY 3.0\"_")
    lines.append("")
    lines.append(
        "No copyrighted third-party catalog, streaming service, or discovery "
        "service is accessed from the submitted binary. All music files are "
        "bundled inside `LovelyMusic.app/DemoContent/Audio/` at build time."
    )
    lines.append("")
    lines.append("## Verification Steps for Apple Reviewer")
    lines.append("")
    lines.append(
        "1. Visit the source collection: "
        "<https://archive.org/details/Incompetech>"
    )
    lines.append(
        "2. Confirm the collection's license is "
        "\"Creative Commons Attribution 3.0 Unported\" "
        "(displayed near the top of the Archive.org page)."
    )
    lines.append(
        "3. For any track in the table below, click the **Source URL** "
        "to reach the direct MP3. The returned file's SHA-256 should match "
        "the original MP3 before conversion to AAC/m4a."
    )
    lines.append(
        "4. Inside the app, navigate to **Settings → About → Music Credits** "
        "to see the in-app attribution screen."
    )
    lines.append("")
    lines.append("## License Terms (CC BY 3.0 — permitted uses)")
    lines.append("")
    lines.append(
        "- ✅ **Commercial use** (including paid apps, apps with in-app purchases)  "
    )
    lines.append("- ✅ **Redistribution and bundling** inside a software product  ")
    lines.append("- ✅ **Modification** (format conversion from MP3 to AAC/m4a)  ")
    lines.append("- ⚠️ **Attribution required**: LovelyMusic displays attribution "
                 "inside the app under Settings → About → Music Credits.")
    lines.append("")
    lines.append("Full license text: <https://creativecommons.org/licenses/by/3.0/legalcode>")
    lines.append("")
    lines.append("## Per-Track Evidence")
    lines.append("")
    lines.append(
        f"All {len(tracks)} tracks. Column definitions: _Slot_ = filename in "
        "`DemoContent/Audio/`; _Source URL_ = deterministic public download URL; "
        "_SHA-256_ = checksum of the bundled .m4a file (post-conversion); "
        "_Bytes_ = size of the bundled .m4a file."
    )
    lines.append("")

    lines.append(
        "| # | Slot | Title | Duration | Source URL | SHA-256 (m4a) | Bytes |"
    )
    lines.append(
        "| - | ---- | ----- | -------- | ---------- | ------------- | ----- |"
    )
    for i, t in enumerate(tracks, 1):
        sha12 = t["sha256"][:12]
        slot = t["slot"]
        title = t["display_title"]
        dur = fmt_duration(t.get("duration_sec"))
        src = t["source_download_url"]
        lines.append(
            f"| {i} | `{slot}` | {title} | {dur} | "
            f"[{src[-60:]}]({src}) | `{sha12}…` | {fmt_bytes(t['bytes'])} |"
        )
    lines.append("")

    lines.append("## Integrity Check")
    lines.append("")
    lines.append(
        "Apple reviewer can verify that any bundled file came from the claimed "
        "source by running (after downloading the .ipa and extracting "
        "`DemoContent/Audio/`):"
    )
    lines.append("")
    lines.append("```bash")
    lines.append("# Example for one track:")
    lines.append("shasum -a 256 LovelyMusic.app/DemoContent/Audio/demo_song_aurora.m4a")
    lines.append("# Expected sha256 prefix matches MUSIC_LICENSE_EVIDENCE.md table.")
    lines.append("")
    lines.append("# Re-fetch the original MP3 from archive.org:")
    lines.append(
        "curl -LO 'https://archive.org/download/Incompetech/mp3-royaltyfree/"
        "Atlantean%20Twilight.mp3'"
    )
    lines.append("# License banner is visible at: https://archive.org/details/Incompetech")
    lines.append("```")
    lines.append("")
    lines.append("## Attribution (shipped in app binary)")
    lines.append("")
    lines.append("The following attribution is rendered in the app at")
    lines.append("**Settings → About → Music Credits**:")
    lines.append("")
    lines.append("> Music bundled with LovelyMusic is composed by")
    lines.append("> **Kevin MacLeod** (<https://incompetech.com>) and used")
    lines.append("> under the Creative Commons Attribution 3.0 Unported license")
    lines.append("> (<https://creativecommons.org/licenses/by/3.0/>).")
    lines.append(">")
    lines.append("> Source collection: <https://archive.org/details/Incompetech>")
    lines.append("")
    lines.append("## Contact")
    lines.append("")
    lines.append(
        "For questions about this evidence, contact the developer through "
        "App Store Connect review messaging. All source files can be "
        "independently re-verified via the archive.org URLs listed above."
    )
    lines.append("")

    OUT.write_text("\n".join(lines))
    print(f"✅ Wrote {OUT.relative_to(REPO_ROOT)} ({len(tracks)} tracks).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
