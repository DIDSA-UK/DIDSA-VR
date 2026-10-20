#!/usr/bin/env bash
# Installs the Godot OpenXR Vendors plugin into addons/godotopenxrvendors (git-ignored: 82 MB of native libraries and AARs).
# It is what puts Meta's passthrough, the Quest manifest entries (features, permissions such as com.oculus.permission.USE_SCENE) and the Quest export
# options into a standalone Android build. This is the project's one deliberate exception to "no addons" (CLAUDE.md, docs/android-build.md).
# Pinned to one release and checked against its SHA-256, so a changed download is refused.
# Usage (from anywhere):  tools/install_vendors_plugin.sh [--force]          VENDORS_ZIP=/path/to/godotopenxrvendorsaddon.zip to use a file you already have
set -euo pipefail
VERSION="5.1.0-stable"   # needs Godot 4.6 or later
SHA256="6a838dbdf4115549e4511ebee0da9a5dcc8f9f6258d4cc2f2ee57a907a3e2911"
URL="https://github.com/GodotVR/godot_openxr_vendors/releases/download/${VERSION}/godotopenxrvendorsaddon.zip"

cd "$(dirname "$0")/.."
dest="addons/godotopenxrvendors"
if [ -f "$dest/.installed-version" ] && [ "$(cat "$dest/.installed-version")" = "$VERSION" ] && [ "${1:-}" != "--force" ]; then
  echo "OpenXR Vendors plugin $VERSION is already installed in $dest (use --force to reinstall)."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
zip="${VENDORS_ZIP:-$tmp/addon.zip}"
if [ -z "${VENDORS_ZIP:-}" ]; then
  echo "Downloading $URL"
  curl -fsSL --retry 3 -o "$zip" "$URL"
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$zip" | cut -d' ' -f1)"
else
  actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
fi
if [ "$actual" != "$SHA256" ]; then
  echo "SHA-256 mismatch for the plugin zip: expected $SHA256, got $actual. Not installing." >&2
  exit 1
fi

unzip -q "$zip" -d "$tmp/x"
src="$tmp/x/asset/addons/godotopenxrvendors"
[ -f "$src/plugin.gdextension" ] || { echo "The zip does not contain asset/addons/godotopenxrvendors/plugin.gdextension." >&2; exit 1; }
rm -rf "$dest"
mkdir -p addons
cp -R "$src" "$dest"
echo "$VERSION" > "$dest/.installed-version"
echo "Installed OpenXR Vendors plugin $VERSION into $dest."
echo "Next: open the project in the Godot editor once (it imports the extension), then see docs/android-build.md."
