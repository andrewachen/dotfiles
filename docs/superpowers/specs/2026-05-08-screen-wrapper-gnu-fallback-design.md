# Screen Wrapper: GNU Screen Fallback for Named Attach

## Background

`bin/screen` is a tmux-backed compatibility wrapper for common GNU screen
invocations. Today, when a user runs `screen -r NAME` and tmux has no session
named `NAME`, the wrapper exits with tmux's "no such session" error. Andrew
sometimes still has live GNU screen sessions on machines where the wrapper is
installed, and wants those reachable without dropping back to typing the full
`/usr/bin/screen ...` invocation.

## Goal

Add a narrow fallback path: when an attach-style invocation names a target and
tmux has no matching session, hand the original argv off to `/usr/bin/screen`
if (and only if) GNU screen lists a session with that name.

## Non-goals

- No fallback for unsupported flags. The original wrapper philosophy stays:
  unsupported screen options still fail explicitly.
- No fallback for create-if-missing modes (`-R`, `-RR`, `-D -RR`). Those
  always create a tmux session.
- No fallback for bare `-r` / `-x` (no target).
- No fallback for pure detach (`-d NAME`, `-D NAME` without `-r`).
- No user-facing config knob for the GNU screen path. Default is hardcoded to
  `/usr/bin/screen`. A `TMUX_SCREEN_COMPAT_REAL_SCREEN` env var override
  exists strictly for testability (mirrors the existing
  `TMUX_SCREEN_COMPAT_TMUX` pattern), not for end-user configurability.

## Behavior matrix

| Invocation | Today | Proposed |
|---|---|---|
| `screen -r NAME` | tmux attach, error if missing | If tmux missing AND `/usr/bin/screen -ls` lists NAME → exec `/usr/bin/screen` with original argv. Else current behavior. |
| `screen -x NAME` | tmux attach, error if missing | Same fallback rule. |
| `screen -d -r NAME` | tmux attach -d, error if missing | Same fallback rule. |
| `screen -D -r NAME` | tmux attach -d, error if missing | Same fallback rule. |
| `screen -R NAME`, `screen -RR NAME`, `screen -D -RR NAME` | create-if-missing in tmux | Unchanged. Always creates tmux. |
| `screen -d NAME`, `screen -D NAME` (pure detach) | tmux detach-client | Unchanged. No fallback. |
| `screen -r` / `screen -x` (no name) | tmux attach most-recent | Unchanged. No fallback. |
| `-ls`, `-dmS`, default new-session | as today | Unchanged. |
| Unsupported flags | `die` with explicit error | Unchanged. |

## Mechanism

### Argv capture and screen-bin resolution

At the top of the script (before any flag parsing or shifting), save the
user's original arguments and resolve the screen binary path:

```bash
original_args=("$@")
screen_bin=${TMUX_SCREEN_COMPAT_REAL_SCREEN:-/usr/bin/screen}
```

`original_args` is used only on the fallback path so `/usr/bin/screen` sees
the user's exact invocation. `screen_bin` defaults to the literal absolute
path; the env var exists solely so tests can redirect to a stub.

### Fallback gate

The check sits in the plain-attach branch (the `if [[ $attach_requested == true ]]`
block, after the `create_if_missing` short-circuit, before the existing
`args=(attach-session)` setup). It runs only when `target` is non-empty.

Pseudocode:

```
if target is empty: skip fallback (today's behavior)
if tmux has-session -t "$target" succeeds: skip fallback (today's behavior)
if not -x "$screen_bin": skip fallback (today's behavior, no recursion risk)
if readlink -f "$screen_bin" == readlink -f "$BASH_SOURCE[0]": skip fallback (recursion guard)
parse "$screen_bin" -ls output for a line matching ".${target}" exactly
if no match: skip fallback (today's behavior)
exec "$screen_bin" "${original_args[@]}"
```

Any guard failure falls through to today's `args=(attach-session); run_tmux ...`,
which produces tmux's existing "no such session" error.

### Resilience

- `[[ -x "$screen_bin" ]]` gate: missing path, non-executable, or dangling
  symlink → no fallback, no crash.
- `"$screen_bin" -ls` invoked with `stderr` redirected to `/dev/null` and
  exit code ignored. We only inspect stdout for a session-line match. (GNU
  screen's exit code from `-ls` is documented as varying by version and
  state; ignoring it avoids fragile assumptions.)
- Self-recursion guard: if `$screen_bin` resolves (via `readlink -f`) to the
  same file as `BASH_SOURCE[0]`, skip fallback. Protects against the case
  where this wrapper is installed *as* the resolved screen binary.
- All guards are local `if` checks. No `set -e` traps, no aborts.

### `screen -ls` parsing

`screen -ls` output looks like:

```
There are screens on:
        12345.foo       (Detached)
        67890.bar       (Detached)
2 Sockets in /run/screen/S-user.
```

