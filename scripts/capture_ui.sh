#!/usr/bin/env bash
# capture_ui.sh — Drive a full UI capture sweep on the iOS Simulator.
#
# Usage:
#   bash scripts/capture_ui.sh [--appearance light|dark] [--slug NAME]
#                              [--udid UDID] [--bundle-id ID]
#                              [--rebuild] [--no-log]
#
# Output: doc/design/<slug>/captures/{screenshots,hierarchy,index.md,runtime.log}
#
# Companion skill: .claude/skills/ios-light-mode-capture/SKILL.md
set -euo pipefail

# ---------- args ----------
APPEARANCE="light"
SLUG=""
UDID=""
BUNDLE_ID="com.lovelymusic.app"
REBUILD=0
LOGGING=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appearance) APPEARANCE="$2"; shift 2;;
    --slug)       SLUG="$2"; shift 2;;
    --udid)       UDID="$2"; shift 2;;
    --bundle-id)  BUNDLE_ID="$2"; shift 2;;
    --rebuild)    REBUILD=1; shift;;
    --no-log)     LOGGING=0; shift;;
    -h|--help)    sed -n '2,12p' "$0"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z "$SLUG" ]] && SLUG="$(date +%Y-%m-%d)-${APPEARANCE}-mode-capture"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/doc/design/$SLUG/captures"
mkdir -p "$OUT_DIR/screenshots" "$OUT_DIR/hierarchy"

