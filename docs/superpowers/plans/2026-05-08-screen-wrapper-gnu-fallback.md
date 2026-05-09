# Screen Wrapper GNU Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a narrow GNU-screen fallback to `bin/screen` so that `screen -r NAME` (and `-x`/`-d -r`/`-D -r` variants) hand off to `/usr/bin/screen` when tmux has no matching session but GNU screen does.

**Architecture:** The fallback gate sits inside the existing plain-attach branch of `bin/screen`, after the `create_if_missing` short-circuit and before the existing `args=(attach-session)` block. It runs only when `target` is non-empty and tmux has-session check fails. Resilience guards: `-x` check on the screen binary, self-recursion guard via `readlink -f`, awk-based exact match on `screen -ls` output. Tests use a per-test `PATH` shim with stub `tmux` and `screen` binaries; the wrapper's screen path is overridable via a hidden `TMUX_SCREEN_COMPAT_REAL_SCREEN` env var (mirrors existing `TMUX_SCREEN_COMPAT_TMUX`).

**Tech Stack:** Bash. Awk for `screen -ls` parsing. Bash test harness mirroring `tests/codex-gate/`.

**Spec:** `docs/superpowers/specs/2026-05-08-screen-wrapper-gnu-fallback-design.md`

---

## File Structure

- **Create**: `tests/screen/test.sh` — bash test harness, one function per test case.
- **Create**: `tests/screen/fake-tmux.sh` — stub tmux. Reads `STUB_TMUX_SESSIONS` (space-separated) for `has-session`. Logs every invocation argv to `$STUB_TMUX_LOG`.
- **Create**: `tests/screen/fake-screen.sh` — stub screen. `screen -ls` prints `$STUB_SCREEN_LS` to stdout. Other invocations log argv to `$STUB_SCREEN_LOG`.
- **Modify**: `bin/screen` — add `original_args` capture, `screen_bin` resolution, fallback gate in the plain-attach branch, ABOUTME and `usage()` updates.

---

## Task 1: Test harness scaffolding

**Files:**
- Create: `tests/screen/test.sh`
- Create: `tests/screen/fake-tmux.sh`
- Create: `tests/screen/fake-screen.sh`

- [ ] **Step 1: Create the fake tmux stub**

`tests/screen/fake-tmux.sh`:
```bash
#!/usr/bin/env bash
# ABOUTME: Stub tmux for tests/screen. has-session honors STUB_TMUX_SESSIONS;
# ABOUTME: every invocation appends its argv to $STUB_TMUX_LOG.

set -uo pipefail

if [[ -n "${STUB_TMUX_LOG:-}" ]]; then
    printf 'tmux'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
fi >> "${STUB_TMUX_LOG:-/dev/null}"

if [[ "${1:-}" == "has-session" ]]; then
    target=
    while (($#)); do
        case "$1" in
            -t) shift; target="${1:-}"; shift ;;
            *) shift ;;
        esac
    done
    for s in ${STUB_TMUX_SESSIONS:-}; do
        if [[ "$s" == "$target" ]]; then exit 0; fi
    done
    exit 1
fi

exit 0
```

- [ ] **Step 2: Create the fake screen stub**

`tests/screen/fake-screen.sh`:
```bash
#!/usr/bin/env bash
# ABOUTME: Stub /usr/bin/screen for tests/screen. -ls prints STUB_SCREEN_LS;
# ABOUTME: every invocation appends its argv to $STUB_SCREEN_LOG.

set -uo pipefail

if [[ -n "${STUB_SCREEN_LOG:-}" ]]; then
    printf 'screen'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
fi >> "${STUB_SCREEN_LOG:-/dev/null}"

if [[ "${1:-}" == "-ls" ]]; then
    printf '%b' "${STUB_SCREEN_LS:-}"
    exit 0
fi

exit 0
```

- [ ] **Step 3: Create the test harness skeleton**

`tests/screen/test.sh`:
```bash
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

for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
```

- [ ] **Step 4: Make all three executable**

```bash
chmod +x tests/screen/test.sh tests/screen/fake-tmux.sh tests/screen/fake-screen.sh
```

- [ ] **Step 5: Run the smoke test**

