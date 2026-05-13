# Screen Wrapper `-x` Independent Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `screen -x NAME` (target specified, no detach flag) produce an *independent* view of the session — two terminals attached to the same windows but able to switch windows independently — matching GNU screen's `-x` semantics. Today both `-r` and `-x` produce mirrored views via tmux `attach-session`.

**Architecture:** Use tmux session groups. `screen -x NAME` creates a transient *shadow* session `NAME-x-<wrapper-pid>` in the same group as `NAME` (`tmux new-session -t NAME -s NAME-x-<pid>`), attaches to the shadow, and on detach (normal exit or signal) the wrapper's `EXIT` trap kills the shadow. Shadows are hidden from `screen -ls` via tmux's `list-sessions -f` filter (`session_grouped == 1 && session_name != session_group`). Orphan shadows (from `kill -9` of a wrapper) are pruned at the start of every `screen -x NAME` invocation: parse the trailing PID from any session named `NAME-x-<digits>` and `kill -0` it; dead PIDs get their sessions killed.

`screen -r NAME` stays mirrored (today's behavior). Detach-combined `-x` variants (`-d -x NAME`, `-D -x NAME`) keep today's mirror behavior — shadow mode applies only to bare `-x NAME`. Bare `-x` with no target also keeps today's path.

**Tech Stack:** Bash. tmux 3.4+ (`-f` filter and session groups present long before this; we use plain features). Existing bash test harness in `tests/screen/`.

**Background:** Andrew asked: "can we make `screen -x` allow me to attach two different terminals to the same session, but switch windows only affects one terminal? similar to the way gnu screen does it." The pre-research established:

- `tmux new-session -t TARGET -s NEW` creates `NEW` in a session group with `TARGET`. Group members share windows but track current window independently.
- The group name defaults to the original anchor's name; `#{session_grouped}` is 1 for every member; `#{session_group}` is the anchor name; `session_name == session_group` identifies the anchor.
- `destroy-unattached` is too aggressive to set programmatically: setting it on a session with zero clients (which a freshly created session always has, even briefly) destroys the session before our client can attach. **Use trap-based manual cleanup, not `destroy-unattached`.**
- `tmux list-sessions -f '#{||:#{==:#{session_grouped},0},#{==:#{session_name},#{session_group}}}'` keeps anchors and non-grouped sessions, hides shadows. Verified empirically against tmux 3.4.
- `tmux kill-session -t GROUPNAME` returns "can't find session" when the anchor is gone, even though the group still exists — so name collisions between live anchors and group-only names are not a concern.

---

## File Structure

- **Modify:** `bin/screen` — add `attach_via_x` parse flag, shadow-mode dispatch (orphan cleanup + new-session + trap cleanup), `-ls` filter argument, ABOUTME and `usage()` updates.
- **Modify:** `tests/screen/fake-tmux.sh` — extend stub to support `new-session -t ... -s ...`, `kill-session -t ...`, `list-sessions -F '#{session_name}'` (already partially supported), and a new `STUB_TMUX_LS_FILTER_LOG` capture so tests can assert the `-f` filter argument is being passed.
- **Modify:** `tests/screen/test.sh` — append shadow-mode tests, orphan-cleanup tests, `-ls` filter test, regression tests for `-dx`/`-Dx` and bare `-x`.

---

## Task 1: Extend fake-tmux to record `-f` filter and accept new commands

**Files:**
- Modify: `tests/screen/fake-tmux.sh`

The current fake-tmux handles `has-session` and `list-sessions`. The new tests need it to (a) record which `-f` filter argument was passed to `list-sessions`, (b) not error on `new-session`/`kill-session`/`set-option`/`detach-client` (it already exits 0 for unknown commands, but we'll be explicit), and (c) honor an env var to list only specific session names when asked.

- [ ] **Step 1: Update `tests/screen/fake-tmux.sh` to record `-f` filters**

Replace the file body with:

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

if [[ "${1:-}" == "list-sessions" ]]; then
    shift
    fmt=
    filter=
    while (($#)); do
        case "$1" in
            -F) shift; fmt="${1:-}"; shift ;;
            -f) shift; filter="${1:-}"; shift ;;
            *) shift ;;
        esac
    done
    if [[ -n $filter && -n "${STUB_TMUX_LS_FILTER_LOG:-}" ]]; then
        printf '%s\n' "$filter" >> "$STUB_TMUX_LS_FILTER_LOG"
    fi
    for s in ${STUB_TMUX_SESSIONS:-}; do
        if [[ "$fmt" == "#{session_name}" ]]; then
            printf '%s\n' "$s"
        else
            printf '%s: 1 windows\n' "$s"
        fi
    done
    exit 0
fi

exit 0
```

- [ ] **Step 2: Run the existing test suite to confirm no regression**

Run: `bash tests/screen/test.sh`
Expected: same pass count as before this task, 0 failed. (We added a new `-f` parse branch but only logs when `STUB_TMUX_LS_FILTER_LOG` is set; existing tests don't set it.)

- [ ] **Step 3: Commit**

```bash
git add tests/screen/fake-tmux.sh
git commit -m "test(screen): extend fake-tmux to record list-sessions -f filter arg"
```

---

## Task 2: Shadow-mode dispatch for `screen -x NAME`

**Files:**
- Modify: `tests/screen/test.sh`
- Modify: `bin/screen`

- [ ] **Step 1: Append the failing test**

Append before the `for t in $(declare -F ...` runner loop in `tests/screen/test.sh`:

```bash
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
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/screen/test.sh`
Expected: FAIL on `shadow session create was invoked` (today `-x` calls `attach-session`, not `new-session -t ... -s ...`).

- [ ] **Step 3: Add `attach_via_x` parse flag in `bin/screen`**

In `bin/screen`, near the other parse-state variables at top of file, find:

```bash
attach_requested=false
```

Replace with:

```bash
attach_requested=false
attach_via_x=false
```

Then in `parse_cluster`, find:

```bash
            r|x)
                attach_requested=true
                if [[ -n $chars ]]; then
                    target=$chars
                    chars=
                fi
                ;;
```

Replace with:

```bash
            r|x)
                attach_requested=true
                if [[ $ch == x ]]; then
                    attach_via_x=true
                fi
                if [[ -n $chars ]]; then
                    target=$chars
                    chars=
                fi
                ;;
