#!/usr/bin/env bash
# ABOUTME: Smoke-test harness for bin/screen wrapper, including the GNU
# ABOUTME: screen fallback path. Stubs tmux and screen via env-var overrides.

set -uo pipefail

DOTFILES=$(cd "$(dirname "$0")/../.." && pwd)
HARNESS_DIR=$(cd "$(dirname "$0")" && pwd)

FAILED=0
PASSED=0

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok %s\n' "$label"
    PASSED=$((PASSED+1))
  else
    printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual"
    FAILED=$((FAILED+1))
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok %s\n' "$label"
    PASSED=$((PASSED+1))
  else
    printf '  FAIL %s\n    needle:   %s\n    haystack: %s\n' "$label" "$needle" "$haystack"
    FAILED=$((FAILED+1))
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  ok %s\n' "$label"
    PASSED=$((PASSED+1))
  else
    printf '  FAIL %s (unexpected match)\n    needle:   %s\n    haystack: %s\n' "$label" "$needle" "$haystack"
    FAILED=$((FAILED+1))
  fi
}

setup_test() {
  TMPDIR_TEST=$(mktemp -d -t screen-test.XXXXXX)
  cp "$HARNESS_DIR/fake-tmux.sh" "$TMPDIR_TEST/tmux"
  cp "$HARNESS_DIR/fake-screen.sh" "$TMPDIR_TEST/screen"
  chmod +x "$TMPDIR_TEST/tmux" "$TMPDIR_TEST/screen"
  export TMUX_SCREEN_COMPAT_TMUX="$TMPDIR_TEST/tmux"
  export TMUX_SCREEN_COMPAT_REAL_SCREEN="$TMPDIR_TEST/screen"
  export STUB_TMUX_LOG="$TMPDIR_TEST/tmux.log"
  export STUB_SCREEN_LOG="$TMPDIR_TEST/screen.log"
  : > "$STUB_TMUX_LOG"
  : > "$STUB_SCREEN_LOG"
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=""
  export STUB_TMUX_SESSIONS STUB_SCREEN_LS
}

teardown_test() {
  rm -rf "$TMPDIR_TEST"
  unset TMUX_SCREEN_COMPAT_TMUX TMUX_SCREEN_COMPAT_REAL_SCREEN
  unset STUB_TMUX_LOG STUB_SCREEN_LOG STUB_TMUX_SESSIONS STUB_SCREEN_LS
}

# Smoke: harness wires up correctly.
test_harness_smoke() {
  setup_test
  out=$("$DOTFILES/bin/screen" --help 2>&1)
  assert_contains "$out" "tmux-backed screen compatibility wrapper" "harness smoke: --help works"
  teardown_test
}

test_attach_when_tmux_has_session() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -r foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$tmux_log" "attach-session -t foo" "tmux attach-session was invoked"
  assert_not_contains "$screen_log" "-r" "screen -r was not invoked"
  teardown_test
}

test_fallback_when_tmux_missing_screen_present() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo\t(Detached)\n1 Socket in /run/screen.\n'
  "$DOTFILES/bin/screen" -r foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$screen_log" "screen -r foo" "screen -r foo was invoked"
  assert_not_contains "$tmux_log" "attach-session -t foo" "tmux attach-session was NOT invoked"
  teardown_test
}

for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
