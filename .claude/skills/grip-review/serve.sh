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

# Canonical absolute directory grip will be (or already is) serving from.
# go-grip serves any sibling .md under that directory at /<relpath>, so a
# prior grip launched in the same dir can be reused for a different file.
TARGET_DIR=$(cd "$(dirname "$FILE")" && pwd -P)
TARGET_REL=$(basename "$FILE")

# /proc/$pid/stat field 22 is "starttime" in clock ticks since boot.
# Pairing PID with starttime defends against PID recycling: a recycled
# PID will have a different starttime, so kill-prior and the SessionEnd
# hook won't accidentally signal an unrelated process.
pid_starttime() {
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null
}

# Percent-encode the path component so chars like '#', '?', space, and
# multi-byte UTF-8 in sibling filenames don't truncate or mangle the URL.
# The launch path emits go-grip's own already-escaped URL; the reuse path
# constructs the URL itself and must match that escaping. Pure-bash
# substring iteration mis-encodes multi-byte chars in UTF-8 locales (it
# emits the Unicode codepoint, not the bytes), so we delegate to
# urllib.parse.quote.
urlencode() {
  python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# If a prior grip from this session is alive and was launched in the same
# directory, reuse it: just emit a fresh URL with the new file's relpath.
# Otherwise kill it (different dir means we'd need to relaunch anyway).
if [ -f "$PID_FILE" ]; then
  read -r PRIOR_PID PRIOR_START PRIOR_HOST PRIOR_PORT PRIOR_DIR < "$PID_FILE" 2>/dev/null || PRIOR_PID=""
  if [ -n "$PRIOR_PID" ] && [ "$(pid_starttime "$PRIOR_PID")" = "$PRIOR_START" ]; then
    if [ "$PRIOR_DIR" = "$TARGET_DIR" ] && [ -n "$PRIOR_HOST" ] && [ -n "$PRIOR_PORT" ]; then
      echo "http://${PRIOR_HOST}:${PRIOR_PORT}/$(urlencode "$TARGET_REL")"
      exit 0
    fi
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
      # Parse host and port out of the URL so subsequent same-dir invocations
      # can rebuild URLs for sibling files without relaunching grip.
      URL_HOSTPORT=${URL#http://}
      URL_HOSTPORT=${URL_HOSTPORT%%/*}
      URL_HOST=${URL_HOSTPORT%:*}
      URL_PORT=${URL_HOSTPORT##*:}
      echo "$GRIP_PID $(pid_starttime "$GRIP_PID") $URL_HOST $URL_PORT $TARGET_DIR" > "$PID_FILE"
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