```

- [ ] **Step 4: Add shadow-mode dispatch in the attach branch**

In `bin/screen`, find the block (currently around lines 267-275):

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

Insert *before* that block (still inside `if [[ $attach_requested == true ]]; then`), so it runs after the GNU-screen fallback check but before the plain attach:

```bash
    # screen -x NAME (bare, with target, no detach) → independent view via
    # tmux session group. Create a shadow session NAME-x-<wrapper-pid> grouped
    # with NAME, attach to the shadow, and kill the shadow on detach via
    # EXIT trap. Other -x variants (-dx, -Dx) and -r fall through to plain
    # attach-session below.
    if [[ $attach_via_x == true && -n $target && $detach_requested == false && $create_if_missing == false ]]; then
        require_tmux
        if "$tmux_bin" has-session -t "$target" 2>/dev/null; then
            shadow_name="$target-x-$$"

            # Prune orphan shadows from previously-killed wrappers in the
            # same family. Pattern: <target>-x-<digits>; the digits are the
            # wrapper PID at creation time. If kill -0 fails, the wrapper
            # is gone and the shadow is a ghost — drop it.
            while IFS= read -r existing; do
                [[ -z $existing ]] && continue
                rest=${existing#"$target-x-"}
                if [[ $rest != "$existing" && $rest =~ ^[0-9]+$ ]]; then
                    if ! kill -0 "$rest" 2>/dev/null; then
                        "$tmux_bin" kill-session -t "$existing" 2>/dev/null || true
                    fi
                fi
            done < <("$tmux_bin" list-sessions -F '#{session_name}' 2>/dev/null || true)

            # Clean up our own shadow on any exit path. tmux kill-session
            # is idempotent (we silence "no such session"), so a duplicate
            # cleanup from a fast user-initiated kill is harmless.
            cleanup_shadow() {
                "$tmux_bin" kill-session -t "$shadow_name" 2>/dev/null || true
            }
            trap cleanup_shadow EXIT INT TERM HUP

            "$tmux_bin" new-session -t "$target" -s "$shadow_name"
            exit $?
        fi
    fi
```

- [ ] **Step 5: Run tests, verify pass**

Run: `bash tests/screen/test.sh`
Expected: both new assertions pass; all prior tests still pass. Net change: `+4 passed`.

- [ ] **Step 6: Commit**

```bash
git add bin/screen tests/screen/test.sh
git commit -m "feat(screen): -x NAME creates independent view via tmux session group"
```

---

## Task 3: Trap-based shadow cleanup fires on exit

**Files:**
- Modify: `tests/screen/test.sh`

The implementation in Task 2 already includes the trap. This task adds the test that verifies the trap fires (kill-session appears in the tmux log after new-session).

- [ ] **Step 1: Append the test**

Append before the runner loop in `tests/screen/test.sh`:

```bash
test_x_named_trap_kills_shadow() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  # Both lines must appear, and kill-session must come AFTER new-session.
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
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `+1 passed`. The trap was already wired in Task 2; this test verifies the ordering.

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): verify shadow trap fires kill-session after new-session"
```

---

## Task 4: Orphan-shadow pruning on `screen -x NAME` startup

**Files:**
- Modify: `tests/screen/fake-tmux.sh`
- Modify: `tests/screen/test.sh`

The shadow-mode implementation in Task 2 already includes the orphan-pruning loop. This task verifies it works: a `foo-x-<dead-pid>` session in `list-sessions` output triggers `kill-session -t foo-x-<dead-pid>`; a live PID is left alone.

Why this matters: without orphan cleanup, every `kill -9` of a wrapper (terminal force-close, OOM kill, etc.) leaks a hidden tmux session. Over time these accumulate and consume server memory. The pruning pass runs only inside the `-x` codepath and only looks at `<target>-x-<digits>` patterns, so unrelated user sessions are never touched.

The fake-tmux currently lists all of `STUB_TMUX_SESSIONS` regardless of format. To test pruning we need the fake to *also* list orphan shadow names when asked, which it already does — we just put them in `STUB_TMUX_SESSIONS`.

- [ ] **Step 1: Append the test**

Append before the runner loop in `tests/screen/test.sh`:

```bash
test_x_named_prunes_dead_orphan_shadow() {
  setup_test
  # PID 1 is always alive (init); pick a large PID that's almost certainly dead.
  dead_pid=2147483646
  STUB_TMUX_SESSIONS="foo foo-x-${dead_pid}"
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
  STUB_TMUX_SESSIONS="foo foo-x-${live_pid}"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_not_contains "$tmux_log" "kill-session -t foo-x-${live_pid}" "shadow with live PID was NOT pruned"
  teardown_test
}

