#!/bin/bash
# ABOUTME: Claude Code SessionEnd hook — reaps the grip process spawned by the
# ABOUTME: grip-review skill in this session and removes its PID file.

set -u

# SessionEnd JSON arrives on stdin; we don't need any of its fields because
# CLAUDE_CODE_SESSION_ID is also in the environment. Drain stdin so the
# upstream caller doesn't block on a closed pipe.
cat >/dev/null 2>&1 || true

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-grip"
PID_FILE="$STATE_DIR/${CLAUDE_CODE_SESSION_ID:-no-session}.pid"

if [ -f "$PID_FILE" ]; then
  # PID file format: one line per live grip, "PID STARTTIME HOST PORT ROOT".
  # A session can hold several grips (one per directory served), so reap every
  # line. Trailing fields beyond STARTTIME are only used by serve.sh's reuse
  # path; ignore them here.
  while read -r PID STARTTIME REST; do
    [ -z "$PID" ] && continue
    [ -z "$STARTTIME" ] && continue
    ACTUAL=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)
    if [ "$ACTUAL" = "$STARTTIME" ]; then
      kill "$PID" 2>/dev/null || true
    fi
  done < "$PID_FILE"
  rm -f "$PID_FILE"
fi

# Also clear the log file to keep ~/.cache tidy.
rm -f "$STATE_DIR/${CLAUDE_CODE_SESSION_ID:-no-session}.log"

exit 0
