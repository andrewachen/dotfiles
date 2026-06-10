#!/bin/bash
# ABOUTME: Launches ~/bin/grip in the background for a markdown file, prints a non-localhost URL,
# ABOUTME: and tracks each grip in a session-scoped state file so cleanup-grip.sh can reap them.

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

# Canonical absolute file path and its directory.
FDIR=$(cd "$(dirname "$FILE")" && pwd -P)
FABS="$FDIR/$(basename "$FILE")"

# go-grip roots its file server at path.Dir(arg) and serves that whole subtree.
# The superpowers workflow writes specs to docs/superpowers/specs/ and plans to
# docs/superpowers/plans/ — different directories under a shared ancestor. To let
# Andrew view a spec and its plan at the same time, root ONE grip at that common
# ancestor (docs/superpowers) so both are served at /specs/.. and /plans/.. by a
# single daemon. Any other markdown roots at its own directory.
#
# ROOT is the directory the grip's file server is rooted at. ARG is what we hand
# go-grip; path.Dir(ARG) must equal ROOT (passing the specs/plans dir roots one
# level up at the ancestor; passing the file itself roots at the file's dir).
if { [ "$(basename "$FDIR")" = "specs" ] || [ "$(basename "$FDIR")" = "plans" ]; } \
   && [ "$(basename "$(dirname "$FDIR")")" = "superpowers" ]; then
  ROOT=$(dirname "$FDIR")
  ARG="$FDIR"
else
  ROOT="$FDIR"
  ARG="$FABS"
fi

# /proc/$pid/stat field 22 is "starttime" in clock ticks since boot.
# Pairing PID with starttime defends against PID recycling: a recycled
# PID will have a different starttime, so reuse-pruning and the SessionEnd
# hook won't accidentally signal an unrelated process.
pid_starttime() {
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null
}

# Percent-encode the path so chars like '#', '?', space, and multi-byte UTF-8
# in filenames don't truncate or mangle the URL. safe="/" keeps the path
# separators intact while encoding everything within each segment. Pure-bash
# substring iteration mis-encodes multi-byte chars in UTF-8 locales (it emits
# the Unicode codepoint, not the bytes), so we delegate to urllib.parse.quote.
urlpath() {
  python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe="/"))' "$1"
}

# True if directory $1 is an ancestor-or-equal of file $2 (so a grip rooted at
# $1 already serves $2).
covers() {
  case "$2" in
    "$1"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Walk the existing session grips: keep the live ones, drop the dead (pruning
# the PID file), and if any live grip already covers this file, reuse it.
KEEP=""
REUSE_HOST=""
REUSE_PORT=""
REUSE_ROOT=""
USED_PORTS=" "
if [ -f "$PID_FILE" ]; then
  while read -r P_PID P_START P_HOST P_PORT P_ROOT; do
    [ -z "$P_PID" ] && continue
    if [ "$(pid_starttime "$P_PID")" != "$P_START" ]; then
      continue  # dead or recycled — prune
    fi
    KEEP="${KEEP}${P_PID} ${P_START} ${P_HOST} ${P_PORT} ${P_ROOT}
"
    USED_PORTS="${USED_PORTS}${P_PORT} "
    if [ -z "$REUSE_HOST" ] && covers "$P_ROOT" "$FABS"; then
      REUSE_HOST="$P_HOST"; REUSE_PORT="$P_PORT"; REUSE_ROOT="$P_ROOT"
    fi
  done < "$PID_FILE"
fi

# Rewrite the PID file with only the live grips.
printf '%s' "$KEEP" > "$PID_FILE"

if [ -n "$REUSE_HOST" ]; then
  REL=${FABS#"$REUSE_ROOT"/}
  echo "http://${REUSE_HOST}:${REUSE_PORT}/$(urlpath "$REL")"
  exit 0
fi

PORT=$(pick_port)

URL=""
for ATTEMPT in 0 1 2 3 4 5 6 7 8 9; do
  TRY_PORT=$((PORT + ATTEMPT))
  case "$USED_PORTS" in
    *" $TRY_PORT "*) continue ;;  # already held by a live grip this session
  esac
  : > "$LOG_FILE"
  "$GRIP" -p "$TRY_PORT" "$ARG" >"$LOG_FILE" 2>&1 &
  GRIP_PID=$!
  sleep 0.5

  if kill -0 "$GRIP_PID" 2>/dev/null; then
    # Parse only the host from go-grip's banner; we already know the port, and
    # the banner path points at ARG (a directory in the superpowers case), not
    # the file we want to surface — so we build the file URL ourselves.
    HOSTPORT=$(grep -oE 'http://[^/[:space:]]+' "$LOG_FILE" | head -1)
    HOSTPORT=${HOSTPORT#http://}
    HOST=${HOSTPORT%:*}
    if [ -n "$HOST" ]; then
      printf '%s %s %s %s %s\n' "$GRIP_PID" "$(pid_starttime "$GRIP_PID")" "$HOST" "$TRY_PORT" "$ROOT" >> "$PID_FILE"
      REL=${FABS#"$ROOT"/}
      URL="http://${HOST}:${TRY_PORT}/$(urlpath "$REL")"
      break
    fi
    # Process alive but no parseable host — kill and treat as failure.
    kill "$GRIP_PID" 2>/dev/null
  fi
  GRIP_PID=""
done

if [ -z "$URL" ]; then
  echo "grip-review: could not launch grip after 10 port attempts starting at $PORT; see $LOG_FILE" >&2
  exit 1
fi

echo "$URL"