test_x_named_ignores_unrelated_session_names() {
  setup_test
  # foo-bar isn't a shadow of foo (no -x-<digits> suffix); must be left alone.
  # foobar-x-99 is a shadow of foobar, not foo; also must be left alone.
  STUB_TMUX_SESSIONS="foo foo-bar foobar-x-99"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_not_contains "$tmux_log" "kill-session -t foo-bar" "non-shadow sibling left alone"
  assert_not_contains "$tmux_log" "kill-session -t foobar-x-99" "different-target shadow left alone"
  teardown_test
}
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `+4 passed`. The pruning logic already exists from Task 2; these tests verify the matching rules.

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): verify orphan shadow pruning on -x invocation"
```

---

## Task 5: `screen -ls` hides shadow sessions via tmux `-f` filter

**Files:**
- Modify: `bin/screen`
- Modify: `tests/screen/test.sh`

- [ ] **Step 1: Append the failing test**

Append before the runner loop in `tests/screen/test.sh`:

```bash
test_ls_passes_filter_to_hide_shadows() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  export STUB_TMUX_LS_FILTER_LOG="$TMPDIR_TEST/tmux-ls-filter.log"
  : > "$STUB_TMUX_LS_FILTER_LOG"
  "$DOTFILES/bin/screen" -ls >/dev/null 2>&1 || true
  filter_log=$(cat "$STUB_TMUX_LS_FILTER_LOG")
  # The filter must be the canonical "keep anchors and non-grouped".
  # We check substrings rather than the full filter string so future
  # formatting tweaks don't break the test.
  assert_contains "$filter_log" "session_grouped" "list-sessions -f references session_grouped"
  assert_contains "$filter_log" "session_group" "list-sessions -f references session_group"
  unset STUB_TMUX_LS_FILTER_LOG
  teardown_test
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/screen/test.sh`
Expected: FAIL on both asserts (today's `-ls` invokes `list-sessions` with no `-f` flag).

- [ ] **Step 3: Pass the `-f` filter in the `-ls` branch of `bin/screen`**

In `bin/screen`, find:

```bash
    require_tmux
    tmux_out=$("$tmux_bin" list-sessions 2>/dev/null) || true
    [[ -n $tmux_out ]] && printf '%s\n' "$tmux_out"
