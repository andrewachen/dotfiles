# grip-review Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-serve `.md` plan/spec files via `~/bin/grip` whenever a superpowers skill asks Andrew to review one, surfacing a non-localhost URL he can open from anywhere on his LAN.

**Architecture:** A personal skill (`grip-review`) wraps the entire flow in a single helper script — one Bash permission grants the whole skill freedom over `~/.cache/claude-grip/`, `kill`, and grip itself. Port is deterministic per `CLAUDE_CODE_SESSION_ID` with collision retry, so multiple concurrent Claudes don't clash. PID is tracked in a session-scoped state file; a SessionEnd hook reaps the grip process at session end. A CLAUDE.md directive (not a fork of superpowers) tells Claude to invoke the skill at every "please review this .md" gate.

**Tech Stack:** Bash 4+, `~/bin/grip` (existing wrapper for `go-grip`), Claude Code SessionEnd hook, symlinks from dotfiles into `~/.claude/`.

---

## File Structure

**New files in `~/git/gh/dotfiles/`:**
- `.claude/skills/grip-review/SKILL.md` — skill descriptor (frontmatter + invocation instructions)
- `.claude/skills/grip-review/serve.sh` — all logic: port pick, kill prior, launch, URL capture, retry
- `.claude/hooks/cleanup-grip.sh` — SessionEnd hook: kill PID from state file, remove file
- `.claude/settings.grip-review-example.json` — example settings.json fragment showing the allow rule + SessionEnd hook
- `tests/grip-review/test.sh` — shell test driver
- `tests/grip-review/fake-grip.sh` — fake grip binary used by tests via `PATH` override

**Files to modify in `~/git/gh/dotfiles/`:**
- `.claude/CLAUDE.md` — add a new section that tells Claude to invoke grip-review at superpowers review gates
- `README.md` — add `grip-review` to the symlink loop, add a line about symlinking the cleanup hook

**Symlinks to create (not in git, but installation steps in README):**
- `~/.claude/skills/grip-review` → `~/git/gh/dotfiles/.claude/skills/grip-review`
- `~/.claude/hooks/cleanup-grip.sh` → `~/git/gh/dotfiles/.claude/hooks/cleanup-grip.sh`

**Live config edit (NOT in git, manual, per `feedback_dotfiles_hook_wiring.md`):**
- `~/.claude/settings.json` — apply the allow rule + SessionEnd hook from the example file

---

### Task 1: Skill skeleton and stub

**Files:**
- Create: `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/SKILL.md`
- Create: `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`

- [ ] **Step 1: Create the SKILL.md descriptor**

Write `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/SKILL.md`:

```markdown
---
name: grip-review
description: Serve a Markdown file (plan, spec, design doc) via ~/bin/grip on a non-localhost URL so Andrew can review it from any device on his LAN. Use whenever a superpowers skill (brainstorming spec review, writing-plans plan review, executing-plans checkpoint, etc.) asks Andrew to review a `.md` file. Returns a URL; print it on its own line before asking for review.
when_to_use: Any time you are about to ask Andrew to review a markdown plan or spec file produced by a superpowers skill — the moment before you ask "please review", run this skill against the file path, then include the URL in your prompt to Andrew.
version: 1.0.0
languages: bash
---

# grip-review

## Overview

Serves a markdown file via the local `~/bin/grip` wrapper, which binds `go-grip` to Andrew's LAN-visible IP. The URL it returns is reachable from any device on his network, so reviews don't require sitting at this machine.

The skill encapsulates all process and file management in a single helper script (`serve.sh`) so one Bash allowlist entry covers everything: state-dir creation, PID-file writes, prior-grip kill, port allocation, grip launch, URL extraction. No additional prompts.

## When to invoke

At every superpowers review gate that asks Andrew to read a `.md` file:
- brainstorming's spec-review gate
- writing-plans's plan-review gate
- executing-plans's checkpoint gates
- any other "please review this markdown" moment from a superpowers skill

Do NOT invoke for arbitrary markdown files unrelated to superpowers reviews. Do NOT invoke for code review (that's a different flow).

## How to invoke

Run the helper with the absolute path to the markdown file:

```bash
/home/achen/.claude/skills/grip-review/serve.sh /absolute/path/to/file.md
```

The script prints a single URL to stdout on success (e.g. `http://<lan-ip>:6531/path/to/file.md`). Pipe that URL into your review prompt to Andrew, e.g.:

