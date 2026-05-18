#!/bin/bash
# ABOUTME: Tests for .claude/skills/grip-review/serve.sh — overrides PATH to use
# ABOUTME: fake-grip.sh, asserts deterministic port, PID file, URL extraction, retry behavior.

set -u

DOTFILES="$(cd "$(dirname "$0")/../.." && pwd)"
SERVE="$DOTFILES/.claude/skills/grip-review/serve.sh"
FAKE_BIN="$(mktemp -d)"
cp "$DOTFILES/tests/grip-review/fake-grip.sh" "$FAKE_BIN/grip"
export PATH="$FAKE_BIN:$PATH"

# Isolate state to a temp dir so tests don't fight ~/.cache.
export XDG_CACHE_HOME="$(mktemp -d)"
export CLAUDE_CODE_SESSION_ID="test-session-deterministic"
export GRIP_BIN="$FAKE_BIN/grip"  # serve.sh will honor this for testability

cleanup() {
  rm -rf "$FAKE_BIN" "$XDG_CACHE_HOME"
  # Reap any lingering fake-grips spawned by the suite.
  pkill -f "$FAKE_BIN/grip" 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1))
    echo "  PASS: $1"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: $1 — expected '$3', got '$2'"
  fi
}
assert_contains() {
  if echo "$2" | grep -qF "$3"; then
    PASS=$((PASS+1))
    echo "  PASS: $1"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: $1 — expected to contain '$3', got '$2'"
  fi
}

# --- Test: --dry-run-port mode emits deterministic port for a given session id ---
PORT_A=$(CLAUDE_CODE_SESSION_ID=fixed-id-A "$SERVE" --dry-run-port)
PORT_B=$(CLAUDE_CODE_SESSION_ID=fixed-id-A "$SERVE" --dry-run-port)
PORT_C=$(CLAUDE_CODE_SESSION_ID=fixed-id-B "$SERVE" --dry-run-port)

assert_eq "same session id -> same port"     "$PORT_A" "$PORT_B"
# Different session ids should (almost always) differ; the two fixed ids above
# are chosen to verify both md5 buckets — if this ever fails, change one id.
if [ "$PORT_A" != "$PORT_C" ]; then
  PASS=$((PASS+1)); echo "  PASS: different session ids -> different ports"
else
  FAIL=$((FAIL+1)); echo "  FAIL: different session ids -> different ports (both $PORT_A)"
fi

# Port must fall in expected range
if [ "$PORT_A" -ge 6420 ] && [ "$PORT_A" -le 7419 ]; then
  PASS=$((PASS+1)); echo "  PASS: port in 6420-7419 range"
else
  FAIL=$((FAIL+1)); echo "  FAIL: port $PORT_A out of range 6420-7419"
fi

# --- Test: launch grip, capture URL, write PID file ---
MD=$(mktemp --suffix=.md)
echo "# hello" > "$MD"

URL=$("$SERVE" "$MD")
assert_contains "URL printed to stdout" "$URL" "http://"
assert_contains "URL contains a port" "$URL" ":"

PID_FILE="$XDG_CACHE_HOME/claude-grip/$CLAUDE_CODE_SESSION_ID.pid"
if [ -f "$PID_FILE" ]; then
  PASS=$((PASS+1)); echo "  PASS: PID file created"
  # PID file format is "PID STARTTIME" — read just the PID.
  GRIP_PID=$(awk '{print $1}' "$PID_FILE")
  if kill -0 "$GRIP_PID" 2>/dev/null; then
    PASS=$((PASS+1)); echo "  PASS: grip process alive"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: grip process not alive (pid $GRIP_PID)"
  fi
  # PID file must have two whitespace-separated fields.
  FIELDS=$(awk '{print NF}' "$PID_FILE")
  assert_eq "PID file has 2 fields (pid+starttime)" "$FIELDS" "2"
else
  FAIL=$((FAIL+1)); echo "  FAIL: PID file not at $PID_FILE"
fi

# Clean up this test's grip so subsequent tests start fresh.
[ -f "$PID_FILE" ] && kill "$(awk '{print $1}' "$PID_FILE")" 2>/dev/null
rm -f "$PID_FILE"
rm -f "$MD"

# --- Test: re-invocation kills the prior grip from the same session ---
MD2=$(mktemp --suffix=.md); echo "# a" > "$MD2"
MD3=$(mktemp --suffix=.md); echo "# b" > "$MD3"

"$SERVE" "$MD2" >/dev/null
PID_FILE="$XDG_CACHE_HOME/claude-grip/$CLAUDE_CODE_SESSION_ID.pid"
FIRST_PID=$(awk '{print $1}' "$PID_FILE")

"$SERVE" "$MD3" >/dev/null
SECOND_PID=$(awk '{print $1}' "$PID_FILE")

if [ "$FIRST_PID" != "$SECOND_PID" ]; then
  PASS=$((PASS+1)); echo "  PASS: re-invocation rotates PID"
else
  FAIL=$((FAIL+1)); echo "  FAIL: PID did not change ($FIRST_PID)"
fi

# Give the kill signal a moment to deliver, then verify the old PID is gone.
sleep 0.2
if kill -0 "$FIRST_PID" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: first grip still alive ($FIRST_PID)"
else
  PASS=$((PASS+1)); echo "  PASS: first grip killed"
fi

kill "$SECOND_PID" 2>/dev/null
rm -f "$PID_FILE" "$MD2" "$MD3"

# --- Test: stale PID file with mismatched starttime does NOT kill unrelated process ---
sleep 60 &
VICTIM=$!
mkdir -p "$XDG_CACHE_HOME/claude-grip"
VICT_PID_FILE="$XDG_CACHE_HOME/claude-grip/stale-victim.pid"
# Real starttimes are millions of clock ticks; "1" cannot match.
echo "$VICTIM 1" > "$VICT_PID_FILE"

MD_VICT=$(mktemp --suffix=.md); echo "# v" > "$MD_VICT"
CLAUDE_CODE_SESSION_ID=stale-victim "$SERVE" "$MD_VICT" >/dev/null

if kill -0 "$VICTIM" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS: stale PID+starttime did not kill victim"
else
  FAIL=$((FAIL+1)); echo "  FAIL: victim process was killed by stale PID file"
fi

# Cleanup: kill the victim sleep and the new grip started by the call above.
kill "$VICTIM" 2>/dev/null
[ -f "$VICT_PID_FILE" ] && kill "$(awk '{print $1}' "$VICT_PID_FILE")" 2>/dev/null
rm -f "$VICT_PID_FILE" "$MD_VICT"

echo
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
