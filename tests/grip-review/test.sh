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

echo "(no tests yet — added by later tasks)"

echo
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