> "Plan written to `<path>`. View it at `<URL>`. Let me know what to change."

On failure the script exits non-zero and prints a diagnostic to stderr. If that happens, fall back to asking Andrew to read the file directly.

## Lifecycle

Each invocation kills the prior grip from this same Claude session (PID tracked at `~/.cache/claude-grip/$CLAUDE_CODE_SESSION_ID.pid`) so only one grip per session is alive at a time. A SessionEnd hook (`~/.claude/hooks/cleanup-grip.sh`) reaps the final grip at session end.
```

- [ ] **Step 2: Create the serve.sh stub**

Write `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`:

```bash
#!/bin/bash
# ABOUTME: Launches ~/bin/grip in the background for a markdown file, prints a non-localhost URL,
# ABOUTME: and tracks the PID in a session-scoped state file so cleanup-grip.sh can reap it.

set -u
```

- [ ] **Step 3: Make serve.sh executable**

```bash
chmod +x /home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh
```

- [ ] **Step 4: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/skills/grip-review/
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
feat(grip-review): skill skeleton

SKILL.md descriptor + empty serve.sh placeholder. Logic added in
follow-up commits via TDD.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Test scaffolding with fake grip

**Files:**
- Create: `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
- Create: `/home/achen/git/gh/dotfiles/tests/grip-review/fake-grip.sh`

- [ ] **Step 1: Write the fake grip binary**

Write `/home/achen/git/gh/dotfiles/tests/grip-review/fake-grip.sh`:

```bash
#!/bin/bash
# ABOUTME: Stand-in for ~/bin/grip used by tests. Parses -p PORT and the file arg,
# ABOUTME: optionally fails fast if the env var FAKE_GRIP_FAIL_PORT matches the requested port.

set -u

PORT=6419
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PORT="$2"; shift 2 ;;
    -H|--host) shift 2 ;;
    -b|--browser) shift ;;
    --bounding-box|--no-reload) shift ;;
    *) FILE="$1"; shift ;;
  esac
done

# Simulate "port already bound": exit immediately when caller-specified port matches.
if [ -n "${FAKE_GRIP_FAIL_PORT:-}" ] && [ "$PORT" = "$FAKE_GRIP_FAIL_PORT" ]; then
  echo "listen tcp 0.0.0.0:$PORT: bind: address already in use" >&2
  exit 1
fi

# Successful path: print a grip-shaped URL and stay alive until killed.
echo "Serving on http://<lan-ip>:$PORT/$(basename "$FILE")"
exec sleep 3600
```

```bash
chmod +x /home/achen/git/gh/dotfiles/tests/grip-review/fake-grip.sh
```

- [ ] **Step 2: Write the test driver skeleton**

Write `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh`:

```bash
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
```

```bash
chmod +x /home/achen/git/gh/dotfiles/tests/grip-review/test.sh
```

- [ ] **Step 3: Run the skeleton to confirm it executes**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: prints `(no tests yet — added by later tasks)` and `Results: 0 passed, 0 failed`, exits 0.

- [ ] **Step 4: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add tests/grip-review/
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
test(grip-review): test scaffolding + fake grip binary

Fake grip parses -p, optionally simulates bind failure via
FAKE_GRIP_FAIL_PORT, otherwise prints a grip-shaped URL and
sleeps. Driver overrides PATH and isolates state via XDG_CACHE_HOME.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: TDD — deterministic port from session ID