Run: `bash tests/screen/test.sh`
Expected: `1 passed, 0 failed` and exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/screen/test.sh tests/screen/fake-tmux.sh tests/screen/fake-screen.sh
git commit -m "test(screen): bash harness scaffolding with tmux and screen stubs"
```

---

## Task 2: Sanity test — tmux-only attach when tmux has the session

**Files:**
- Modify: `tests/screen/test.sh` (append a new test function)

- [ ] **Step 1: Append the test function**

Append before the `for t in $(declare -F ...` loop:

```bash
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
```

- [ ] **Step 2: Run tests, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `3 passed, 0 failed`. (Smoke + 2 new asserts.)

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): sanity test for existing tmux-attach path"
```

---

## Task 3: Failing test — fallback to GNU screen when tmux missing, screen present

**Files:**
- Modify: `tests/screen/test.sh`
- Modify: `bin/screen`

- [ ] **Step 1: Append the failing test**

Append before the runner loop in `tests/screen/test.sh`:

```bash
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
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/screen/test.sh`
Expected: FAIL on `screen -r foo was invoked` (today the wrapper goes to tmux unconditionally).

- [ ] **Step 3: Add argv capture and screen_bin to bin/screen**

Edit `bin/screen` near the top, just after `set -uo pipefail` and `tmux_bin=...`:

Find:
```bash
set -uo pipefail

tmux_bin=${TMUX_SCREEN_COMPAT_TMUX:-tmux}
```

Replace with:
```bash
set -uo pipefail

original_args=("$@")

tmux_bin=${TMUX_SCREEN_COMPAT_TMUX:-tmux}
screen_bin=${TMUX_SCREEN_COMPAT_REAL_SCREEN:-/usr/bin/screen}
```

- [ ] **Step 4: Add the fallback gate to the plain-attach branch**

The gate includes a defensive `[[ -x $screen_bin ]]` check from the start —
the spec calls for it as a resilience measure, even though the surrounding
`2>/dev/null` and awk-empty-input behavior would also fall through cleanly.

Find this block in `bin/screen`:
```bash
    args=(attach-session)
    if [[ $detach_requested == true || $detach_others == true ]]; then
        args+=( -d )
    fi
    if [[ -n $target ]]; then
        args+=( -t "$target" )
    fi

    run_tmux "${args[@]}"
fi
```

Replace with:
```bash
    if [[ -n $target ]] && ! "$tmux_bin" has-session -t "$target" 2>/dev/null; then
        if [[ -x $screen_bin ]] \
            && "$screen_bin" -ls 2>/dev/null \
                | awk -v t="$target" '$1 ~ /^[0-9]+\./ {
                      n = $1; sub(/^[0-9]+\./, "", n); if (n == t) found = 1
                  } END { exit !found }'; then
            exec "$screen_bin" "${original_args[@]}"
        fi
    fi

    args=(attach-session)
    if [[ $detach_requested == true || $detach_others == true ]]; then
        args+=( -d )
    fi
    if [[ -n $target ]]; then
        args+=( -t "$target" )
    fi

    run_tmux "${args[@]}"
fi
```

- [ ] **Step 5: Run the new test, verify it passes**

Run: `bash tests/screen/test.sh -- test_fallback_when_tmux_missing_screen_present` (or just `bash tests/screen/test.sh` and inspect the new test).
Expected: all assertions pass.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/screen/test.sh`
Expected: `5 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add bin/screen tests/screen/test.sh
git commit -m "feat(screen): fall back to GNU screen on named-target attach miss"
```

---

## Task 4: Regression test — `-R` does not fall back

**Files:**
- Modify: `tests/screen/test.sh`

- [ ] **Step 1: Append the test**

```bash
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
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `7 passed, 0 failed`. (`-R` short-circuits before the fallback gate, so this should already pass.)

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): -R never falls back, always creates tmux session"
```

---

## Task 5: Regression test — bare `-r` does not fall back

**Files:**
- Modify: `tests/screen/test.sh`

- [ ] **Step 1: Append the test**

```bash
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
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `10 passed, 0 failed`. (Bare `-r` leaves `target` empty; the gate's `[[ -n $target ]]` short-circuits before any screen probe.)

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): bare -r never falls back, never probes screen"
```

---

## Task 6: Regression test — `-d -r` and `-D -r` fall back

**Files:**
- Modify: `tests/screen/test.sh`

- [ ] **Step 1: Append the test**

```bash
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
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `12 passed, 0 failed`. (Same code path as plain `-r foo`; the gate fires regardless of `detach_requested`/`detach_others`.)

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): -d -r and -D -r fall back like plain -r"
```

---

## Task 7: Regression test — neither has the session

**Files:**
- Modify: `tests/screen/test.sh`

- [ ] **Step 1: Append the test**

```bash
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
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `15 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): falls through to tmux when neither tmux nor screen has session"
```

---

## Task 8: Regression test — screen binary missing

The `-x $screen_bin` guard is already in place from Task 3 (defensive). This
task verifies behavior is correct when the screen path is missing.

**Files:**
- Modify: `tests/screen/test.sh`

- [ ] **Step 1: Append the test**

```bash
test_screen_missing() {
  setup_test
  STUB_TMUX_SESSIONS=""
  rm -f "$TMPDIR_TEST/screen"
  "$DOTFILES/bin/screen" -r foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "attach-session -t foo" "tmux attach-session was invoked despite missing screen"
  teardown_test
}
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `16 passed, 0 failed`. The `-x` guard short-circuits before
attempting to invoke the missing binary; the wrapper falls through to tmux.

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): regression coverage for missing screen binary"
```

---

## Task 9: Failing test — self-recursion guard

**Files:**
- Modify: `tests/screen/test.sh`
- Modify: `bin/screen`

