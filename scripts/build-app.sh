#!/bin/bash
# Builds "Photo Date Guesser.app" into ./build using Swift Package Manager.
# Requires macOS 14+ with Xcode 15.3 or newer (or the matching Command Line Tools).
#
#   ./scripts/build-app.sh                 # release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer full Xcode when it's installed (and its license is accepted), even if the active
# developer directory is the Command Line Tools. The build also works with only the CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
  XCODE_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -n 1)"
  [ -n "$XCODE_APP" ] || XCODE_APP="/Applications/Xcode.app"
  if [ -d "$XCODE_APP/Contents/Developer" ] && \
     DEVELOPER_DIR="$XCODE_APP/Contents/Developer" xcrun swift --version >/dev/null 2>&1; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    echo "▸ Using Xcode at $XCODE_APP"
  fi
fi

CONFIG="${CONFIG:-release}"
APP_NAME="Photo Date Guesser"
APP="build/${APP_NAME}.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product PhotoMetadataGuesser
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PhotoMetadataGuesser" "$APP/Contents/MacOS/PhotoMetadataGuesser"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing…"
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --entitlements Resources/PhotoMetadataGuesser.entitlements "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements Resources/PhotoMetadataGuesser.entitlements "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo "✓ Built $APP"
echo "  Open it with:  open \"$APP\""