**Files:**
- Modify: `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
- Modify: `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`

- [ ] **Step 1: Write the failing test**

Add to `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh` (replace the `(no tests yet — added by later tasks)` line):

```bash
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
```

- [ ] **Step 2: Run the test to verify failure**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: FAIL — serve.sh doesn't implement --dry-run-port yet, all three assertions fail or hang.

- [ ] **Step 3: Implement the port-pick logic**

Replace contents of `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`:

```bash
#!/bin/bash
# ABOUTME: Launches ~/bin/grip in the background for a markdown file, prints a non-localhost URL,
# ABOUTME: and tracks the PID in a session-scoped state file so cleanup-grip.sh can reap it.

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

echo "usage: $0 <markdown-file>  (or --dry-run-port for test inspection)" >&2
exit 2
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: all three port assertions PASS. `Results: 3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/skills/grip-review/serve.sh tests/grip-review/test.sh
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
feat(grip-review): deterministic per-session port

Hash CLAUDE_CODE_SESSION_ID to pick a port in 6420-7419. Different
Claude sessions get different ports almost always; collisions are
handled by the retry logic added in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: TDD — launch grip, capture URL, write PID file

**Files:**
- Modify: `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
- Modify: `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`

- [ ] **Step 1: Write the failing test**

Append to test.sh before the final `echo / Results` block:

```bash
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
```

- [ ] **Step 2: Run the test to verify failure**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: prior 3 PASS, new 4 FAIL (serve.sh exits 2 on unknown args).

- [ ] **Step 3: Implement launch + capture**

Replace the bottom of `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh` (everything after the `--dry-run-port` block) with:

```bash
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

# /proc/$pid/stat field 22 is "starttime" in clock ticks since boot.
# Pairing PID with starttime defends against PID recycling: a recycled
# PID will have a different starttime, so kill-prior and the SessionEnd
# hook won't accidentally signal an unrelated process.
pid_starttime() {
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null
}

PORT=$(pick_port)
"$GRIP" -p "$PORT" "$FILE" >"$LOG_FILE" 2>&1 &
GRIP_PID=$!

# Give grip a moment to bind and print its banner.
sleep 0.5

if ! kill -0 "$GRIP_PID" 2>/dev/null; then
  echo "grip-review: grip exited immediately; see $LOG_FILE" >&2
  exit 1
fi

echo "$GRIP_PID $(pid_starttime "$GRIP_PID")" > "$PID_FILE"

URL=$(grep -oE 'http://[^[:space:]]+' "$LOG_FILE" | head -1)
if [ -z "$URL" ]; then
  echo "grip-review: could not extract URL from grip output; see $LOG_FILE" >&2
  kill "$GRIP_PID" 2>/dev/null
  rm -f "$PID_FILE"
  exit 1
fi

echo "$URL"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: `Results: 8 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/skills/grip-review/serve.sh tests/grip-review/test.sh
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
feat(grip-review): launch grip, write PID+starttime, emit URL

Launch grip in the background on the deterministic port, write
"PID STARTTIME" to a session-scoped state file under XDG_CACHE_HOME
(starttime from /proc/$pid/stat field 22 defends against PID recycling
when kill-prior and the SessionEnd hook later read this file). Scrape
the URL from grip's first 0.5s of output and emit it. GRIP_BIN env
var exists for test injection.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: TDD — kill prior grip on re-invocation

