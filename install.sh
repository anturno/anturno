#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Anturno
#
# Installs Anturno on a Mac (Apple silicon) or on Linux (x64):
#
#     curl -fsSL https://download.anturno.cloud/install.sh | sh
#
# It downloads the newest release from github.com/anturno/anturno, checks it
# against the release's SHA256SUMS, and installs it:
#
#   Mac     Anturno.app into /Applications, or ~/Applications when that isn't
#           writable, then opens it. The app is not notarized; curl doesn't
#           mark what it downloads with com.apple.quarantine, so Gatekeeper
#           doesn't stop its first open. Its updates download inside the app.
#   Linux   the .deb through apt where there is apt (it asks for your password
#           once), else the AppImage into ~/.local/share/anturno with a menu
#           entry and an `anturno` command. Both update themselves.
#
# Environment:
#   ANTURNO_RELEASES     where the files are (default: the newest release)
#   ANTURNO_APPLICATIONS the Mac folder to install into
#   ANTURNO_NO_OPEN=1    don't open the app afterwards
#
# Published by .github/workflows/desktop-release.yml from apps/desktop/download.

set -eu

RELEASES="${ANTURNO_RELEASES:-https://github.com/anturno/anturno/releases/latest/download}"
SITE="https://download.anturno.cloud"
BUNDLE_ID="factory.anturno.desktop"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'Anturno: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "needs curl."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fetch() {
  curl -fL --retry 3 --progress-bar -o "$tmp/$1" "$RELEASES/$1" || fail "couldn't download $1."
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# Downloads a release file and stops unless it matches the release's SHA256SUMS.
download() {
  [ -f "$tmp/SHA256SUMS" ] || curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$RELEASES/SHA256SUMS" || fail "couldn't read the release's checksums."
  say "Downloading $1"
  fetch "$1"
  expected="$(grep "  $1\$" "$tmp/SHA256SUMS" | cut -d ' ' -f 1)"
  [ -n "$expected" ] || fail "the release has no checksum for $1."
  [ "$(sha256 "$tmp/$1")" = "$expected" ] || fail "$1 doesn't match its checksum. Nothing was installed."
}

install_mac() {
  # A shell under Rosetta says x86_64 on Apple silicon too.
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] || fail "needs a Mac with Apple silicon."
  major="$(sw_vers -productVersion | cut -d . -f 1)"
  [ "$major" -ge 12 ] || fail "needs macOS 12 or later."

  dest="${ANTURNO_APPLICATIONS:-/Applications}"
  if [ -z "${ANTURNO_APPLICATIONS:-}" ] && [ ! -w "$dest" ]; then
    dest="$HOME/Applications"
  fi
  mkdir -p "$dest"
  app="$dest/Anturno.app"

  # Only the copy this replaces needs to be closed (-i: the earlier app is anturno.app).
  if pgrep -qif "$app/Contents/MacOS/"; then
    fail "quit Anturno first, then run this again."
  fi

  download Anturno-mac-arm64.zip
  /usr/bin/ditto -x -k "$tmp/Anturno-mac-arm64.zip" "$tmp/unpacked"
  [ -d "$tmp/unpacked/Anturno.app" ] || fail "the download holds no Anturno.app."

  # The earlier anturno app has the same name to the Mac (anturno.app): this replaces it.
  if [ -d "$app" ]; then
    id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
    [ "$id" = "$BUNDLE_ID" ] || say "Replacing the earlier anturno app in $dest"
    rm -rf "$app"
  fi
  /usr/bin/ditto "$tmp/unpacked/Anturno.app" "$app"
  /usr/bin/xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

  say "Installed Anturno in $dest"
  [ "${ANTURNO_NO_OPEN:-}" = 1 ] || open "$app"
}

install_deb() {
  download Anturno-linux-amd64.deb
  # apt reads a local package as its own user: the folder must be readable.
  chmod 755 "$tmp"
  chmod 644 "$tmp/Anturno-linux-amd64.deb"
  # Under `curl | sh` the script is stdin: apt mustn't read it. sudo asks on the terminal all the same.
  if [ "$(id -u)" = 0 ]; then
    apt-get install -y "$tmp/Anturno-linux-amd64.deb" </dev/null
  else
    say "Installing with apt: it asks for your password."
    sudo apt-get install -y "$tmp/Anturno-linux-amd64.deb" </dev/null
  fi
  say "Installed Anturno. Open it from your app menu."
}

install_appimage() {
  home="${XDG_DATA_HOME:-$HOME/.local/share}"
  dir="$home/anturno"
  mkdir -p "$dir" "$HOME/.local/bin" "$home/applications" "$home/icons/hicolor/256x256/apps"

  download Anturno-linux-x86_64.AppImage
  chmod 755 "$tmp/Anturno-linux-x86_64.AppImage"
  mv -f "$tmp/Anturno-linux-x86_64.AppImage" "$dir/Anturno.AppImage"
  ln -sf "$dir/Anturno.AppImage" "$HOME/.local/bin/anturno"
  curl -fsL -o "$home/icons/hicolor/256x256/apps/anturno.png" "$SITE/icon.png" || true
  cat >"$home/applications/anturno.desktop" <<EOF
[Desktop Entry]
Name=Anturno
Comment=The control plane for your coding agents
Exec="$dir/Anturno.AppImage" %U
Icon=anturno
Type=Application
Categories=Development;
StartupWMClass=anturno-factory
EOF

  say "Installed Anturno in $dir. Open it from your app menu, or run: anturno"
  if ! (ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'); then
    say "AppImages need FUSE 2, which this system seems to lack: install libfuse2 (libfuse2t64, fuse-libs or fuse2, by distro)."
  fi
}

case "$(uname -s)" in
  Darwin) install_mac ;;
  Linux)
    [ "$(uname -m)" = x86_64 ] || fail "is built for x64 Linux only, for now."
    if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
      install_deb
    else
      install_appimage
    fi
    ;;
  *) fail "runs on macOS and Linux." ;;
esac
