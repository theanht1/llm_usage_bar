#!/bin/bash
# Builds LLMUsageBar.app into dist/
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/LLMUsageBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LLMUsageBar "$APP/Contents/MacOS/LLMUsageBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
