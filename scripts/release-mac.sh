#!/bin/sh
# Signed and notarized Mac release: builds ARPradar.app (Apple silicon + Intel), signs it with the Developer ID
# certificate, sends it to Apple's notary service, staples the ticket and writes build-release.noindex/ARPradar.zip
# with its SHA-256 (for the release notes' checksum table). It doesn't upload anything.
#
# One-time setup on this Mac:
#   1. Xcode › Settings › Accounts: sign in, pick the team, Manage Certificates… › + › Developer ID Application.
#   2. DEVELOPMENT_TEAM in project.yml (or ARPRADAR_TEAM=XXXXXXXXXX in the environment).
#   3. An app-specific password from appleid.apple.com, stored in the Keychain (it asks for the password):
#        xcrun notarytool store-credentials arpradar-notary --apple-id YOUR-APPLE-ID --team-id XXXXXXXXXX
set -e
cd "$(dirname "$0")/.."
OUT=build-release.noindex
PROFILE=arpradar-notary

case "$(xcode-select -p 2>/dev/null)" in
  *CommandLineTools*) [ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
esac

TEAM="${ARPRADAR_TEAM:-$(sed -n 's/^ *DEVELOPMENT_TEAM: *"*\([A-Z0-9]\{10\}\)"*.*/\1/p' project.yml | head -1)}"
[ -n "$TEAM" ] || { echo "No team ID: set DEVELOPMENT_TEAM in project.yml or ARPRADAR_TEAM."; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application.*($TEAM)" \
  || { echo "No 'Developer ID Application' certificate for team $TEAM in the Keychain (see step 1 above)."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "No notary password stored yet (see step 3 above)."; exit 1; }

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen

echo "Building and signing…"
rm -rf "$OUT/Build/Products/Release/ARPradar.app"
xcodebuild -scheme ArpSpy -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$OUT" -quiet \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS=--timestamp build
APP="$OUT/Build/Products/Release/ARPradar.app"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Sending to Apple's notary service (usually a few minutes)…"
rm -f "$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$OUT/ARPradar.zip"
ditto -c -k --keepParent "$APP" "$OUT/ARPradar.zip"
echo "Ready: $OUT/ARPradar.zip"
shasum -a 256 "$OUT/ARPradar.zip"
