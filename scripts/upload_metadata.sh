#!/usr/bin/env bash
# Upload App Store metadata (only) via Fastlane deliver.
# Does NOT upload a new binary and does NOT submit for review.
#
# Prerequisites:
#   1. App Store Connect API Key (.p8 file, Key ID, Issuer ID)
#      → https://appstoreconnect.apple.com/access/integrations/api
#   2. One of:
#        (a) Environment variables exported in your shell, OR
#        (b) A file `.env.local` at repo root with those variables (gitignored)
#
# Required variables:
#   APP_STORE_CONNECT_API_KEY_ID       — 10-char key ID (e.g. A1B2C3D4E5)
#   APP_STORE_CONNECT_API_ISSUER_ID    — UUID from App Store Connect
#   APP_STORE_CONNECT_API_KEY_PATH     — absolute path to the .p8 file
#     (OR APP_STORE_CONNECT_API_KEY_CONTENT — base64 of the .p8 file)
#
# Usage:
#   scripts/upload_metadata.sh              # uploads metadata for com.lovelymusic.app
#   scripts/upload_metadata.sh --dry-run    # validates without uploading
#
# What gets uploaded:
#   fastlane/metadata/en-US/{description,subtitle,keywords,promotional_text,release_notes}.txt
#   fastlane/metadata/ja/{same}
#   fastlane/metadata/vi/{same}
#   fastlane/metadata/review_information/*.txt   (if present)
#
# Apple App Review Information (PDF attachments) must be uploaded MANUALLY via
# App Store Connect web UI — fastlane deliver does not attach PDFs to the
# Resolution Center.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BLUE="\033[0;34m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"

log()   { echo -e "${BLUE}[upload-metadata]${NC} $*"; }
ok()    { echo -e "${GREEN}[ ok ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
fail()  { echo -e "${RED}[fail]${NC} $*"; exit 1; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── 1. Load .env.local if present ────────────────────────────────────────────
if [[ -f .env.local ]]; then
  log "Sourcing .env.local"
  set -a; source .env.local; set +a
fi

# ── 2. Validate required env vars ────────────────────────────────────────────
: "${APP_STORE_CONNECT_API_KEY_ID:?env APP_STORE_CONNECT_API_KEY_ID is required}"
: "${APP_STORE_CONNECT_API_ISSUER_ID:?env APP_STORE_CONNECT_API_ISSUER_ID is required}"

APP_ID="${APP_IDENTIFIER:-com.lovelymusic.app}"
METADATA_PATH="fastlane/metadata"

# Resolve .p8: either a file path, or base64 content we need to materialise.
KEY_FILE=""
CLEANUP_KEY=false
if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
  [[ -f "$APP_STORE_CONNECT_API_KEY_PATH" ]] || fail "Key file not found: $APP_STORE_CONNECT_API_KEY_PATH"
  KEY_FILE="$APP_STORE_CONNECT_API_KEY_PATH"
elif [[ -n "${APP_STORE_CONNECT_API_KEY_CONTENT:-}" ]]; then
  KEY_FILE="$(mktemp -t asc_key.XXXXXX).p8"
  echo "$APP_STORE_CONNECT_API_KEY_CONTENT" | base64 --decode > "$KEY_FILE"
  CLEANUP_KEY=true
else
  fail "Need APP_STORE_CONNECT_API_KEY_PATH or APP_STORE_CONNECT_API_KEY_CONTENT"
fi

trap '$CLEANUP_KEY && rm -f "$KEY_FILE"' EXIT

ok "Key ID       : $APP_STORE_CONNECT_API_KEY_ID"
ok "Issuer ID    : $APP_STORE_CONNECT_API_ISSUER_ID"
ok "Key file     : $KEY_FILE"
ok "App bundle id: $APP_ID"

# ── 3. Validate metadata files are present ───────────────────────────────────
log "Checking metadata files …"
MISSING=0
for loc in en-US ja vi; do
  for key in description subtitle keywords promotional_text release_notes; do
    file="$METADATA_PATH/$loc/$key.txt"
    if [[ ! -f "$file" ]]; then
      warn "missing  $file"
      MISSING=$((MISSING+1))
    fi
  done
done
[[ $MISSING -eq 0 ]] || fail "$MISSING metadata file(s) missing"
ok "All metadata files present for en-US, ja, vi"

check_len() {
  local f=$1 max=$2
  local n=$(python3 -c "import sys; print(len(open(sys.argv[1], encoding='utf-8').read().rstrip()))" "$f")
  if (( n > max )); then warn "$f is $n chars (max $max)"; return 1; fi
  return 0
}
OVERFLOW=0
for loc in en-US ja vi; do
  check_len "$METADATA_PATH/$loc/description.txt"      4000 || OVERFLOW=$((OVERFLOW+1))
  check_len "$METADATA_PATH/$loc/subtitle.txt"         30   || OVERFLOW=$((OVERFLOW+1))
  check_len "$METADATA_PATH/$loc/promotional_text.txt" 170  || OVERFLOW=$((OVERFLOW+1))
  check_len "$METADATA_PATH/$loc/keywords.txt"         100  || OVERFLOW=$((OVERFLOW+1))
done
if (( OVERFLOW > 0 )); then
  fail "$OVERFLOW field(s) exceed App Store char limits (fix before upload)"
fi

if $DRY_RUN; then
  ok "Dry-run complete. Nothing uploaded."
  exit 0
fi

# ── 4. Run fastlane deliver (metadata-only) ──────────────────────────────────
log "Uploading metadata to App Store Connect …"

bundle exec fastlane deliver \
  --api_key_path <(cat <<EOF
{
  "key_id": "$APP_STORE_CONNECT_API_KEY_ID",
  "issuer_id": "$APP_STORE_CONNECT_API_ISSUER_ID",
  "key": $(python3 -c "import json,sys; print(json.dumps(open('$KEY_FILE').read()))"),
  "duration": 1200,
  "in_house": false
}
EOF
) \
  --app_identifier "$APP_ID" \
  --metadata_path "$METADATA_PATH" \
  --skip_binary_upload true \
  --skip_screenshots true \
  --skip_app_version_update false \
  --force true \
  --submit_for_review false \
  --automatic_release false \
  --precheck_include_in_app_purchases false \
  --run_precheck_before_submit false

ok "Metadata uploaded."
log "Next step: attach MUSIC_LICENSE_EVIDENCE.pdf + APP_REVIEW_STATEMENT.pdf"
log "           in App Store Connect → App Review Information (manual)."