**Files:**
- Modify: `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
- Modify: `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`

- [ ] **Step 1: Write the failing test**

Append to test.sh:

```bash
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
```

- [ ] **Step 2: Run the test to verify failure**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: "first grip killed" FAILs (the previous grip leaks because no kill-prior logic exists yet). "re-invocation rotates PID" likely PASSes because the second grip gets a fresh OS pid regardless.

- [ ] **Step 3: Implement kill-prior logic with PID+starttime verification**

In `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`, insert this block AFTER the `pid_starttime()` function definition added in Task 4, and BEFORE `PORT=$(pick_port)`:

```bash
# Kill any prior grip from this same Claude session.
# Verify the recorded starttime still matches before signalling — if the
# previous grip died and Linux recycled its PID, the starttime will differ
# and we leave that unrelated process alone.
if [ -f "$PID_FILE" ]; then
  read -r PRIOR_PID PRIOR_START < "$PID_FILE" 2>/dev/null || PRIOR_PID=""
  if [ -n "$PRIOR_PID" ] && [ "$(pid_starttime "$PRIOR_PID")" = "$PRIOR_START" ]; then
    kill "$PRIOR_PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: `Results: 11 passed, 0 failed` (8 prior + 2 kill-prior + 1 stale-pid-safety).

- [ ] **Step 5: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/skills/grip-review/serve.sh tests/grip-review/test.sh
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
feat(grip-review): kill prior grip with PID+starttime safety check

Each invocation reads the session PID file, verifies the recorded
starttime still matches /proc/$pid/stat field 22, and only signals
when both match — so a recycled PID from a long-dead grip cannot
cause us to kill an unrelated user process. Removes the stale file
either way. Bounded to this session id so sibling Claude sessions
aren't disturbed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: TDD — port collision retry

**Files:**
- Modify: `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
- Modify: `/home/achen/git/gh/dotfiles/.claude/skills/grip-review/serve.sh`

- [ ] **Step 1: Write the failing test**

Append to test.sh:

```bash
# --- Test: port collision triggers retry on next port ---
MD4=$(mktemp --suffix=.md); echo "# c" > "$MD4"
PRIMARY=$(CLAUDE_CODE_SESSION_ID=collision-session "$SERVE" --dry-run-port)
export FAKE_GRIP_FAIL_PORT="$PRIMARY"
URL_C=$(CLAUDE_CODE_SESSION_ID=collision-session "$SERVE" "$MD4")
unset FAKE_GRIP_FAIL_PORT

assert_contains "retry produced a URL" "$URL_C" "http://"
# Retry should land on PRIMARY+1
EXPECTED_PORT=$((PRIMARY + 1))
assert_contains "retry used next port" "$URL_C" ":$EXPECTED_PORT/"

# Regression check: serve.sh must emit exactly ONE URL line on stdout
# (caught a bug where the retry loop and the old single-shot extraction
# both echoed, producing two URLs per successful invocation).
URL_LINES=$(printf '%s\n' "$URL_C" | grep -c '^http')
assert_eq "single URL line on stdout" "$URL_LINES" "1"

# Cleanup
RETRY_PID_FILE="$XDG_CACHE_HOME/claude-grip/collision-session.pid"
[ -f "$RETRY_PID_FILE" ] && kill "$(awk '{print $1}' "$RETRY_PID_FILE")" 2>/dev/null
rm -f "$RETRY_PID_FILE" "$MD4"
```

- [ ] **Step 2: Run the test to verify failure**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: prior 11 PASS, all three new asserts FAIL (no retry — script exits 1 after the first grip dies).

- [ ] **Step 3: Implement retry**

Replace the entire launch-through-emit section in serve.sh — from `"$GRIP" -p "$PORT" "$FILE" >"$LOG_FILE" 2>&1 &` (the line right after the `sleep 0.5` comment) through the final `echo "$URL"` (inclusive). Do NOT leave the original Task-4 `URL=$(grep ...)` extraction or trailing `echo "$URL"` in place — the loop below handles both internally, and leaving them would cause serve.sh to print two URLs per invocation (the regression the new test guards against).

```bash
URL=""
for ATTEMPT in 0 1 2 3 4; do
  TRY_PORT=$((PORT + ATTEMPT))
  : > "$LOG_FILE"
  "$GRIP" -p "$TRY_PORT" "$FILE" >"$LOG_FILE" 2>&1 &
  GRIP_PID=$!
  sleep 0.5

  if kill -0 "$GRIP_PID" 2>/dev/null; then
    URL=$(grep -oE 'http://[^[:space:]]+' "$LOG_FILE" | head -1)
    if [ -n "$URL" ]; then
      echo "$GRIP_PID $(pid_starttime "$GRIP_PID")" > "$PID_FILE"
      break
    fi
    # Process alive but no URL — kill and treat as failure.
    kill "$GRIP_PID" 2>/dev/null
  fi
  GRIP_PID=""
