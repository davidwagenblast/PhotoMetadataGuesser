#!/bin/bash
# Installs Photo Date Guesser on this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/davidwagenblast/PhotoMetadataGuesser/main/install.sh | bash
#
# Downloads the latest source, builds the app, puts it in Applications and opens it.
# Needs macOS 14+ and Apple's free developer tools (it offers to install them).
#
# Options (environment variables):
#   PDG_BRANCH=name     build a different branch (default: main)
#   PDG_NO_OPEN=1       don't open the app when done

# Everything is inside main() so a partially downloaded script never runs.
main() {
  set -euo pipefail

  local repo="davidwagenblast/PhotoMetadataGuesser"
  local branch="${PDG_BRANCH:-main}"
  local app_name="Photo Date Guesser"

  say() { printf '%s\n' "$*"; }
  fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

  say "📸 Installing ${app_name}…"

  [ "$(uname -s)" = "Darwin" ] || fail "This app only runs on macOS."
  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$macos_major" -ge 14 ] || fail "${app_name} needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion))."

  if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    fail "Apple's developer tools are needed. A window should have opened — click Install, wait for it to finish, then run the install command again."
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  say "▸ Downloading the source (${branch})…"
  curl -fsSL --retry 3 -o "$tmp/source.tar.gz" "https://github.com/${repo}/archive/refs/heads/${branch}.tar.gz" \
    || fail "Couldn't download the source. Check your internet connection."
  mkdir -p "$tmp/source"
  tar -xzf "$tmp/source.tar.gz" -C "$tmp/source" --strip-components 1

  say "▸ Building (this takes a minute or two)…"
  (cd "$tmp/source" && ./scripts/build-app.sh </dev/null) || fail "The build failed. Scroll up to see what went wrong."
  local built="$tmp/source/build/${app_name}.app"

  local dest="/Applications"
  if [ ! -w "$dest" ]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
  fi
  local target="$dest/${app_name}.app"

  # Quit a running copy so it can be replaced.
  osascript -e "tell application \"${app_name}\" to quit" >/dev/null 2>&1 || true

  say "▸ Installing in ${dest}…"
  rm -rf "$target"
  ditto "$built" "$target"

  say ""
  say "🎉 ${app_name} is installed at: $target"
  if [ -z "${PDG_NO_OPEN:-}" ]; then
    open "$target"
    say "   It's opening now. Click Allow when it asks to use your Photos library."
  fi
  say "   To update later, just run the same install command again."
}

main "$@"
