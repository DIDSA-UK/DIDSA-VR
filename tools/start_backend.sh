#!/usr/bin/env bash
# Starts a throwaway DIDSA-CAD backend for the e2e tests (tests/ci_e2e.sh) and points this repo's secrets.cfg at it.
# Never the owner's real server or key: the key is a throwaway, the document store is in memory and dies with the process.
#
# Usage (from DIDSA-VR's root, after tools/setup_test_env.sh):
#   tools/start_backend.sh          # start (or reuse) on 127.0.0.1:8000, write secrets.cfg if there is none
#   tools/start_backend.sh stop
#   tools/start_backend.sh restart  # after changing backend code: the server does not reload itself
# The log is $TOOLS_DIR/backend.log.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"
CAD_DIR="${CAD_DIR:-$(cd .. && pwd)/DIDSA-CAD}"
PORT="${PORT:-8000}"
KEY="${CAD_API_KEY:-local-test-key}"
PIDFILE="$TOOLS_DIR/backend.pid"

stop() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then kill "$(cat "$PIDFILE")"; sleep 1; fi
  rm -f "$PIDFILE"
}

case "${1:-start}" in
  stop) stop; echo "stopped"; exit 0 ;;
  restart) stop ;;
esac

if curl -sf -o /dev/null "http://127.0.0.1:$PORT/docs"; then
  echo "a backend already answers on port $PORT (use restart to reload code)"
else
  (cd "$CAD_DIR/backend" && CAD_API_KEY="$KEY" nohup "$TOOLS_DIR/cad-env/bin/python" -m uvicorn app.main:app \
    --host 127.0.0.1 --port "$PORT" > "$TOOLS_DIR/backend.log" 2>&1 & echo $! > "$PIDFILE")
  for i in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/docs"; then echo "backend up after ${i}s"; break; fi
    sleep 1
    [ "$i" = 60 ] && { echo "backend did not come up; see $TOOLS_DIR/backend.log"; tail -20 "$TOOLS_DIR/backend.log"; exit 1; }
  done
fi

if [ ! -f secrets.cfg ]; then
  printf '[backend]\nurl="http://127.0.0.1:%s"\napi_key="%s"\n' "$PORT" "$KEY" > secrets.cfg
  echo "wrote secrets.cfg (git-ignored) for 127.0.0.1:$PORT"
elif ! grep -q "127.0.0.1:$PORT" secrets.cfg; then
  echo "WARNING: secrets.cfg points somewhere else; e2e tests would use THAT server. Move it aside before running tests/ci_e2e.sh."
fi