# ---------- preflight ----------
command -v axe >/dev/null || { echo "axe not installed: brew install cameroncooke/axe/axe"; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode CLT required"; exit 1; }

# ---------- resolve UDID ----------
if [[ -z "$UDID" ]]; then
  # Prefer iPhone 17 Pro booted; else first booted; else boot iPhone 17 Pro.
  UDID="$(xcrun simctl list devices booted -j 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for v in d["devices"].values():
  for x in v:
    if x.get("state")=="Booted":
      print(x["udid"]); break
  else: continue
  break' || true)"
fi

if [[ -z "$UDID" ]]; then
  echo "[capture_ui] No booted simulator. Booting iPhone 17 Pro..."
  xcrun simctl boot "iPhone 17 Pro"
  open -a Simulator
  sleep 6
  UDID="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;d=json.load(sys.stdin);
print(next(x["udid"] for v in d["devices"].values() for x in v if x["state"]=="Booted"))')"
fi

# Guard: shut down extras (multiple booted sims break axe describe-ui)
BOOTED_COUNT=$(xcrun simctl list devices booted | grep -c "Booted" || true)
if [[ "$BOOTED_COUNT" -gt 1 ]]; then
  echo "[capture_ui] WARNING: $BOOTED_COUNT booted sims; shutting down others"
  xcrun simctl list devices booted -j | python3 -c "
import json,sys,subprocess
d=json.load(sys.stdin); keep='$UDID'
for v in d['devices'].values():
  for x in v:
    if x['state']=='Booted' and x['udid']!=keep:
      subprocess.run(['xcrun','simctl','shutdown',x['udid']])"
fi

echo "[capture_ui] UDID=$UDID  appearance=$APPEARANCE  slug=$SLUG"

# ---------- appearance + launch ----------
xcrun simctl ui "$UDID" appearance "$APPEARANCE"

if [[ "$REBUILD" -eq 1 ]]; then
  echo "[capture_ui] Rebuilding..."
  xcodebuild -project "$REPO_ROOT/LovelyMusic.xcodeproj" -scheme LovelyMusic \
    -destination "id=$UDID" -configuration Debug build >/dev/null
  APP_PATH="$(find ~/Library/Developer/Xcode/DerivedData -name LovelyMusic.app \
    -path '*/Debug-iphonesimulator/*' -print -quit)"
  [[ -n "$APP_PATH" ]] && xcrun simctl install "$UDID" "$APP_PATH"
fi

xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null || true
sleep 1.5

# ---------- log capture ----------
LOG_PID=""
if [[ "$LOGGING" -eq 1 ]]; then
  ( xcrun simctl spawn "$UDID" log stream --level info \
      --predicate 'subsystem CONTAINS "lovelymusic" AND messageType >= info' \
      > "$OUT_DIR/runtime.raw.log" 2>/dev/null ) &
  LOG_PID=$!
fi

cleanup() {
  [[ -n "$LOG_PID" ]] && kill "$LOG_PID" 2>/dev/null || true
  if [[ -f "$OUT_DIR/runtime.raw.log" ]]; then
    grep -aE 'Error|Fault|warning|🛑|❌|⚠️' "$OUT_DIR/runtime.raw.log" \
      | head -5000 > "$OUT_DIR/runtime.log" || true
    rm -f "$OUT_DIR/runtime.raw.log"
  fi
}
trap cleanup EXIT

# ---------- helpers ----------
SHOT() { axe screenshot --udid "$UDID" --output "$OUT_DIR/screenshots/$1.png" >/dev/null; }
DUMP() { axe describe-ui --udid "$UDID" --output-format json > "$OUT_DIR/hierarchy/$1.json"; }
CAP()  { sleep 0.4; SHOT "$1"; DUMP "$1"; echo "  ✓ $1"; }
TAP()  { axe tap --udid "$UDID" "$@" >/dev/null 2>&1 || true; sleep 0.5; }
SCROLL() { axe gesture scroll-down --udid "$UDID" >/dev/null 2>&1 || true; sleep 0.4; }

# ---------- screen plan ----------
# Each entry runs nav commands then CAP <slug>.
# Edit freely; this is the LovelyMusic baseline.

echo "[capture_ui] Screen sweep starting..."

# 1. Onboarding (only on first launch — usually skipped after first run)
CAP "onboarding-welcome"

# Skip onboarding if visible
TAP --label "Skip"
TAP --label "Get Started"
sleep 1

# 2-4. Home
CAP "home-top"
SCROLL; CAP "home-mid"
SCROLL; SCROLL; CAP "home-bottom"

# 5-7. Search
TAP --label "Search"
sleep 0.6
CAP "search-idle"
TAP --label "Search songs, artists, albums"
axe type 'Kevin' --udid "$UDID" >/dev/null 2>&1 || true
sleep 0.8
CAP "search-typing"
sleep 0.8
CAP "search-results"

# 8. Library
TAP --label "Library"
sleep 0.6
CAP "library-empty"

# 9-10. Player (mini + full) — assumes a tile is tappable on Home
TAP --label "Home"
sleep 0.5
TAP --label "Play"
sleep 1.2
CAP "mini-player"
TAP --label "Mini Player"
sleep 0.8
CAP "player-full"
TAP --label "Close"

# 11-13. Settings
TAP --label "Home"
TAP --label "Settings"
sleep 0.6
CAP "settings"
TAP --label "Playback & Audio"
sleep 0.6
CAP "settings-playback"
TAP --label "Back"
TAP --label "Language & Region"
sleep 0.6
CAP "settings-language"
TAP --label "Back"
TAP --label "Back"

# 14-15. Album / Artist detail (best-effort; depends on demo data)
TAP --label "Search"
TAP --label "Albums"
sleep 0.6
TAP --label "Peaceful Moments"
sleep 0.8
CAP "album-detail"
TAP --label "Back"
TAP --label "Artists"
sleep 0.6
TAP --label "Kevin MacLeod"
sleep 0.8
CAP "artist-detail"
TAP --label "Back"

# 16. Playlist detail (empty)
TAP --label "Library"
TAP --label "Liked Songs"
sleep 0.6
CAP "playlist-detail-empty"
TAP --label "Back"

# 17. Paywall
TAP --label "Home"
TAP --label "See All"
sleep 0.8
CAP "paywall-premium"

# ---------- index.md ----------
INDEX="$OUT_DIR/index.md"
{
  echo "# UI Capture — $SLUG"
  echo
  echo "> Generated by \`scripts/capture_ui.sh\` on $(date '+%Y-%m-%d %H:%M:%S')"
  echo "> UDID \`$UDID\` · appearance \`$APPEARANCE\` · bundle \`$BUNDLE_ID\`"
  echo
  echo "| # | Screen | Screenshot | Hierarchy | Notes |"
  echo "|--:|--------|------------|-----------|-------|"
  i=0
  for png in "$OUT_DIR/screenshots/"*.png; do
    [[ -e "$png" ]] || continue
    i=$((i+1))
    slug="$(basename "${png%.png}")"
    echo "| $i | $slug | [screenshots/$slug.png](screenshots/$slug.png) | [hierarchy/$slug.json](hierarchy/$slug.json) |  |"
  done
  echo
  echo "## Runtime log"
  echo
  echo "Errors/warnings only — see [runtime.log](runtime.log)."
} > "$INDEX"

echo "[capture_ui] DONE → $OUT_DIR"
echo "[capture_ui] Screens: $(ls "$OUT_DIR/screenshots" | wc -l | tr -d ' ')"