A session named `foo` appears as `<digits>.foo<whitespace>`. Match by
splitting on `.` and comparing field 2 exactly to `target` — avoids regex
escaping headaches when `target` contains characters like `.`, `+`, `*`.

A simple `awk` invocation works:

```bash
"$screen_bin" -ls 2>/dev/null \
  | awk -v t="$target" '$1 ~ /^[0-9]+\./ {
      n = $1; sub(/^[0-9]+\./, "", n); if (n == t) found = 1
    } END { exit !found }'
```

## Tests

New test directory `tests/screen/`, bash-style harness mirroring
`tests/codex-gate/`. Each test creates a per-test shim directory containing
stub `tmux` and `screen` binaries that read scripted responses from env vars.
Tests redirect the wrapper to those stubs by setting:

- `TMUX_SCREEN_COMPAT_TMUX="$shim_dir/tmux"`
- `TMUX_SCREEN_COMPAT_REAL_SCREEN="$shim_dir/screen"`

Stub contract:

- `tmux has-session -t NAME`: exit 0 if `NAME` is in `STUB_TMUX_SESSIONS`
  (space-separated), else exit 1.
- `tmux <anything-else>`: log argv to `$STUB_TMUX_LOG`, exit 0.
- `screen -ls`: print `$STUB_SCREEN_LS` verbatim to stdout, exit code is
  irrelevant to the wrapper but pinned to 0 in the stub.
- `screen <other args>`: log argv to `$STUB_SCREEN_LOG`, exit 0.

Cases:

1. **tmux has it**: `screen -r foo`, `STUB_TMUX_SESSIONS="foo"`. Asserts tmux
   `attach-session -t foo` was logged, screen log empty.
2. **fallback to screen**: `screen -r foo`, `STUB_TMUX_SESSIONS=""`,
   `STUB_SCREEN_LS="There are screens on:\n\t12345.foo\t(Detached)\n"`.
   Asserts screen log contains `-r foo`, tmux attach-session not logged.
3. **neither has it**: `screen -r foo`, `STUB_TMUX_SESSIONS=""`,
   `STUB_SCREEN_LS=""`. Asserts tmux `attach-session -t foo` was logged
   (today's error path), screen log only contains the `-ls` probe.
4. **`-R` does not fall back**: `screen -R foo`, `STUB_TMUX_SESSIONS=""`,
   `STUB_SCREEN_LS="...\t12345.foo\t..."`. Asserts tmux `new-session -A -s foo`
   was logged, screen log only contains `-ls`.
5. **`-d -r` and `-D -r` fall back**: same shape as case 2 with the extra
   flags. Assert screen log contains the original argv.
6. **bare `-r` does not fall back**: `screen -r`, `STUB_TMUX_SESSIONS=""`,
   `STUB_SCREEN_LS="...\t12345.foo\t..."`. Asserts tmux attach-session (no
   `-t`) was logged, screen log empty (the gate is keyed off non-empty
   `target`, so the `-ls` probe never runs).
7. **screen missing**: shim's `screen` removed or chmod'd 000.
   `TMUX_SCREEN_COMPAT_REAL_SCREEN` points at the missing path. `screen -r foo`
   with `STUB_TMUX_SESSIONS=""`. Asserts tmux `attach-session -t foo` was
   logged, no crash.
8. **self-recursion guard**: `TMUX_SCREEN_COMPAT_REAL_SCREEN` points at the
   wrapper itself. `screen -r foo` with `STUB_TMUX_SESSIONS=""`. Asserts tmux
   attach-session was logged, no infinite loop.
9. **regex-special name**: `screen -r foo.bar`, `STUB_TMUX_SESSIONS=""`,
   `STUB_SCREEN_LS` containing `12345.foo.bar`. Asserts screen log contains
   `-r foo.bar`. Confirms literal match (and not e.g. matching against `foo`
   followed by any char).

## Docs

In `bin/screen` itself:

- Append to the `usage()` heredoc a "Fallback" paragraph:

  > If a named-target attach (`-r`, `-x`, `-d -r`, `-D -r`) finds no matching
  > tmux session and `/usr/bin/screen` lists one, the wrapper hands off to
  > GNU screen with the original arguments. Other modes do not fall back.

- Update the second `ABOUTME:` line. Current:

  > It intentionally does not fall back to real screen for unsupported args.

  Replace with:

  > Unsupported args still fail loudly, but a named attach with no tmux match
  > falls back to GNU screen if it has the session.

- Leave the `die()` message as-is; it fires on unsupported args, where the
  no-fallback rule still holds.

## Out-of-scope follow-ups

- Documenting `TMUX_SCREEN_COMPAT_REAL_SCREEN` as a user-facing knob. The
  variable exists for tests; it is intentionally not advertised in `usage()`.
- Pure-detach fallback (`screen -d NAME` finding the session in screen, not
  tmux). Skipped per scope agreement.
- Bare `-r` / `-x` fallback when tmux has zero sessions. Skipped per scope
  agreement.