```

Replace with:

```bash
    require_tmux
    # Hide shadow sessions created by `screen -x NAME`. The filter keeps
    # sessions that are not in a group OR that are the anchor of their
    # group (session_name == session_group). tmux drops the rest.
    tmux_ls_filter='#{||:#{==:#{session_grouped},0},#{==:#{session_name},#{session_group}}}'
    tmux_out=$("$tmux_bin" list-sessions -f "$tmux_ls_filter" 2>/dev/null) || true
    [[ -n $tmux_out ]] && printf '%s\n' "$tmux_out"
```

- [ ] **Step 4: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `+2 passed`.

- [ ] **Step 5: Commit**

```bash
git add bin/screen tests/screen/test.sh
git commit -m "feat(screen): -ls hides shadow sessions via tmux list-sessions filter"
```

---

## Task 6: Regression guards — `-dx`/`-Dx` and bare `-x` keep mirror behavior

**Files:**
- Modify: `tests/screen/test.sh`

These tests should pass against the Task 2 implementation (which gates shadow mode on `detach_requested == false` and `-n $target`), but they are easy to break in future edits — pin them down with explicit tests.

- [ ] **Step 1: Append the regression tests**

Append before the runner loop in `tests/screen/test.sh`:

```bash
test_dx_named_keeps_mirror() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -d -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "attach-session -d -t foo" "-d -x falls through to attach-session -d"
  assert_not_contains "$tmux_log" "new-session -t foo -s foo-x-" "-d -x does NOT enter shadow mode"
  teardown_test
}

test_Dx_named_keeps_mirror() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -D -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  assert_contains "$tmux_log" "attach-session -d -t foo" "-D -x falls through to attach-session -d"
  assert_not_contains "$tmux_log" "new-session -t foo -s foo-x-" "-D -x does NOT enter shadow mode"
  teardown_test
}

