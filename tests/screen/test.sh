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

test_R_does_not_fall_back() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo\t(Detached)\n'
  "$DOTFILES/bin/screen" -R foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$tmux_log" "new-session -A -s foo" "tmux new-session -A was invoked"
  assert_not_contains "$screen_log" "screen -R" "screen -R was NOT invoked"
  teardown_test
}

test_bare_r_does_not_fall_back() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo\t(Detached)\n'
  "$DOTFILES/bin/screen" -r >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$tmux_log" "attach-session" "tmux attach-session (no -t) was invoked"
  assert_not_contains "$tmux_log" "-t " "tmux attach-session had no -t"
  assert_eq "$(wc -c < "$STUB_SCREEN_LOG" | tr -d ' ')" "0" "screen log is empty (probe never ran)"
  teardown_test
}

test_d_r_falls_back() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo\t(Detached)\n'
  "$DOTFILES/bin/screen" -d -r foo >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$screen_log" "screen -d -r foo" "screen -d -r foo was invoked"
  teardown_test
}

test_D_r_falls_back() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo\t(Detached)\n'
  "$DOTFILES/bin/screen" -D -r foo >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$screen_log" "screen -D -r foo" "screen -D -r foo was invoked"
  teardown_test
}

test_neither_has_session() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -r foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$tmux_log" "attach-session -t foo" "tmux attach-session -t foo was invoked (today's error path)"
  assert_contains "$screen_log" "screen -ls" "screen -ls probe ran"
  assert_not_contains "$screen_log" "screen -r" "screen -r was NOT invoked"
  teardown_test
}

test_screen_missing() {
  setup_test
  STUB_TMUX_SESSIONS=""
  rm -f "$TMPDIR_TEST/screen"
  "$DOTFILES/bin/screen" -r foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "attach-session -t foo" "tmux attach-session was invoked despite missing screen"
  teardown_test
}

test_self_recursion_guard() {
  setup_test
  if ! command -v timeout >/dev/null 2>&1; then
    printf '  FAIL self-recursion: timeout(1) required to test the guard\n'
    FAILED=$((FAILED+1))
    teardown_test
    return
  fi
  STUB_TMUX_SESSIONS=""
  # Replace screen with a symlink to the wrapper itself.
  rm -f "$TMPDIR_TEST/screen"
  ln -sf "$DOTFILES/bin/screen" "$TMPDIR_TEST/screen"
  # Replace tmux stub so list-sessions emits screen-format output containing foo.
  cat > "$TMPDIR_TEST/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${STUB_TMUX_LOG:-}" ]]; then
    printf 'tmux'
    for arg in "$@"; do printf ' %q' "$arg"; done
    printf '\n'
fi >> "${STUB_TMUX_LOG:-/dev/null}"
case "${1:-}" in
    has-session) exit 1 ;;
    list-sessions) printf '\t12345.foo\t(Detached)\n'; exit 0 ;;
    *) exit 0 ;;
esac
EOF
  chmod +x "$TMPDIR_TEST/tmux"
  set +e
  timeout 5 "$DOTFILES/bin/screen" -r foo >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" == "124" ]]; then
    printf '  FAIL self-recursion: timeout fired, wrapper looped\n'
    FAILED=$((FAILED+1))
  else
    printf '  ok self-recursion: did not loop (rc=%s)\n' "$rc"
    PASSED=$((PASSED+1))
  fi
  teardown_test
}

test_regex_special_name() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo.bar\t(Detached)\n'
  "$DOTFILES/bin/screen" -r "foo.bar" >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$screen_log" "screen -r foo.bar" "literal-match worked for foo.bar"
  teardown_test
}

test_regex_special_name_no_false_positive() {
  setup_test
  STUB_TMUX_SESSIONS=""
  # screen has a session named "fooXbar" — must NOT match query "foo.bar"
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.fooXbar\t(Detached)\n'
  "$DOTFILES/bin/screen" -r "foo.bar" >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_not_contains "$screen_log" "screen -r foo.bar" "literal-match did NOT match fooXbar against foo.bar"
  teardown_test
}