done

if [ -z "$URL" ]; then
  echo "grip-review: could not launch grip after 5 port attempts starting at $PORT; see $LOG_FILE" >&2
  exit 1
fi

echo "$URL"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: `Results: 14 passed, 0 failed` (11 prior + retry-URL + retry-port + single-URL-line).

- [ ] **Step 5: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/skills/grip-review/serve.sh tests/grip-review/test.sh
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
feat(grip-review): retry on port collision

If grip dies within 0.5s (typically EADDRINUSE), increment the port
and retry up to 5 times. Handles both rare session-id hash collisions
and unrelated processes squatting on the chosen port.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: TDD — SessionEnd cleanup hook

**Files:**
- Create: `/home/achen/git/gh/dotfiles/.claude/hooks/cleanup-grip.sh`
- Modify: `/home/achen/git/gh/dotfiles/tests/grip-review/test.sh`

- [ ] **Step 1: Write the failing test**

Append to test.sh:

```bash
# --- Test: cleanup-grip.sh kills the session's grip and removes the PID file ---
HOOK="$DOTFILES/.claude/hooks/cleanup-grip.sh"
MD5=$(mktemp --suffix=.md); echo "# d" > "$MD5"
CLAUDE_CODE_SESSION_ID=cleanup-test "$SERVE" "$MD5" >/dev/null
CLEAN_PID_FILE="$XDG_CACHE_HOME/claude-grip/cleanup-test.pid"
CLEAN_PID=$(awk '{print $1}' "$CLEAN_PID_FILE")

# Hook reads JSON from stdin (Claude Code passes session info); pass minimal valid JSON.
echo '{"session_id":"cleanup-test"}' | CLAUDE_CODE_SESSION_ID=cleanup-test "$HOOK"

sleep 0.2
if kill -0 "$CLEAN_PID" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: hook did not kill grip ($CLEAN_PID)"
else
  PASS=$((PASS+1)); echo "  PASS: hook killed grip"
fi
if [ -f "$CLEAN_PID_FILE" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: hook did not remove PID file"
else
  PASS=$((PASS+1)); echo "  PASS: hook removed PID file"
fi

rm -f "$MD5"

# --- Test: hook with mismatched starttime does NOT kill unrelated process ---
sleep 60 &
HOOK_VICTIM=$!
HOOK_VICT_FILE="$XDG_CACHE_HOME/claude-grip/hook-victim.pid"
echo "$HOOK_VICTIM 1" > "$HOOK_VICT_FILE"

echo '{"session_id":"hook-victim"}' | CLAUDE_CODE_SESSION_ID=hook-victim "$HOOK"

if kill -0 "$HOOK_VICTIM" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS: hook skipped kill on stale starttime"
else
  FAIL=$((FAIL+1)); echo "  FAIL: hook killed victim on stale starttime"
fi

kill "$HOOK_VICTIM" 2>/dev/null
rm -f "$HOOK_VICT_FILE"
```

- [ ] **Step 2: Run the test to verify failure**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: hook does not exist yet — both new asserts FAIL with "command not found" or similar.

- [ ] **Step 3: Implement the cleanup hook**

Write `/home/achen/git/gh/dotfiles/.claude/hooks/cleanup-grip.sh`:

