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

echo
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