test_prefix_match_falls_back() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.whereuat\t(Detached)\n'
  "$DOTFILES/bin/screen" -r "whe" >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$screen_log" "screen -r whe" "prefix 'whe' matched 'whereuat' and handed off to GNU screen"
  teardown_test
}

test_non_prefix_substring_does_not_match() {
  setup_test
  STUB_TMUX_SESSIONS=""
  # 'eua' is a substring of 'whereuat' but NOT a prefix — must not match.
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.whereuat\t(Detached)\n'
  "$DOTFILES/bin/screen" -r "eua" >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_not_contains "$screen_log" "screen -r eua" "non-prefix substring 'eua' did NOT match 'whereuat'"
  teardown_test
}

test_prefix_match_respects_literal_dots() {
  setup_test
  STUB_TMUX_SESSIONS=""
  # Query "foo." is a literal prefix; should match "foo.bar" but not "fooXbar".
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo.bar\t(Detached)\n\t12346.fooXbar\t(Detached)\n'
  "$DOTFILES/bin/screen" -r "foo." >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$screen_log" "screen -r foo." "literal prefix 'foo.' matched 'foo.bar'"
  teardown_test
}

# Real tmux's `has-session -t <prefix>` returns non-zero for an *ambiguous*
# prefix as well as for an absent session. If the wrapper treated ambiguity
# as absence and a GNU screen session happened to share the prefix, we'd
# silently route the user to GNU screen instead of letting tmux report the
# ambiguity. Fallback must only fire when tmux has zero prefix matches.
test_ambiguous_tmux_prefix_does_not_fall_back() {
  setup_test
  STUB_TMUX_SESSIONS="whereabouts whereuat"
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.wheelchair\t(Detached)\n'
  "$DOTFILES/bin/screen" -r "whe" >/dev/null 2>&1 || true
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_not_contains "$screen_log" "screen -r whe" "ambiguous tmux prefix did NOT trigger GNU screen fallback"
  teardown_test
}

test_list_sessions_includes_screen() {
  setup_test
  STUB_TMUX_SESSIONS="alpha beta"
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.gamma\t(Detached)\n1 Socket in /run/screen.\n'
  out=$("$DOTFILES/bin/screen" -ls 2>&1)
  assert_contains "$out" "alpha: 1 windows" "tmux session alpha listed"
  assert_contains "$out" "beta: 1 windows" "tmux session beta listed"
  assert_contains "$out" "12345.gamma" "screen session gamma listed"
  alpha_line=$(printf '%s\n' "$out" | grep -n "alpha:" | head -1 | cut -d: -f1)
  gamma_line=$(printf '%s\n' "$out" | grep -n "12345.gamma" | head -1 | cut -d: -f1)
  if [[ -n "$alpha_line" && -n "$gamma_line" && "$alpha_line" -lt "$gamma_line" ]]; then
    printf '  ok tmux output precedes screen output (alpha=%s gamma=%s)\n' "$alpha_line" "$gamma_line"
    PASSED=$((PASSED+1))
  else
    printf '  FAIL tmux output must precede screen output (alpha=%s gamma=%s)\n' "$alpha_line" "$gamma_line"
    FAILED=$((FAILED+1))
  fi
  teardown_test
}

test_list_sessions_suppresses_tmux_errors() {
  setup_test
  cat > "$TMPDIR_TEST/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) echo "no server running on /tmp/tmux-1000/default" >&2; exit 1 ;;
    *) exit 0 ;;
esac
EOF
  chmod +x "$TMPDIR_TEST/tmux"
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.gamma\t(Detached)\n'
  out=$("$DOTFILES/bin/screen" -ls 2>&1)
  assert_not_contains "$out" "no server running" "tmux 'no server' stderr suppressed"
  assert_contains "$out" "12345.gamma" "screen sessions still listed"
  teardown_test
}

test_list_sessions_screen_missing() {
  setup_test
  STUB_TMUX_SESSIONS="alpha"
  rm -f "$TMPDIR_TEST/screen"
  out=$("$DOTFILES/bin/screen" -ls 2>&1)
  assert_contains "$out" "alpha: 1 windows" "tmux session listed when screen is missing"
  teardown_test
}