```bash
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
  read -r PID STARTTIME < "$PID_FILE" 2>/dev/null || PID=""
  if [ -n "$PID" ] && [ -n "$STARTTIME" ]; then
    ACTUAL=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)
    if [ "$ACTUAL" = "$STARTTIME" ]; then
      kill "$PID" 2>/dev/null || true
    fi
  fi
  rm -f "$PID_FILE"
fi

# Also clear the log file to keep ~/.cache tidy.
rm -f "$STATE_DIR/${CLAUDE_CODE_SESSION_ID:-no-session}.log"

exit 0
```

```bash
chmod +x /home/achen/git/gh/dotfiles/.claude/hooks/cleanup-grip.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: `Results: 17 passed, 0 failed` (14 prior + kill-grip + remove-pid-file + stale-starttime-safety).

- [ ] **Step 5: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/hooks/cleanup-grip.sh tests/grip-review/test.sh
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
feat(grip-review): SessionEnd cleanup hook with starttime check

cleanup-grip.sh reaps the session's grip process and removes its
PID + log files from XDG_CACHE_HOME/claude-grip/. Verifies the
recorded /proc/$pid/stat starttime still matches before signalling
so a recycled PID (after a long session and a dead grip) can't take
out an unrelated user process. Drains stdin so Claude Code doesn't
block on a closed pipe.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: CLAUDE.md directive

**Files:**
- Modify: `/home/achen/git/gh/dotfiles/.claude/CLAUDE.md`

- [ ] **Step 1: Read current CLAUDE.md around the Code Review section**

Look at lines 97–112 (the "Code review" section is at line 97, "Trivial work" at 103, "Systematic Debugging" at 112). The new section logically slots between "Code review" and "Trivial work" — both are workflow-overrides like the new one.

- [ ] **Step 2: Insert the new section**

Add a new section after the "Code review" section (i.e., before "## Trivial work"):

```markdown
## Markdown review serving

When a superpowers skill (brainstorming, writing-plans, executing-plans, or any other) is about to ask Andrew to review a `.md` plan, spec, or design doc, FIRST invoke the `grip-review` skill on the absolute file path. The skill prints a non-localhost URL (e.g. `http://<lan-ip>:6531/...`) — include that URL in the review prompt to Andrew so he can open it from anywhere on his LAN.

Skip this for code review or for arbitrary markdown files unrelated to a superpowers review gate. If `grip-review` exits non-zero, fall back to asking Andrew to read the file directly and note the failure.
```

- [ ] **Step 3: Verify the file still parses cleanly**

Run: `grep -n '^##' /home/achen/git/gh/dotfiles/.claude/CLAUDE.md`
Expected: new section appears between "Code review" and "Trivial work".

- [ ] **Step 4: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/CLAUDE.md
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
feat(claude-md): wire superpowers reviews through grip-review

New section directs Claude to serve markdown plans/specs via the
grip-review skill at every superpowers review gate. Directive lives
in CLAUDE.md, not as a fork of the superpowers skills, per the
upstream-maintenance-tax principle (see feedback_codex_review_pairing).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Example settings.json fragment

**Files:**
- Create: `/home/achen/git/gh/dotfiles/.claude/settings.grip-review-example.json`

- [ ] **Step 1: Write the example fragment**

Write `/home/achen/git/gh/dotfiles/.claude/settings.grip-review-example.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(/home/achen/.claude/skills/grip-review/serve.sh *)"
    ]
  },
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/achen/.claude/hooks/cleanup-grip.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Verify JSON parses**

Run: `python3 -m json.tool /home/achen/git/gh/dotfiles/.claude/settings.grip-review-example.json >/dev/null`
Expected: exit 0, no output.

- [ ] **Step 3: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add .claude/settings.grip-review-example.json
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
docs(grip-review): example settings.json fragment

Documents the one Bash allow rule and the SessionEnd hook entry that
need to be added to the local ~/.claude/settings.json. Single allow
covers all of serve.sh's internal ops (mkdir, write, kill, grip) so
no operation prompts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: README symlink-loop update

**Files:**
- Modify: `/home/achen/git/gh/dotfiles/README.md`

