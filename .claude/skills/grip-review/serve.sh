#!/bin/bash
# ABOUTME: Launches ~/bin/grip in the background for a markdown file, prints a non-localhost URL,
# ABOUTME: and tracks the PID in a session-scoped state file so cleanup-grip.sh can reap it.

set -u

pick_port() {
  local sid="${CLAUDE_CODE_SESSION_ID:-no-session}"
  local hex
  hex=$(printf '%s' "$sid" | md5sum | cut -c1-3)
  echo $((6420 + 0x$hex % 1000))
}

if [ "${1:-}" = "--dry-run-port" ]; then
  pick_port
  exit 0
fi

FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "usage: $0 <markdown-file>  (or --dry-run-port for test inspection)" >&2
  exit 2
fi

if [ ! -f "$FILE" ]; then
  echo "grip-review: file not found: $FILE" >&2
  exit 2
fi

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-grip"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/${CLAUDE_CODE_SESSION_ID:-no-session}.pid"
LOG_FILE="$STATE_DIR/${CLAUDE_CODE_SESSION_ID:-no-session}.log"

# Honor GRIP_BIN for tests; default to the user's wrapper.
GRIP="${GRIP_BIN:-$HOME/bin/grip}"

# /proc/$pid/stat field 22 is "starttime" in clock ticks since boot.
# Pairing PID with starttime defends against PID recycling: a recycled
# PID will have a different starttime, so kill-prior and the SessionEnd
# hook won't accidentally signal an unrelated process.
pid_starttime() {
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null
}

# Kill any prior grip from this same Claude session.
# Verify the recorded starttime still matches before signalling — if the
# previous grip died and Linux recycled its PID, the starttime will differ
# and we leave that unrelated process alone.
if [ -f "$PID_FILE" ]; then
  read -r PRIOR_PID PRIOR_START < "$PID_FILE" 2>/dev/null || PRIOR_PID=""
  if [ -n "$PRIOR_PID" ] && [ "$(pid_starttime "$PRIOR_PID")" = "$PRIOR_START" ]; then
    kill "$PRIOR_PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi

PORT=$(pick_port)

URL=""
for ATTEMPT in 0 1 2 3 4; do
  TRY_PORT=$((PORT + ATTEMPT))
  : > "$LOG_FILE"
  "$GRIP" -p "$TRY_PORT" "$FILE" >"$LOG_FILE" 2>&1 &
  GRIP_PID=$!
  sleep 0.5

  if kill -0 "$GRIP_PID" 2>/dev/null; then
    URL=$(grep -oE 'http://[^[:space:]]+' "$LOG_FILE" | head -1)
    if [ -n "$URL" ]; then
      echo "$GRIP_PID $(pid_starttime "$GRIP_PID")" > "$PID_FILE"
      break
    fi
    # Process alive but no URL — kill and treat as failure.
    kill "$GRIP_PID" 2>/dev/null
  fi
  GRIP_PID=""
done

if [ -z "$URL" ]; then
  echo "grip-review: could not launch grip after 5 port attempts starting at $PORT; see $LOG_FILE" >&2
  exit 1
fi

echo "$URL"