test_list_exits_zero_when_tmux_has_sessions() {
  setup_test
  STUB_TMUX_SESSIONS="alpha"
  STUB_SCREEN_LS="No Sockets found in /run/screen/S-user."$'\n'
  STUB_SCREEN_LS_RC=1
  export STUB_SCREEN_LS_RC
  set +e
  "$DOTFILES/bin/screen" -ls >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" "0" "exit 0 when tmux has sessions"
  unset STUB_SCREEN_LS_RC
  teardown_test
}

test_list_exits_zero_when_only_screen_has_sessions() {
  setup_test
  cat > "$TMPDIR_TEST/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) exit 1 ;;
    *) exit 0 ;;
esac
EOF
  chmod +x "$TMPDIR_TEST/tmux"
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.gamma\t(Detached)\n'
  set +e
  "$DOTFILES/bin/screen" -ls >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" "0" "exit 0 when only screen has sessions"
  teardown_test
}

test_list_exits_nonzero_when_neither_has_sessions() {
  setup_test
  cat > "$TMPDIR_TEST/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) exit 1 ;;
    *) exit 0 ;;
esac
EOF
  chmod +x "$TMPDIR_TEST/tmux"
  STUB_SCREEN_LS="No Sockets found in /run/screen/S-user."$'\n'
  STUB_SCREEN_LS_RC=1
  export STUB_SCREEN_LS_RC
  set +e
  "$DOTFILES/bin/screen" -ls >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" "1" "exit 1 when neither has sessions"
  unset STUB_SCREEN_LS_RC
  teardown_test
}

test_list_exits_nonzero_when_tmux_running_but_empty() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS="No Sockets found in /run/screen/S-user."$'\n'
  STUB_SCREEN_LS_RC=1
  export STUB_SCREEN_LS_RC
  set +e
  "$DOTFILES/bin/screen" -ls >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" "1" "exit 1 when tmux server is up but empty and screen has no sessions"
  unset STUB_SCREEN_LS_RC
  teardown_test
}

test_x_named_creates_shadow_session() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "new-session -t foo -s foo-x-" "shadow session create was invoked"
  assert_not_contains "$tmux_log" "attach-session -t foo" "plain attach-session was NOT invoked"
  teardown_test
}

test_r_named_still_mirrors() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -r foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "attach-session -t foo" "plain attach-session was invoked for -r"
  assert_not_contains "$tmux_log" "new-session -t foo -s foo-x-" "shadow session was NOT created for -r"
  teardown_test
}

test_x_named_does_not_kill_coincidentally_named_session() {
  setup_test
  # foo-x-99 looks like a shadow of foo (name matches the pattern, PID 99
  # is almost certainly dead), but it has NO session group — it's an
  # unrelated user session that happens to match the pattern. The orphan
  # prune must NOT kill it. Found by codex review of the original Task 2
  # implementation.
  STUB_TMUX_SESSIONS="foo:foo foo-x-99"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_not_contains "$tmux_log" "kill-session -t foo-x-99" "coincidentally-named session was NOT killed"
  teardown_test
}

test_x_prefix_target_canonicalizes() {
  setup_test
  # User invokes `screen -x fo`, tmux resolves to `foo` (unique prefix).
  # The shadow must be named foo-x-<pid> (not fo-x-<pid>), so a future
  # invocation can prune it via session_group=foo match.
  STUB_TMUX_SESSIONS="foo:foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x fo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "new-session -t foo -s foo-x-" "shadow uses canonical target name 'foo', not raw 'fo'"
  assert_not_contains "$tmux_log" "new-session -t foo -s fo-x-" "shadow does NOT use raw arg as name prefix"
  teardown_test
}

test_x_canonicalization_uses_session_namespace() {
  setup_test
  # The wrapper must canonicalize $target via display-message with a session
  # target ("$target:"), not a pane target. The fake-tmux stub doesn't
  # implement tmux's window/pane namespace, so this test just pins the
  # invocation form so a future refactor can't quietly drop the trailing
  # colon and reintroduce the namespace bug.
  STUB_TMUX_SESSIONS="foo:foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "display-message -t foo: -p" "display-message uses session-target form (trailing colon)"
  teardown_test
}

