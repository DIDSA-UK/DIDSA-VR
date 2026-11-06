#!/usr/bin/env bash
# Installs everything the VR and CAD test suites need on a fresh Linux x86_64 box (a cloud session, a new laptop):
#   Godot 4.7.2 (headless, CI's pinned version), Xvfb + Mesa software GL (render tests), micromamba and the DIDSA-CAD backend's
#   conda environment (pythonocc-core, py-slvs, FastAPI: backend tests and the live backend for e2e), Flutter stable 3.47.9 (the flat app's tests).
# Idempotent: anything already in place is kept. Nothing is installed into either repo; secrets.cfg is not touched.
#
# Usage (from DIDSA-VR's root, DIDSA-CAD checked out next to it as ../DIDSA-CAD):
#   tools/setup_test_env.sh            # everything
#   tools/setup_test_env.sh godot      # one piece: godot | render | backend | flutter
#   TOOLS_DIR=/somewhere tools/setup_test_env.sh
# Then:  source "$TOOLS_DIR/env.sh"   (default TOOLS_DIR=/opt/tools) for GODOT, CAD_PY and Flutter on the PATH.
# What each suite needs and how to run it: docs/gears-and-motion-plan.md, "Test tooling".
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"
CAD_DIR="${CAD_DIR:-$(cd .. && pwd)/DIDSA-CAD}"
GODOT_VERSION=4.7.2 # keep in step with .github/workflows/*.yml
GODOT_BIN="$TOOLS_DIR/Godot_v${GODOT_VERSION}-stable_linux.x86_64"
SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"
mkdir -p "$TOOLS_DIR"

want() { [ $# -eq 0 ] || [ "$1" = all ] || [ "$1" = "$2" ]; }

get_godot() {
  if [ -x "$GODOT_BIN" ]; then echo "godot: present"; return; fi
  curl -sSfL --retry 3 -o "$TOOLS_DIR/godot.zip" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  unzip -oq "$TOOLS_DIR/godot.zip" -d "$TOOLS_DIR" && rm "$TOOLS_DIR/godot.zip"
  chmod +x "$GODOT_BIN"
  "$GODOT_BIN" --version
}

get_render() {
  if command -v Xvfb >/dev/null && dpkg -s libgl1-mesa-dri >/dev/null 2>&1 && dpkg -s libglu1-mesa >/dev/null 2>&1; then
    echo "render: present"; return
  fi
  $SUDO apt-get update -q
  $SUDO apt-get install -y -q --no-install-recommends xvfb libgl1-mesa-dri libglu1-mesa xauth
}

get_backend() {
  local mm="$TOOLS_DIR/bin/micromamba"
  if [ ! -x "$mm" ]; then
    mkdir -p "$TOOLS_DIR/bin"
    # micro.mamba.pm is not reachable from every sandbox; the GitHub release is the same binary.
    curl -sSfL --retry 3 -o "$mm" https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-64
    chmod +x "$mm"
  fi
  if [ -x "$TOOLS_DIR/cad-env/bin/python" ]; then echo "backend env: present"; else
    [ -f "$CAD_DIR/backend/environment.yml" ] || { echo "no $CAD_DIR/backend/environment.yml (set CAD_DIR)"; exit 1; }
    MAMBA_ROOT_PREFIX="$TOOLS_DIR/mamba" "$mm" create -y -q -p "$TOOLS_DIR/cad-env" -f "$CAD_DIR/backend/environment.yml"
  fi
  "$TOOLS_DIR/cad-env/bin/python" -c "import OCC, py_slvs, fastapi; print('backend env ok, OCCT', OCC.VERSION)"
  # DIDSA-CAD tools/motion_vectors/generate.py --check passes under the SYSTEM python's numpy and fails in the backend env
  # (float rounding, docs/width-mate-plan.md "Environment note"), so the system python needs numpy too.
  python3 -c "import numpy" 2>/dev/null || python3 -m pip install -q numpy || python3 -m pip install -q --break-system-packages numpy
}

get_flutter() {
  # Flutter stable, pinned to the version DIDSA-CAD's CI uses (.github/workflows/client-verify.yml): client/'s flutter_scene needs >= 3.47.0.
  # A leftover SDK of another version (e.g. an old master clone) is replaced.
  local want_ver=3.47.9
  if [ -d "$TOOLS_DIR/flutter" ] && [ "$(git -C "$TOOLS_DIR/flutter" describe --tags --exact-match 2>/dev/null)" != "$want_ver" ]; then
    rm -rf "$TOOLS_DIR/flutter"
  fi
  if [ ! -x "$TOOLS_DIR/flutter/bin/flutter" ]; then
    git clone -q --depth 1 -b "$want_ver" https://github.com/flutter/flutter.git "$TOOLS_DIR/flutter"
  fi
  "$TOOLS_DIR/flutter/bin/flutter" --version
  if [ -d "$CAD_DIR/client" ]; then (cd "$CAD_DIR/client" && "$TOOLS_DIR/flutter/bin/flutter" pub get); fi
}

want "${1:-all}" godot && get_godot
want "${1:-all}" render && get_render
want "${1:-all}" backend && get_backend
want "${1:-all}" flutter && get_flutter

cat > "$TOOLS_DIR/env.sh" <<ENV
export GODOT="$GODOT_BIN"
export CAD_PY="$TOOLS_DIR/cad-env/bin/python"
export PATH="$TOOLS_DIR/flutter/bin:$TOOLS_DIR/bin:\$PATH"
ENV
echo "done: source $TOOLS_DIR/env.sh"