- [ ] **Step 1: Read the relevant chunk of README**

Read `/home/achen/git/gh/dotfiles/README.md` lines 20–60 (the "Personal skills + CLAUDE.md: symlink from this repo" section).

- [ ] **Step 2: Add grip-review to the skills loop**

Find the line:
```bash
for s in codex-review java-style; do
```

Replace with:
```bash
for s in codex-review java-style grip-review; do
```

- [ ] **Step 3: Add a paragraph about symlinking the cleanup hook**

After the skills loop's closing `done` line in README.md, before the next `### Helper scripts: symlink from ~/bin` section, append the following block. (Plain markdown — triple-backticks are literal, no escaping.)

    The grip-review skill also needs its SessionEnd hook symlinked:

    ```bash
    mkdir -p ~/.claude/hooks
    ln -sf "$PWD/.claude/hooks/cleanup-grip.sh" "$HOME/.claude/hooks/cleanup-grip.sh"
    ```

    Then merge `.claude/settings.grip-review-example.json` into your live `~/.claude/settings.json` (the live file is intentionally not tracked; the example shows the allow rule and the SessionEnd hook entry to add).

(The four-space indent above is just to render the block here without nested-fence trouble; in the actual README the paragraph and code block are flush-left, ordinary markdown.)

- [ ] **Step 4: Commit**

```bash
git -C /home/achen/git/gh/dotfiles add README.md
git -C /home/achen/git/gh/dotfiles commit -m "$(cat <<'EOF'
docs(readme): grip-review skill + hook install steps

Add grip-review to the symlink loop, document the separate hook
symlink and the settings.json merge.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Install symlinks locally

**Files:** (no dotfiles changes — only `~/.claude/` symlinks)

- [ ] **Step 1: Symlink the skill**

```bash
ln -sf /home/achen/git/gh/dotfiles/.claude/skills/grip-review /home/achen/.claude/skills/grip-review
```

- [ ] **Step 2: Symlink the cleanup hook**

```bash
ln -sf /home/achen/git/gh/dotfiles/.claude/hooks/cleanup-grip.sh /home/achen/.claude/hooks/cleanup-grip.sh
```

- [ ] **Step 3: Verify both symlinks resolve**

```bash
readlink /home/achen/.claude/skills/grip-review
readlink /home/achen/.claude/hooks/cleanup-grip.sh
test -x /home/achen/.claude/skills/grip-review/serve.sh && echo serve.sh ok
test -x /home/achen/.claude/hooks/cleanup-grip.sh && echo hook ok
```

Expected: both readlinks print dotfiles paths; both "ok" lines print.

- [ ] **Step 4: No commit — these are local-only filesystem links.**

---

### Task 12: Live settings.json update (manual, requires Andrew's OK)

**Files:**
- Modify: `/home/achen/.claude/settings.json` (NOT in git)

- [ ] **Step 1: Read current settings.json**

Run: `python3 -m json.tool /home/achen/.claude/settings.json > /tmp/settings-before.json`

Inspect to see the current `permissions.allow` list and any existing `hooks.SessionEnd`.

- [ ] **Step 2: Show Andrew the proposed diff before applying**

Print the lines that will be added:
- One new entry in `permissions.allow`: `"Bash(/home/achen/.claude/skills/grip-review/serve.sh *)"`
- Either a new `SessionEnd` array (if none exists) or a new entry appended to the existing one.

Ask Andrew to confirm before editing the file.

- [ ] **Step 3: Apply the edit using the Edit tool**

After Andrew approves, use Edit to:
- Add `"Bash(/home/achen/.claude/skills/grip-review/serve.sh *)",` to the `allow` array (alphabetical or last position — match existing convention).
- Add the SessionEnd hook entry from the example file into `hooks` (creating the `SessionEnd` key if it doesn't exist).

- [ ] **Step 4: Verify JSON still parses**

Run: `python3 -m json.tool /home/achen/.claude/settings.json >/dev/null`
Expected: exit 0.

- [ ] **Step 5: No commit — `~/.claude/settings.json` is intentionally not in git.**

---

### Task 13: End-to-end smoke test

**Files:** (no edits — just verification)

- [ ] **Step 1: Run the test suite one more time end-to-end**

Run: `bash /home/achen/git/gh/dotfiles/tests/grip-review/test.sh`
Expected: `Results: 17 passed, 0 failed`.

- [ ] **Step 2: Real-world smoke against the live serve.sh and live grip**

```bash
echo "# smoke" > /tmp/smoke.md
/home/achen/.claude/skills/grip-review/serve.sh /tmp/smoke.md
```

Expected: prints a `http://<lan-ip>:<port>/smoke.md` URL. Open it in a browser on the LAN; should render the markdown.