test_bare_x_no_target_keeps_mirror() {
  setup_test
  STUB_TMUX_SESSIONS="foo"
  STUB_SCREEN_LS=""
  "$DOTFILES/bin/screen" -x >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  # No target → no -t arg, plain attach-session that tmux resolves
  # to most-recent unattached. Definitely no shadow mode.
  assert_contains "$tmux_log" "attach-session" "bare -x falls through to attach-session"
  assert_not_contains "$tmux_log" "new-session" "bare -x does NOT enter shadow mode"
  teardown_test
}
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `+6 passed` (three tests, two asserts each).

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): pin mirror behavior for -dx, -Dx, bare -x"
```

---

## Task 7: Regression guard — `-x NAME` still falls back to GNU screen when tmux missing

**Files:**
- Modify: `tests/screen/test.sh`

The Task 2 implementation gates shadow mode on `has-session` succeeding, so the existing GNU-screen fallback path (further down in the attach branch) is reached when tmux has no `NAME`. Verify that.

- [ ] **Step 1: Append the test**

Append before the runner loop in `tests/screen/test.sh`:

```bash
test_x_named_falls_back_to_gnu_screen() {
  setup_test
  STUB_TMUX_SESSIONS=""
  STUB_SCREEN_LS=$'There are screens on:\n\t12345.foo\t(Detached)\n1 Socket in /run/screen.\n'
  "$DOTFILES/bin/screen" -x foo >/dev/null 2>&1 || true
  tmux_log=$(cat "$STUB_TMUX_LOG")
  screen_log=$(cat "$STUB_SCREEN_LOG")
  assert_contains "$screen_log" "screen -x foo" "screen -x foo was handed off to GNU screen"
  assert_not_contains "$tmux_log" "new-session -t foo -s foo-x-" "shadow mode NOT entered when tmux has no NAME"
  teardown_test
}
```

- [ ] **Step 2: Run, verify pass**

Run: `bash tests/screen/test.sh`
Expected: `+2 passed`. (Shadow mode is gated by `has-session`; tmux miss → fallback path unchanged.)

- [ ] **Step 3: Commit**

```bash
git add tests/screen/test.sh
git commit -m "test(screen): -x NAME still falls back to GNU screen when tmux misses"
```

---

## Task 8: Update help text and ABOUTME

**Files:**
- Modify: `bin/screen`

- [ ] **Step 1: Update ABOUTME at top of `bin/screen`**

Find lines 2-3:

```bash
# ABOUTME: Compatibility wrapper that maps common GNU screen invocations to tmux.
# ABOUTME: Named attach falls back to /usr/bin/screen on tmux miss; other modes fail loudly.
```

Replace with:

```bash
# ABOUTME: Compatibility wrapper that maps common GNU screen invocations to tmux.
# ABOUTME: -x NAME uses a tmux session group so each terminal has an independent window view.
```

(The fallback line is moved into `usage()` only; the ABOUTME-line budget is two, and the new -x behavior is the more salient invariant.)

- [ ] **Step 2: Update `usage()` heredoc**

Find the heredoc inside `usage()`:

```
Supported:
  screen
  screen -S NAME [COMMAND ...]
  screen -r [NAME]
  screen -x [NAME]
  screen -d [NAME]
  ...
```

Replace the full heredoc with:

```
screen: tmux-backed screen compatibility wrapper

Supported:
  screen
  screen -S NAME [COMMAND ...]
  screen -r [NAME]
  screen -x [NAME]
  screen -d [NAME]
  screen -D [NAME]
  screen -d -r [NAME]
  screen -D -r [NAME]
  screen -D -RR [NAME]
  screen -R|-RR [NAME]
  screen -ls|-list|-l
  screen -dmS NAME [COMMAND ...]

In this wrapper, -D detaches other tmux clients without sending SIGHUP/logout.

screen -x NAME (bare) creates an independent view: each terminal that runs
screen -x NAME against the same NAME shares the same windows but tracks its
own current window, like GNU screen's multi-display mode. This is
implemented via a tmux session group; the shadow session is named
NAME-x-<wrapper-pid> and is cleaned up when the terminal detaches.
Shadow sessions are hidden from screen -ls.

screen -r NAME and the detach-combined variants (-d -x, -D -x, -d -r, -D -r)
keep the mirrored-view behavior — all attached clients see the same window.

Unsupported screen options do not fall back to GNU screen.

Fallback: if a named-target attach (-r, -x, -d -r, -D -r) finds no matching
tmux session and /usr/bin/screen lists one whose name starts with the
target (prefix match, like screen -r itself), the wrapper hands off to GNU
screen with the original arguments. Other modes do not fall back.

Listing: -ls / -l / -list emits tmux sessions first (shadow sessions
hidden), then GNU screen sessions (separated by a blank line) when
/usr/bin/screen is available.

