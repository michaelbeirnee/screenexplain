#!/bin/bash
# Builds ScreenExplain.app — a proper double-clickable, signable app bundle.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building release binary…"
swift build -c release

APP="ScreenExplain.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp ".build/release/ScreenExplain" "$APP/Contents/MacOS/ScreenExplain"
cp "Info.plist" "$APP/Contents/Info.plist"

echo "Code signing…"
# A stable local identity (not ad-hoc "-") so macOS's screen-recording/mic
# permission grants survive rebuilds instead of resetting on every new binary hash.
codesign --force --deep --sign "ScreenExplain Local Signing" "$APP"

echo "Done: $APP"
echo "Move it to /Applications with:  mv $APP /Applications/"