- [ ] **Step 3: Smoke test cleanup hook**

```bash
ls /home/achen/.cache/claude-grip/
echo '{"session_id":"smoke"}' | /home/achen/.claude/hooks/cleanup-grip.sh
ls /home/achen/.cache/claude-grip/ 2>/dev/null
pgrep -f 'go-grip.*smoke' && echo "FAIL: grip still alive" || echo "OK: cleaned up"
```

Expected: PID file removed, grip process gone.

- [ ] **Step 4: Final commit (only if any drift surfaced)**

If smoke tests revealed any needed tweaks, commit them. Otherwise no-op.

---

## Self-review notes (filled during writing)

- Spec coverage: All five components from the design (skill, serve.sh, hook, CLAUDE.md edit, dotfiles wiring) have dedicated tasks.
- Placeholder scan: All `<filename>` and `<port>` references are illustrative inside code/markdown blocks, not action items left for the engineer to fill.
- Type consistency: PID-file path uses `${CLAUDE_CODE_SESSION_ID:-no-session}.pid` throughout (serve.sh, cleanup-grip.sh, tests). PID file format is `"PID STARTTIME"` (two whitespace-separated fields) throughout — readers consistently use `awk '{print $1}'` for the PID and `read -r PID STARTTIME < file` when both are needed.
- Memory cross-check:
  - `feedback_dotfiles_hook_wiring.md`: ✓ hook in `.claude/hooks/`, example settings checked in, live settings out of git.
  - `feedback_codex_review_pairing.md`: ✓ directive in CLAUDE.md, no superpowers fork.
  - `claude_md_symlink.md`: ✓ edit at dotfiles path, symlink propagates.
  - `feedback_heredoc_no_escape.md`: ✓ no `$`/`` ` `` escaping inside heredocs.
  - `dotfiles_skill_sources.md`: ✓ adding a third personal skill; same pattern.

## Codex review findings (addressed in plan revision)

Codex flagged two P2 issues on the first plan revision (`0685bbe`). Both are addressed in the current plan:

1. **Double URL print bug.** Task 6's "Replace the single-shot launch block" instruction only delimited the launch-through-PID-write range, leaving Task 4's trailing `URL=$(grep...) ... echo "$URL"` block in place — serve.sh would print two URLs per invocation. **Fix:** Task 6 Step 3 now explicitly delimits the replacement range as launch (inclusive) through final `echo "$URL"` (inclusive), and a new regression test in Task 6 Step 1 asserts exactly one URL line on stdout via `grep -c '^http'`.

2. **PID recycling could kill unrelated processes.** `kill -0 $PID` only confirms a process with that PID exists; if grip crashed and Linux recycled the PID to an unrelated user process, both kill-prior (serve.sh) and the SessionEnd hook would signal the wrong process. **Fix:** The PID file format is now `"PID STARTTIME"`, where starttime comes from `/proc/$pid/stat` field 22 (stable across exec, unique per process). Both kill-prior and the cleanup hook verify the starttime still matches before signalling. New negative tests in Tasks 5 and 7 confirm a stale starttime aborts the kill.
