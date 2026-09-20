#!/usr/bin/env bash
set -euo pipefail

# Script to sync Remote Config JSON from Git to MicroCMS
# Supports both:
#   1. Clean Stringified Mode (when 'config_json' field exists on MicroCMS schema)
#   2. Legacy Flat Fields Mode (fallback for existing 35 flat fields)
#
# Usage:
#   ./scripts/sync_remote_config.sh debug
#   ./scripts/sync_remote_config.sh release
#   ./scripts/sync_remote_config.sh all

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SECRETS_FILE="${ROOT_DIR}/LovelyMusic/Resources/Secrets.plist"
API_KEY="${MICROCMS_API_KEY:-}"
SERVICE_DOMAIN="${MICROCMS_SERVICE_DOMAIN:-your-service}"

if [[ -z "${API_KEY}" && -f "${SECRETS_FILE}" ]]; then
  API_KEY="$(plutil -extract MICROCMS_API_KEY raw "${SECRETS_FILE}" 2>/dev/null || true)"
fi

if [[ -z "${API_KEY}" || "${API_KEY}" == *"XXXXXX"* ]]; then
  echo "❌ Error: MICROCMS_API_KEY not found or invalid in ${SECRETS_FILE}"
  exit 1
fi

sync_env() {
  local target="$1"
  local endpoint=""
  local json_file=""

  if [[ "${target}" == "debug" ]]; then
    endpoint="app-config-develop"
    json_file="${ROOT_DIR}/LovelyMusic/Resources/RemoteConfig/config.debug.json"
  elif [[ "${target}" == "release" ]]; then
    endpoint="app-config"
    json_file="${ROOT_DIR}/LovelyMusic/Resources/RemoteConfig/config.release.json"
  else
    echo "❌ Unknown target: ${target}. Use 'debug' or 'release'."
    return 1
  fi

  if [[ ! -f "${json_file}" ]]; then
    echo "❌ Config file not found: ${json_file}"
    return 1
  fi

  echo "🔄 Checking schema and syncing [${target}] from ${json_file} to https://${SERVICE_DOMAIN}.microcms.io/api/v1/${endpoint}..."

  # Validate JSON syntax
  python3 -m json.tool "${json_file}" > /dev/null

  # Check schema from Management API to see if 'config_json' field exists
  local schema_has_config_json
  schema_has_config_json=$(python3 -c "
import urllib.request, json

url = 'https://${SERVICE_DOMAIN}.microcms-management.io/api/v1/apis/${endpoint}'
headers = {
    'X-MICROCMS-API-KEY': '${API_KEY}',
    'User-Agent': 'curl/8.7.1'
}

try:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read().decode())
    fields = [f.get('fieldId') for f in data.get('apiFields', [])]
    print('true' if 'config_json' in fields else 'false')
except Exception:
    print('false')
")

  local payload
  if [[ "${schema_has_config_json}" == "true" ]]; then
    echo "✨ Detected clean 'config_json' field on ${endpoint} schema! Using stringified JSON payload."
    payload=$(python3 -c "
import json
with open('${json_file}') as f:
    content = f.read()
print(json.dumps({'config_json': content}))
")
  else
    echo "ℹ️  'config_json' not found in schema. Falling back to 35 legacy flat fields."
    payload=$(python3 -c "
import json

with open('${json_file}') as f:
    cfg = json.load(f)

toggles = cfg.get('toggles', {})
monetization = cfg.get('monetization', {})
audio = cfg.get('audio', {})
anim = cfg.get('animations', {})
ui = cfg.get('ui', {})
update = cfg.get('update', {})

flat = {
    'download_enabled': toggles.get('download_enabled', False),
    'youtube_auth_enabled': toggles.get('youtube_auth_enabled', False),
    'video_playbacktoggle': toggles.get('video_playback_enabled', True),
    'dev_mode_enabled': toggles.get('dev_mode_enabled', False),
    'appearance_settings': toggles.get('appearance_settings_enabled', True),
    'review_mode_enabled': toggles.get('review_mode_enabled', True),
    'free_skip_limit': monetization.get('free_skip_limit', 12),
    'free_download_limit': monetization.get('free_download_limit', 5),
    'premium_enabled': monetization.get('premium_enabled', True),
    'lifetime_enabled': monetization.get('lifetime_enabled', True),
    'ads_enabled': monetization.get('ads_enabled', False),
    'ads_skip_frequency': monetization.get('ads_skip_frequency', 4),
    'ads_section_interval': monetization.get('ads_section_interval', 3),
    'ads_song_interval': monetization.get('ads_song_interval', 10),
    'terms_of_service_url': monetization.get('terms_of_service_url', ''),
    'privacy_policy_url': monetization.get('privacy_policy_url', ''),
    'audio_bitrate_low': audio.get('bitrate_low', 64000),
    'audio_bitrate_medium': audio.get('bitrate_medium', 128000),
    'audio_bitrate_high': audio.get('bitrate_high', 256000),
    'anim_bouncy_response': anim.get('bouncy_response', 0.3),
    'anim_bouncy_damping': anim.get('bouncy_damping', 0.6),
    'anim_smooth_response': anim.get('smooth_response', 0.4),
    'anim_smooth_damping': anim.get('smooth_damping', 0.8),
    'anim_player_response': anim.get('player_response', 0.5),
    'anim_player_damping': anim.get('player_damping', 0.85),
    'anim_gentle_duration': anim.get('gentle_duration', 0.25),
    'anim_fade_duration': anim.get('crossfade_duration', 0.3),
    'home_m_carousel_heig': ui.get('home_mood_carousel_height', 110),
    'home_mood_item_width': ui.get('home_mood_item_width', 180),
    'home_m_grid_row_heig': ui.get('home_mood_grid_row_height', 48),
    'min_required_version': update.get('min_required_version', '1.0.0'),
    'recommended_version': update.get('recommended_version', '1.0.0'),
    'force_update_message': update.get('force_update_message', ''),
    'app_store_url': update.get('app_store_url', ''),
    'update_changelog': update.get('update_changelog', '')
}

print(json.dumps(flat))
")
  fi

  local response
  response=$(curl -s -w "\n%{http_code}" -X PATCH "https://${SERVICE_DOMAIN}.microcms.io/api/v1/${endpoint}" \
    -H "X-MICROCMS-API-KEY: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  local status_code
  status_code=$(echo "${response}" | tail -n 1)
  local body
  body=$(echo "${response}" | sed '$d')

  if [[ "${status_code}" -ge 200 && "${status_code}" -lt 300 ]]; then
    echo "✅ Successfully synced [${target}] to MicroCMS (${status_code}): ${body}"
  else
    echo "❌ Failed to sync [${target}] (${status_code}): ${body}"
    return 1
  fi
}

TARGET="${1:-all}"
if [[ "${TARGET}" == "all" ]]; then
  sync_env "debug"
  sync_env "release"
else
  sync_env "${TARGET}"
fi
