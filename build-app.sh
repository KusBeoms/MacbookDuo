#!/bin/bash
# Builds MacbookDuo.app. Xcode is not required — this uses the Swift toolchain
# that ships with the Command Line Tools.
#
#   ./build-app.sh             build into ./build
#   ./build-app.sh --install   build, install to /Applications, and re-arm the
#                              Screen Recording prompt
#
# On the Screen Recording prompt reappearing: with no code signing certificate the
# app can only be ad-hoc signed, and every rebuild produces a different code hash.
# macOS ties the granted permission to that hash, so a rebuilt app is a new app as
# far as TCC is concerned — the old entry stays in the list but no longer matches.
# `--install` clears the stale entry so the prompt appears cleanly once, instead of
# the app silently failing to capture.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/MacbookDuo.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/MacbookDuo" "$APP/Contents/MacOS/MacbookDuo"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature, so TCC can remember the Screen Recording grant for this build.
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -f "MacbookDuo.app" 2>/dev/null || true
    sleep 1
    tccutil reset ScreenCapture com.macbookduo.app || true
    rm -rf "/Applications/MacbookDuo.app"
    cp -R "$APP" "/Applications/"
    open "/Applications/MacbookDuo.app"
    echo "Installed to /Applications and launched. Grant Screen Recording once when asked."
fi
