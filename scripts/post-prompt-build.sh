#!/bin/bash
set -e

INPUT=$(cat)
LOG_FILE=".build-hook.log"

# Background the heavy work to avoid blocking the agent
# Docs: "For expensive operations, consider background processing"
(
  echo "=== Post-prompt build hook started: $(date) ===" >> "$LOG_FILE"

  echo "[xcodegen] Generating Xcode project..." >> "$LOG_FILE"
  if xcodegen generate >> "$LOG_FILE" 2>&1; then
    echo "[xcodegen] Project generated successfully" >> "$LOG_FILE"
  else
    echo "[xcodegen] FAIL -- project generation failed" >> "$LOG_FILE"
    echo "=== Post-prompt build hook finished: $(date) ===" >> "$LOG_FILE"
    exit 0
  fi

  echo "[xcodebuild] Building LovelyMusic..." >> "$LOG_FILE"
  if xcodebuild build \
    -project LovelyMusic.xcodeproj \
    -scheme LovelyMusic \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -quiet \
    >> "$LOG_FILE" 2>&1; then
    echo "[xcodebuild] Build succeeded" >> "$LOG_FILE"
  else
    echo "[xcodebuild] FAIL -- build failed, check $LOG_FILE" >> "$LOG_FILE"
  fi

  echo "=== Post-prompt build hook finished: $(date) ===" >> "$LOG_FILE"
) &

exit 0