Use tmux directly for behavior outside this compatibility set.
```

- [ ] **Step 3: Run the test suite — should still be all green**

Run: `bash tests/screen/test.sh`
Expected: same pass count as after Task 7, 0 failed. (Docs changes don't break tests; smoke test confirms `--help` still works.)

- [ ] **Step 4: Commit**

```bash
git add bin/screen
git commit -m "docs(screen): document -x independent-view behavior in ABOUTME and --help"
```

---

## Task 9: Manual end-to-end verification on a real tmux server

**Files:** none (verification step)

The test harness uses a fake tmux. Before declaring done, run a real two-terminal smoke test to catch anything the fake masks (especially TTY interaction with `new-session` and trap timing).

- [ ] **Step 1: Open terminal A. Start a real session.**

```bash
bin/screen -S xtest
```

You should be inside tmux session `xtest`. Press `Ctrl-b c` once to make a second window so independence is visible. You're now in window 1.

- [ ] **Step 2: Open terminal B. Run `screen -x xtest`.**

```bash
bin/screen -x xtest
```

You should be attached, viewing the *same* windows as terminal A (because they're shared via the group), but you can press `Ctrl-b 0` to switch to window 0 *without* changing what terminal A sees. Terminal A stays on window 1; terminal B is on window 0. Independence confirmed.

- [ ] **Step 3: From a third terminal C, list sessions**

```bash
bin/screen -ls
```

Expected: only `xtest` shown. The shadow `xtest-x-<pid>` is hidden by the `-f` filter.

Sanity-check the shadow exists with raw tmux:

```bash
tmux list-sessions
```

Expected: two sessions, `xtest` and `xtest-x-<some-pid>`, both showing `(group xtest)`.

- [ ] **Step 4: Detach terminal B (`Ctrl-b d`). Verify cleanup.**

In terminal C:

```bash
tmux list-sessions
```

Expected: only `xtest` remains. The shadow was killed by the EXIT trap in terminal B's wrapper.

- [ ] **Step 5: Test orphan cleanup**

Re-run `screen -x xtest` in terminal B but `kill -9` its parent shell process from terminal C to simulate a kill that bypasses the trap:

```bash
# In terminal C:
pgrep -af 'bin/screen -x xtest'
kill -9 <pid-of-the-wrapper>
tmux list-sessions  # shadow should still be there (leaked)
```

Now in terminal B, run `screen -x xtest` again. The startup pruning pass should detect the dead PID and kill the orphan before creating its own shadow.

```bash
# Back in terminal C, while terminal B is still attached to the new shadow:
tmux list-sessions
```

Expected: `xtest` plus exactly one new `xtest-x-<pid>` — the old orphan is gone.

- [ ] **Step 6: Clean up the test session**

In terminal A: `exit` (or `Ctrl-b :` then `kill-session`).

- [ ] **Step 7: If everything above worked, no further commit needed. Push the branch.**

Verify final state:

```bash
git log --oneline main..HEAD
bash tests/screen/test.sh
```

Expected: clean commit history, all tests passing.

---

## Known limitations (intentionally out of scope)

These are documented behaviors, not bugs. Adding any of them to the plan would be YAGNI.

1. **`screen -x` with no target.** Keeps today's mirrored `attach-session` behavior. To get an independent view, the user must name the session.
2. **`screen -d -x NAME` / `screen -D -x NAME`.** Keep today's mirrored-with-detach-others behavior. The semantics of "detach other clients" across a session group are ambiguous; rather than guess, the wrapper preserves today's behavior for these combinations.
3. **Anchor session killed externally.** If the user runs `tmux kill-session -t NAME` directly (bypassing the wrapper) while shadows are attached, the group survives but `screen -ls` will not show an entry for the (now-anchor-less) group. The shadows remain functional until their own clients detach. This is a "you held it wrong" case; the wrapper does not synthesize a recovery anchor.
4. **`kill -9` of the wrapper.** No `EXIT` trap fires; the shadow leaks. The next invocation of `screen -x NAME` in the same family cleans up such orphans via the PID-liveness check. If no future `-x NAME` invocation happens, the orphan persists until tmux server restart — hidden from `-ls` and harmless besides a small memory cost.

---

## Self-review

- **Spec coverage:** Each behavior in the goal ("two terminals attached to the same session, switch windows only affects one terminal", "make sure you don't have ghosts/random garbage hanging around") maps to tasks: Task 2 implements independent views; Tasks 3, 4, 7 cover cleanup paths; Task 9 confirms behavior on real tmux.
- **Placeholder scan:** No TODOs, no "add error handling," no "similar to Task N" — every step has concrete code or a concrete command.
- **Type consistency:** Variable names used in `bin/screen` edits are consistent (`shadow_name`, `attach_via_x`, `tmux_ls_filter`). Shadow naming pattern is consistently `<target>-x-<pid>` everywhere. The tmux `-f` filter string in Task 5 step 3 matches what fake-tmux's `STUB_TMUX_LS_FILTER_LOG` records in Task 1.
