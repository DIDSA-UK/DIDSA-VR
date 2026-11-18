#!/usr/bin/env bash
# Installs TwoVoip (github.com/goatchurchprime/two-voip-godot-4, MIT): the Opus voice GDExtension chosen for D9
# (DIDSA-CAD docs/mates-storage-sessions-plan-2026-11-12.md; docs/live-sessions-spikes.md here). Mic capture through Godot's
# AudioServer, Opus encode / decode (libopus 1.5.2), RNNoise. The release carries Android arm64 / arm32 / x86, Linux x86_64,
# Windows x86_64, macOS, iOS and web libraries (~140 MB unpacked), so it is fetched and checked, never committed, like the OpenXR
# Vendors plugin (tools/install_vendors_plugin.sh). For now it goes into the P0 voice spike (spikes/voice/); P3 decides whether the
# app itself takes it (and then CLAUDE.md lists it as the second add-on exception).
# Pinned to one release and checked against its SHA-256, so a changed download is refused.
# Usage (from anywhere):  tools/install_voip_plugin.sh [--force] [destination project folder, default spikes/voice]
#                         VOIP_ZIP=/path/to/TwoVoIP.zip to use a file you already have
set -euo pipefail
VERSION="v6.6.2"   # 16 Nov 2026; needs Godot 4.6 or later (its .gdextension says compatibility_minimum 4.6.0)
SHA256="cce8bc13342897f139c2c4569d2c1352a9971e31e802403927b319b19336cdb3"
URL="https://github.com/goatchurchprime/two-voip-godot-4/releases/download/${VERSION}/TwoVoIP.zip"

cd "$(dirname "$0")/.."
force=""
if [ "${1:-}" = "--force" ]; then force=1; shift; fi
project="${1:-spikes/voice}"
dest="$project/addons/twovoip"
if [ -f "$dest/.installed-version" ] && [ "$(cat "$dest/.installed-version")" = "$VERSION" ] && [ -z "$force" ]; then
  echo "TwoVoip $VERSION is already installed in $dest (use --force to reinstall)."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
zip="${VOIP_ZIP:-$tmp/TwoVoIP.zip}"
if [ -z "${VOIP_ZIP:-}" ]; then
  echo "Downloading $URL"
  curl -fsSL --retry 3 -o "$zip" "$URL"
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$zip" | cut -d' ' -f1)"
else
  actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
fi
if [ "$actual" != "$SHA256" ]; then
  echo "SHA-256 mismatch for TwoVoIP.zip: expected $SHA256, got $actual. Not installing." >&2
  exit 1
fi

unzip -q "$zip" -d "$tmp/x"
src="$tmp/x/project/addons/twovoip"
[ -f "$src/twovoip.gdextension" ] || { echo "The zip does not contain project/addons/twovoip/twovoip.gdextension." >&2; exit 1; }
[ -f "$src/libs/libtwovoip.android.template_release.arm64.so" ] || { echo "The zip has no Android arm64 library." >&2; exit 1; }
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -R "$src" "$dest"
echo "$VERSION" > "$dest/.installed-version"
echo "Installed TwoVoip $VERSION into $dest. Open that project once in the Godot editor so it registers the extension."
