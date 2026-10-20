#!/usr/bin/env bash
# Lets the Android build send plain http:// (a DIDSA-CAD server on the LAN): copies tools/android/network_security_config.xml into the Gradle build
# template (android/build, installed by the editor's Project > Install Android Build Template) and points the manifest's <application> at it.
# Only run this if a headset test shows plain http is blocked; see docs/android-build.md. Safe to run twice. `--remove` takes it back out.
# Usage:  tools/android/apply_cleartext_overlay.sh [--remove] [path/to/android/build]
set -euo pipefail
remove=0
if [ "${1:-}" = "--remove" ]; then remove=1; shift; fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
build="${1:-$root/android/build}"
manifest="$build/AndroidManifest.xml"
xml_dir="$build/res/xml"
attr='android:networkSecurityConfig="@xml/network_security_config"'

if [ ! -f "$manifest" ]; then
  echo "No $manifest: install the Android build template first (Godot editor: Project > Install Android Build Template)." >&2
  exit 1
fi

if [ "$remove" = 1 ]; then
  perl -0pi -e 's/\s*android:networkSecurityConfig="\@xml\/network_security_config"//g' "$manifest"
  rm -f "$xml_dir/network_security_config.xml"
  echo "Cleartext overlay removed from $build."
  exit 0
fi

mkdir -p "$xml_dir"
cp "$root/tools/android/network_security_config.xml" "$xml_dir/network_security_config.xml"
if grep -q 'android:networkSecurityConfig' "$manifest"; then
  echo "The manifest already has a networkSecurityConfig; left as it is."
else
  perl -0pi -e 's/<application(\s)/<application android:networkSecurityConfig="\@xml\/network_security_config"$1/' "$manifest"
  grep -q "$attr" "$manifest" || { echo "Could not find <application in $manifest to patch." >&2; exit 1; }
fi
echo "Cleartext overlay applied to $build: plain http:// to a LAN server is now allowed by Android."
