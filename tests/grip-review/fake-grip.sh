#!/bin/bash
# ABOUTME: Stand-in for ~/bin/grip used by tests. Parses -p PORT and the file arg,
# ABOUTME: optionally fails fast if the env var FAKE_GRIP_FAIL_PORT matches the requested port.

set -u

PORT=6419
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PORT="$2"; shift 2 ;;
    -H|--host) shift 2 ;;
    -b|--browser) shift ;;
    --bounding-box|--no-reload) shift ;;
    *) FILE="$1"; shift ;;
  esac
done

# Simulate "port already bound": exit immediately when caller-specified port matches.
if [ -n "${FAKE_GRIP_FAIL_PORT:-}" ] && [ "$PORT" = "$FAKE_GRIP_FAIL_PORT" ]; then
  echo "listen tcp 0.0.0.0:$PORT: bind: address already in use" >&2
  exit 1
fi

# Successful path: print a grip-shaped URL and stay alive until killed.
echo "Serving on http://<lan-ip>:$PORT/$(basename "$FILE")"
exec sleep 3600
