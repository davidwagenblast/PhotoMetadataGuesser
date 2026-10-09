#!/bin/bash
# One-step build: double-click this file in Finder (or run it in Terminal).
# It checks for Apple's developer tools, builds the app, installs it in
# Applications, and opens it.
#
# Options (Terminal only):
#   --no-install   leave the app in ./build instead of copying it to Applications
#   --no-open      don't launch the app when done
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=1
OPEN=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --no-open) OPEN=0 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done
# CI machines just build.
if [ -n "${CI:-}" ]; then INSTALL=0; OPEN=0; fi

APP_NAME="Photo Date Guesser"
BUILT_APP="build/${APP_NAME}.app"

fail() {
  echo ""
  echo "✗ $1"
  [ -t 0 ] && [ -z "${CI:-}" ] && read -r -p "Press Return to close…" _
  exit 1
}

echo "📸 Building ${APP_NAME}…"
echo ""

# 1. macOS version
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 14 ]; then
  fail "This app needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion))."
fi

# 2. Developer tools (Xcode or the free Command Line Tools)
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "Apple's developer tools are needed to build the app."
  echo "A window will open — click Install, wait for it to finish, then run this again."
  xcode-select --install >/dev/null 2>&1 || true
  fail "Developer tools are not installed yet."
fi

# 3. Build
./scripts/build-app.sh || fail "The build failed. Scroll up to see what went wrong."

# 4. Install
FINAL_APP="$BUILT_APP"
if [ "$INSTALL" = 1 ]; then
  DEST="/Applications"
  if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
  fi
  rm -rf "$DEST/${APP_NAME}.app"
  ditto "$BUILT_APP" "$DEST/${APP_NAME}.app"
  FINAL_APP="$DEST/${APP_NAME}.app"
  echo "✓ Installed in $DEST"
fi

# 5. Open
if [ "$OPEN" = 1 ]; then
  open "$FINAL_APP"
fi

echo ""
echo "🎉 Done! ${APP_NAME} is at: $FINAL_APP"
