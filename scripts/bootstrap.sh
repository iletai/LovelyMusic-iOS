#!/bin/bash
# Bootstrap script — run once after cloning the repo.
# Generates Xcode project (XcodeGen) and configures BSP for SourceKit-LSP.
set -e

cd "$(dirname "$0")/.."

echo "🔧 [xcodegen] Generating Xcode project..."
xcodegen generate

echo "🔧 [xcode-build-server] Configuring BSP for SourceKit-LSP..."
xcode-build-server config -project LovelyMusic.xcodeproj -scheme LovelyMusic

echo "✅ Done! Open the project in VS Code or Xcode."
