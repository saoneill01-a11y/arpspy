#!/bin/sh
# One-step build on a Mac: makes the Xcode project, builds, runs the tests,
# then installs the app in /Applications and opens it. If something fails,
# copy the error lines into Claude.
# Builds go in build.noindex: Spotlight skips folders ending in .noindex,
# so the launcher only ever shows the copy in /Applications.
set -e
cd "$(dirname "$0")/.."
OUT=build.noindex

# Use Xcode even when the Mac points at the command-line tools only.
case "$(xcode-select -p 2>/dev/null)" in
  *CommandLineTools*) [ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
esac

command -v xcodegen >/dev/null || { echo "Installing xcodegen…"; brew install xcodegen; }
xcodegen

echo "Running tests…"
xcodebuild -scheme ArpSpy -destination 'platform=macOS' -derivedDataPath "$OUT" -quiet test

echo "Building…"
xcodebuild -scheme ArpSpy -configuration Release -destination 'platform=macOS' -derivedDataPath "$OUT" -quiet build

echo "Installing in Applications…"
osascript -e 'tell application id "com.arpradar.mac" to quit' 2>/dev/null || true
osascript -e 'tell application id "com.example.arpspy" to quit' 2>/dev/null || true   # the app's old ID
sleep 1
rm -rf /Applications/ARPradar.app
cp -R "$OUT/Build/Products/Release/ARPradar.app" /Applications/

echo "Done. Opening ARPradar."
open /Applications/ARPradar.app
