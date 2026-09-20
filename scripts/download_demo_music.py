#!/usr/bin/env python3
"""Download demo music tracks from manifest CSV, convert to m4a, emit MANIFEST.json.

Provides provenance evidence for App Store review:
 - Source page URL (clickable by reviewer to verify)
 - Direct download URL (deterministic, re-fetchable)
 - License name + license URL (CC BY 3.0 at creativecommons.org)
 - SHA-256 checksum (proves file integrity)
 - Byte size + duration (sanity check)

Usage:
    scripts/download_demo_music.py            # download + convert everything
    scripts/download_demo_music.py --dry      # validate manifest only
    scripts/download_demo_music.py --force    # re-download even if m4a exists
"""

from __future__ import annotations

import argparse
import csv
import datetime
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_CSV = REPO_ROOT / "scripts" / "demo_music_manifest.csv"
AUDIO_DIR = REPO_ROOT / "LovelyMusic" / "Resources" / "DemoContent" / "Audio"
MANIFEST_JSON = AUDIO_DIR / "MANIFEST.json"

USER_AGENT = "LovelyMusic-DemoDL/1.0 (archive.org re-download for App Store review)"


def parse_manifest() -> list[dict]:
    with MANIFEST_CSV.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit(f"ERROR: empty manifest {MANIFEST_CSV}")
    required = {
        "slot", "display_title", "artist",
        "archive_item_url", "direct_download_url",
        "license", "license_url",
    }
    missing_cols = required - set(rows[0].keys())
    if missing_cols:
        sys.exit(f"ERROR: CSV missing columns: {sorted(missing_cols)}")
    for r in rows:
        for k, v in r.items():
            if not v or v.strip() == "" or v.strip() == "TODO":
                sys.exit(f"ERROR: row slot={r.get('slot')} has empty/TODO value for '{k}'")
    return rows


def download(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=120) as resp, dest.open("wb") as f:
        shutil.copyfileobj(resp, f)


def convert_to_m4a(src: Path, dest: Path) -> None:
    """Convert arbitrary audio to AAC in m4a (matches existing bundle format)."""
    if src.suffix.lower() == ".m4a":
        shutil.copy2(src, dest)
        return
    # afconvert: stereo AAC 128 kbps (matches Apple Music quality tier)
    subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", "-q", "127",
         str(src), str(dest)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def probe_duration(path: Path) -> float | None:
    try:
        out = subprocess.run(
            ["afinfo", str(path)], capture_output=True, text=True, check=True
        ).stdout
    except Exception:
        return None
    for line in out.splitlines():
        if "estimated duration" in line:
            try:
                return float(line.split(":")[1].split()[0])
            except Exception:
                return None
    return None


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry", action="store_true", help="validate CSV without downloads")
    ap.add_argument("--force", action="store_true", help="re-download even if m4a exists")
    args = ap.parse_args()

    print(f"==> Reading manifest: {MANIFEST_CSV}")
    rows = parse_manifest()
    print(f"    {len(rows)} tracks declared.")

    if args.dry:
        print("==> Dry run: manifest is valid.")
        return 0

    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    tmpdir = Path(tempfile.mkdtemp(prefix="lovelymusic-demo-dl-"))
    tracks_out: list[dict] = []
    failures: list[str] = []

    try:
        for i, row in enumerate(rows, 1):
            slot = row["slot"]
            title = row["display_title"]
            artist = row["artist"]
            page_url = row["archive_item_url"]
            download_url = row["direct_download_url"]
            lic = row["license"]
            lic_url = row["license_url"]

            out_m4a = AUDIO_DIR / f"{slot}.m4a"
            if out_m4a.exists() and not args.force:
                # Check MANIFEST.json if already logged same URL
                if MANIFEST_JSON.exists():
                    try:
                        existing = json.loads(MANIFEST_JSON.read_text())
                        for t in existing.get("tracks", []):
                            if t.get("slot") == slot and t.get("source_download_url") == download_url:
                                print(f"  [{i:>2}/{len(rows)}] {slot:30s} ↻ already downloaded, skipping")
                                tracks_out.append(t)
                                break
                        else:
                            pass
                        if tracks_out and tracks_out[-1].get("slot") == slot:
                            continue
                    except Exception:
                        pass

            print(f"  [{i:>2}/{len(rows)}] {slot:30s} <- {title} / {artist}")
            suffix = Path(download_url.split("?")[0]).suffix.lower() or ".mp3"
            tmp_src = tmpdir / f"{slot}{suffix}"

            try:
                download(download_url, tmp_src)
            except Exception as e:
                print(f"       ❌ download failed: {e}")
                failures.append(slot)
                continue

            size = tmp_src.stat().st_size
            if size < 50_000:
                print(f"       ❌ file too small ({size} bytes), likely error page")
                failures.append(slot)
                continue

            try:
                convert_to_m4a(tmp_src, out_m4a)
            except subprocess.CalledProcessError as e:
                print(f"       ❌ afconvert failed: {e.stderr.decode('utf-8','ignore')[:200]}")
                failures.append(slot)
                continue

            final_size = out_m4a.stat().st_size
            duration = probe_duration(out_m4a)
            digest = sha256(out_m4a)
            print(f"       ✓ {final_size:,} bytes, {duration:.1f}s, sha256={digest[:12]}…")

            tracks_out.append({
                "slot": slot,
                "file": str(out_m4a.relative_to(REPO_ROOT)),
                "display_title": title,
                "artist": artist,
                "source_page_url": page_url,
                "source_download_url": download_url,
                "license": lic,
                "license_url": lic_url,
                "downloaded_at": datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z",
                "sha256": digest,
                "bytes": final_size,
                "duration_sec": round(duration, 2) if duration else None,
            })
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    doc = {
        "generated_at": datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "generator": "scripts/download_demo_music.py",
        "purpose": (
            "Provenance manifest for LovelyMusic demo catalog. "
            "Provided to Apple App Review as documentary evidence under Guideline 5.2.3. "
            "All tracks are licensed under Creative Commons (CC BY 3.0) and sourced from "
            "Internet Archive, which hosts Kevin MacLeod's royalty-free music collection."
        ),
        "attribution_statement": (
            "Music by Kevin MacLeod (https://incompetech.com). "
            "Sourced from the Internet Archive Incompetech collection "
            "(https://archive.org/details/Incompetech). "
            "Licensed under Creative Commons Attribution 3.0 Unported "
            "(https://creativecommons.org/licenses/by/3.0/)."
        ),
        "total_tracks": len(tracks_out),
        "failed_tracks": failures,
        "tracks": tracks_out,
    }
    MANIFEST_JSON.write_text(json.dumps(doc, indent=2, ensure_ascii=False))
    print(f"\n==> Wrote {MANIFEST_JSON.relative_to(REPO_ROOT)} "
          f"({len(tracks_out)} ok, {len(failures)} failed)")

    if failures:
        print(f"\n⚠️  Failed slots: {', '.join(failures)}")
        return 1
    print("\n✅ All tracks downloaded successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