test_x_prunes_shadow_when_target_in_differently_named_group() {
  setup_test
  # Edge case: user has manually pre-grouped foo into group "devgrp"
  # (via `tmux new -t devgrp -s foo` or similar). Wrapper-created shadows
  # of foo will inherit group "devgrp", NOT "foo". Orphan pruning must
  # resolve the target's actual group and use that for the comparison;
  # otherwise dead shadows leak.
  dead_pid=2147483646
  STUB_TMUX_SESSIONS="foo:devgrp foo-x-${dead_pid}:devgrp"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "kill-session -t foo-x-${dead_pid}" "shadow in pre-existing differently-named group was pruned"
  teardown_test
}

test_x_named_trap_kills_shadow() {
  setup_test
  STUB_TMUX_SESSIONS="foo:foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  new_line=$(printf '%s\n' "$tmux_log" | grep -n "new-session -t foo -s foo-x-" | head -1 | cut -d: -f1)
  kill_line=$(printf '%s\n' "$tmux_log" | grep -n "kill-session -t foo-x-" | head -1 | cut -d: -f1)
  if [[ -n $new_line && -n $kill_line && $kill_line -gt $new_line ]]; then
    printf '  ok %s\n' "kill-session fires after new-session via trap"
    PASSED=$((PASSED+1))
  else
    printf '  FAIL %s\n    log:\n%s\n' "kill-session fires after new-session via trap" "$tmux_log"
    FAILED=$((FAILED+1))
  fi
  teardown_test
}

test_x_named_prunes_dead_orphan_shadow() {
  setup_test
  # PID 1 is always alive (init); pick a large PID that's almost certainly dead.
  dead_pid=2147483646
  STUB_TMUX_SESSIONS="foo:foo foo-x-${dead_pid}:foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "kill-session -t foo-x-${dead_pid}" "orphan shadow with dead PID was pruned"
  teardown_test
}

test_x_named_leaves_live_pid_shadow_alone() {
  setup_test
  # Use our own PID — guaranteed alive for the duration of this test.
  live_pid=$$
  STUB_TMUX_SESSIONS="foo:foo foo-x-${live_pid}:foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  # End-anchored line match. Substring matching would false-positive if the
  # wrapper's own EXIT-trap kill logged foo-x-<wrapper_pid> where wrapper_pid
  # happens to start with live_pid's digits.
  if grep -qE "kill-session -t foo-x-${live_pid}\$" <<< "$tmux_log"; then
    printf '  FAIL %s\n    log:\n%s\n' "shadow with live PID was NOT pruned" "$tmux_log"
    FAILED=$((FAILED+1))
  else
    printf '  ok %s\n' "shadow with live PID was NOT pruned"
    PASSED=$((PASSED+1))
  fi
  teardown_test
}

test_x_named_ignores_unrelated_session_names() {
  setup_test
  # Three "leave alone" cases:
  # - foo-bar: no -x-<digits> suffix; rejected by name pattern.
  # - foobar-x-99: shadow of foobar, not foo; rejected by name pattern
  #   (doesn't start with foo-x-).
  # - foo-x-2147483646: name pattern matches foo's shadows AND embedded PID
  #   is definitely dead (well above any pid_max). The ONLY thing protecting
  #   it from pruning is session_group=bar ≠ foo. This is the case that
  #   actually exercises the orphan-prune group check.
  STUB_TMUX_SESSIONS="foo:foo foo-bar foobar:foobar foobar-x-99:foobar foo-x-2147483646:bar"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_not_contains "$tmux_log" "kill-session -t foo-bar" "non-shadow sibling left alone"
  assert_not_contains "$tmux_log" "kill-session -t foobar-x-99" "different-target shadow left alone (name pattern mismatch)"
  if grep -qE "kill-session -t foo-x-2147483646\$" <<< "$tmux_log"; then
    printf '  FAIL %s\n    log:\n%s\n' "same-pattern shadow in different group left alone" "$tmux_log"
    FAILED=$((FAILED+1))
  else
    printf '  ok %s\n' "same-pattern shadow in different group left alone"
    PASSED=$((PASSED+1))
  fi
  teardown_test
}

for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
