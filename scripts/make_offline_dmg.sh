#!/bin/bash
# Builds the release DMG: a universal (Apple Silicon + Intel) Zoomie Toolz.app
# with everything inside, nothing downloaded at runtime.
#
#   scripts/make_offline_dmg.sh            -> build/Zoomie-Toolz-<version>.dmg
#
# Signed ad hoc (no Apple Developer account), so on first launch macOS asks
# people to click "Open Anyway" in System Settings → Privacy & Security.
# Video goes to Zoom through OBS Virtual Camera, which needs no signing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Config/App-Info.plist)
OUT=build/release
STAGE=build/dmg-stage
DMG="build/Zoomie-Toolz-$VERSION.dmg"

if command -v xcodegen >/dev/null; then xcodegen generate >/dev/null; fi

echo "Building Zoomie Toolz $VERSION (universal, Release)…"
xcodebuild -project ZoomieToolz.xcodeproj -scheme ZoomieToolz -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$OUT" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= \
  ENABLE_HARDENED_RUNTIME=NO build -quiet

APP="$OUT/Build/Products/Release/Zoomie Toolz.app"
# The bundled Zoomie Cam extension can only install with Apple Developer
# signing, so the ad hoc release leaves it out; OBS Virtual Camera is used instead.
rm -rf "$APP/Contents/Library/SystemExtensions"
rmdir "$APP/Contents/Library" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Zoomie Toolz $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