To make recursion *actually* trigger without the guard, the test rewrites
the tmux stub so `tmux list-sessions` returns screen-formatted output. That
way, when the wrapper-as-screen recursively invokes `screen -ls`, the inner
wrapper execs `tmux list-sessions`, which returns content that fools the
awk matcher into finding the target — driving exec → recurse → exec.

- [ ] **Step 1: Append the failing test**

```bash
test_self_recursion_guard() {
  setup_test
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
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/screen/test.sh`
Expected: FAIL — without the guard, the outer wrapper's `screen -ls` probe
runs the inner wrapper with `-ls`, which execs `tmux list-sessions`, which
prints `12345.foo`. Awk matches. The outer wrapper then execs the screen
symlink (the wrapper) with `-r foo`. That re-enters the same path. The
`timeout 5` fires (rc=124).

- [ ] **Step 3: Add the recursion guard**

Find in `bin/screen`:
```bash
    if [[ -n $target ]] && ! "$tmux_bin" has-session -t "$target" 2>/dev/null; then
        if [[ -x $screen_bin ]] \
            && "$screen_bin" -ls 2>/dev/null \
                | awk -v t="$target" '$1 ~ /^[0-9]+\./ {
                      n = $1; sub(/^[0-9]+\./, "", n); if (n == t) found = 1
                  } END { exit !found }'; then
            exec "$screen_bin" "${original_args[@]}"
        fi
    fi
```

Replace with:
```bash
    if [[ -n $target ]] && ! "$tmux_bin" has-session -t "$target" 2>/dev/null; then
        if [[ -x $screen_bin ]]; then
            screen_real=$(readlink -f "$screen_bin" 2>/dev/null || true)
            wrapper_real=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
            if [[ -n $screen_real && -n $wrapper_real && $screen_real != "$wrapper_real" ]] \
                && "$screen_bin" -ls 2>/dev/null \
                    | awk -v t="$target" '$1 ~ /^[0-9]+\./ {
                          n = $1; sub(/^[0-9]+\./, "", n); if (n == t) found = 1
                      } END { exit !found }'; then
                exec "$screen_bin" "${original_args[@]}"
            fi
        fi
    fi
```

- [ ] **Step 4: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `17 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/screen tests/screen/test.sh
git commit -m "feat(screen): guard against self-recursion if installed as /usr/bin/screen"
```

---

## Task 10: Regression test — name with regex-special characters

**Files:**
- Modify: `tests/screen/test.sh`

- [ ] **Step 1: Append the test**

```bash
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
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `19 passed, 0 failed`. (The awk parser uses string `==`, not regex, so literal-match is already correct.)

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): literal session-name match handles regex-special chars"
```

---

## Task 11: Update ABOUTME and usage()

**Files:**
- Modify: `bin/screen`

- [ ] **Step 1: Update ABOUTME header**

Find in `bin/screen`:
```bash
# ABOUTME: Compatibility wrapper that maps common GNU screen invocations to tmux.
# ABOUTME: It intentionally does not fall back to real screen for unsupported args.
```

Replace with:
```bash
# ABOUTME: Compatibility wrapper that maps common GNU screen invocations to tmux.
# ABOUTME: Unsupported args still fail loudly, but a named attach with no tmux match
# ABOUTME: falls back to GNU screen if /usr/bin/screen has the session.
```

- [ ] **Step 2: Update the usage() heredoc**

Find in `bin/screen`:
```bash
In this wrapper, -D detaches other tmux clients without sending SIGHUP/logout.
Unsupported screen options do not fall back to GNU screen.
Use tmux directly for behavior outside this compatibility set.
EOF
```

Replace with:
```bash
In this wrapper, -D detaches other tmux clients without sending SIGHUP/logout.

Unsupported screen options do not fall back to GNU screen.

Fallback: if a named-target attach (-r, -x, -d -r, -D -r) finds no matching
tmux session and /usr/bin/screen lists one, the wrapper hands off to GNU
screen with the original arguments. Other modes do not fall back.

Use tmux directly for behavior outside this compatibility set.
EOF
```

- [ ] **Step 3: Run the full suite, verify still passes**

Run: `bash tests/screen/test.sh`
Expected: `19 passed, 0 failed`. (The smoke test reads `--help`; the message change is additive.)

- [ ] **Step 4: Commit**

```bash
git add bin/screen
git commit -m "docs(screen): document GNU screen fallback in ABOUTME and --help"
```

---

## Verification

After all tasks complete:

- [ ] **Step 1: Full test suite green**

Run: `bash tests/screen/test.sh`
Expected: `19 passed, 0 failed`, exit 0.

- [ ] **Step 2: Manual smoke**

Run: `./bin/screen --help`
Expected: usage text includes the new "Fallback:" paragraph.

- [ ] **Step 3: Diff review**

Run: `git log --oneline main..HEAD` (if on a branch) or recent commits.
Expected: a clean per-task commit history.
