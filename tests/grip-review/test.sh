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

# Port must fall in expected range (shifted above Chromium's blocked-port list;
# the last blocked port below this band is 6697).
if [ "$PORT_A" -ge 6700 ] && [ "$PORT_A" -le 7699 ]; then
  PASS=$((PASS+1)); echo "  PASS: port in 6700-7699 range"
else
  FAIL=$((FAIL+1)); echo "  FAIL: port $PORT_A out of range 6700-7699"
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
  # PID file must have five whitespace-separated fields.
  FIELDS=$(awk '{print NF}' "$PID_FILE")
  assert_eq "PID file has 5 fields (pid+starttime+host+port+dir)" "$FIELDS" "5"
else
  FAIL=$((FAIL+1)); echo "  FAIL: PID file not at $PID_FILE"
fi

# Clean up this test's grip so subsequent tests start fresh.
[ -f "$PID_FILE" ] && kill "$(awk '{print $1}' "$PID_FILE")" 2>/dev/null
rm -f "$PID_FILE"
rm -f "$MD"

# --- Test: re-invocation with a sibling file reuses the live grip ---
# go-grip already serves every .md in the launch directory at its relative URL
# path, so a second review gate on a sibling file does not need a fresh process.
DIR_SIB=$(mktemp -d)
MD2A="$DIR_SIB/a.md"; echo "# a" > "$MD2A"
MD2B="$DIR_SIB/b.md"; echo "# b" > "$MD2B"

URL_2A=$("$SERVE" "$MD2A")
PID_FILE="$XDG_CACHE_HOME/claude-grip/$CLAUDE_CODE_SESSION_ID.pid"
FIRST_PID=$(awk '{print $1}' "$PID_FILE")

URL_2B=$("$SERVE" "$MD2B")
SECOND_PID=$(awk '{print $1}' "$PID_FILE")

assert_eq "sibling re-invocation reuses PID" "$FIRST_PID" "$SECOND_PID"

assert_contains "sibling URL points to second file" "$URL_2B" "/b.md"

# Exactly one URL line — the reuse path must not double-emit.
REUSE_URL_LINES=$(printf '%s\n' "$URL_2B" | grep -c '^http')
assert_eq "sibling reuse emits one URL line" "$REUSE_URL_LINES" "1"

if kill -0 "$FIRST_PID" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS: grip still alive after sibling reuse"
else
  FAIL=$((FAIL+1)); echo "  FAIL: grip died after sibling reuse"
fi

kill "$FIRST_PID" 2>/dev/null
rm -rf "$DIR_SIB"
rm -f "$PID_FILE"

# --- Test: reuse path percent-encodes URL-reserved chars in sibling names ---
# The launch path echoes go-grip's own URL (already escaped); the reuse path
# builds the URL itself and must encode chars like '#', '?', and space so the
# browser doesn't truncate at a fragment / query / whitespace.
DIR_ENC=$(mktemp -d)
echo "# seed" > "$DIR_ENC/seed.md"
"$SERVE" "$DIR_ENC/seed.md" >/dev/null
ENC_PID=$(awk '{print $1}' "$PID_FILE")

HASH_NAME='a#b.md'
echo "# hash" > "$DIR_ENC/$HASH_NAME"
URL_HASH=$("$SERVE" "$DIR_ENC/$HASH_NAME")
assert_contains "# in sibling filename encoded to %23" "$URL_HASH" "/a%23b.md"

SPACE_NAME='plan v2.md'
echo "# space" > "$DIR_ENC/$SPACE_NAME"
URL_SPACE=$("$SERVE" "$DIR_ENC/$SPACE_NAME")
assert_contains "space in sibling filename encoded to %20" "$URL_SPACE" "/plan%20v2.md"

# Multi-byte UTF-8 must encode per-byte, not per-codepoint. 'é' is 0xC3 0xA9.
UTF8_NAME='café.md'
echo "# utf8" > "$DIR_ENC/$UTF8_NAME"
URL_UTF8=$("$SERVE" "$DIR_ENC/$UTF8_NAME")
assert_contains "UTF-8 sibling filename encoded per byte" "$URL_UTF8" "/caf%C3%A9.md"

kill "$ENC_PID" 2>/dev/null
rm -rf "$DIR_ENC"
rm -f "$PID_FILE"

# --- Test: re-invocation in a different directory adds a second grip ---
# Both grips must stay alive so a spec (one dir) and a plan (another dir) can be
# reviewed at the same time. The PID file tracks one line per live grip.
DIR_X=$(mktemp -d); DIR_Y=$(mktemp -d)
MD_X="$DIR_X/x.md"; echo "# x" > "$MD_X"
MD_Y="$DIR_Y/y.md"; echo "# y" > "$MD_Y"

"$SERVE" "$MD_X" >/dev/null
FIRST_PID=$(awk 'NR==1{print $1}' "$PID_FILE")

"$SERVE" "$MD_Y" >/dev/null
SECOND_PID=$(awk 'NR==2{print $1}' "$PID_FILE")

PID_LINES=$(grep -c . "$PID_FILE")
assert_eq "different dir -> PID file has 2 grip lines" "$PID_LINES" "2"

if [ -n "$FIRST_PID" ] && [ "$FIRST_PID" != "$SECOND_PID" ]; then
  PASS=$((PASS+1)); echo "  PASS: different-dir invocation adds a distinct grip"
else
  FAIL=$((FAIL+1)); echo "  FAIL: second grip not distinct (first=$FIRST_PID second=$SECOND_PID)"
fi

sleep 0.2
if kill -0 "$FIRST_PID" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS: first grip still alive after different-dir invocation"
else
  FAIL=$((FAIL+1)); echo "  FAIL: first grip was killed on different-dir invocation ($FIRST_PID)"
fi
if kill -0 "$SECOND_PID" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS: second grip alive"
else
  FAIL=$((FAIL+1)); echo "  FAIL: second grip not alive ($SECOND_PID)"
fi

kill "$FIRST_PID" "$SECOND_PID" 2>/dev/null
rm -rf "$DIR_X" "$DIR_Y"
rm -f "$PID_FILE"

# --- Test: superpowers spec + plan share ONE grip rooted at docs/superpowers ---
# brainstorming writes docs/superpowers/specs/<topic>-design.md and writing-plans
# writes docs/superpowers/plans/<feature>.md — different dirs but a common
# ancestor. Rooting one grip at that ancestor serves both at /specs/.. and
# /plans/.. so the spec stays live while the plan is reviewed.
SP_ROOT=$(mktemp -d)/docs/superpowers
mkdir -p "$SP_ROOT/specs" "$SP_ROOT/plans"
SPEC="$SP_ROOT/specs/2026-05-30-thing-design.md"; echo "# spec" > "$SPEC"
PLAN="$SP_ROOT/plans/2026-05-30-thing.md"; echo "# plan" > "$PLAN"

URL_SPEC=$("$SERVE" "$SPEC")
SPEC_PID=$(awk 'NR==1{print $1}' "$PID_FILE")
URL_PLAN=$("$SERVE" "$PLAN")
PLAN_PID=$(awk 'NR==1{print $1}' "$PID_FILE")

assert_contains "spec URL is under /specs/"  "$URL_SPEC" "/specs/2026-05-30-thing-design.md"
assert_contains "plan URL is under /plans/"  "$URL_PLAN" "/plans/2026-05-30-thing.md"
assert_eq "spec and plan reuse the same grip PID" "$SPEC_PID" "$PLAN_PID"

SP_LINES=$(grep -c . "$PID_FILE")
assert_eq "superpowers spec+plan -> single grip line" "$SP_LINES" "1"

# Both URLs must share host:port (same daemon).
SPEC_HP=$(echo "$URL_SPEC" | sed -E 's#http://([^/]+)/.*#\1#')
PLAN_HP=$(echo "$URL_PLAN" | sed -E 's#http://([^/]+)/.*#\1#')
assert_eq "spec and plan share host:port" "$SPEC_HP" "$PLAN_HP"

if kill -0 "$SPEC_PID" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS: shared grip alive after serving plan"
else
  FAIL=$((FAIL+1)); echo "  FAIL: shared grip died ($SPEC_PID)"
fi

kill "$SPEC_PID" 2>/dev/null
rm -rf "$SP_ROOT"
rm -f "$PID_FILE"

# --- Test: reuse requires an EXACT root match, not merely an ancestor ---
# The skill scans the directory go-grip will root at before serving; if a
# broader-rooted grip (e.g. rooted at docs/) were reused for a deeper file
# (docs/superpowers/specs/x.md), markdown outside the scanned root would be
# served unchecked. So a grip rooted at a parent dir must NOT be reused for
# a file in a subdirectory: a second grip rooted at the subdir is launched.
DIR_PAR=$(mktemp -d)
mkdir -p "$DIR_PAR/sub"
echo "# parent" > "$DIR_PAR/a.md"
echo "# deep" > "$DIR_PAR/sub/b.md"

"$SERVE" "$DIR_PAR/a.md" >/dev/null
PAR_PID=$(awk 'NR==1{print $1}' "$PID_FILE")

URL_DEEP=$("$SERVE" "$DIR_PAR/sub/b.md")
DEEP_PID=$(awk 'NR==2{print $1}' "$PID_FILE")

assert_contains "deep file served from its own dir" "$URL_DEEP" "/b.md"
if [ -n "$DEEP_PID" ] && [ "$DEEP_PID" != "$PAR_PID" ]; then
  PASS=$((PASS+1)); echo "  PASS: subdir file gets its own grip (no ancestor reuse)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: ancestor-rooted grip was reused (pid $DEEP_PID)"
fi

if kill -0 "$PAR_PID" 2>/dev/null && kill -0 "$DEEP_PID" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  PASS: both grips alive after exact-root split"
else
  FAIL=$((FAIL+1)); echo "  FAIL: a grip died after exact-root split"
fi

kill "$PAR_PID" "$DEEP_PID" 2>/dev/null
rm -rf "$DIR_PAR"
rm -f "$PID_FILE"

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

# --- Test: cleanup-grip.sh reaps ALL of a session's grips ---
# A session can hold several grips (e.g. one per general dir). The hook must
# kill every tracked grip, not just the first line of the PID file.
MG_A=$(mktemp -d); MG_B=$(mktemp -d)
echo "# a" > "$MG_A/a.md"; echo "# b" > "$MG_B/b.md"
CLAUDE_CODE_SESSION_ID=multi-clean "$SERVE" "$MG_A/a.md" >/dev/null
CLAUDE_CODE_SESSION_ID=multi-clean "$SERVE" "$MG_B/b.md" >/dev/null
MG_PID_FILE="$XDG_CACHE_HOME/claude-grip/multi-clean.pid"
MG_PID1=$(awk 'NR==1{print $1}' "$MG_PID_FILE")
MG_PID2=$(awk 'NR==2{print $1}' "$MG_PID_FILE")

echo '{"session_id":"multi-clean"}' | CLAUDE_CODE_SESSION_ID=multi-clean "$HOOK"
sleep 0.2

if kill -0 "$MG_PID1" 2>/dev/null || kill -0 "$MG_PID2" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: hook left a grip alive ($MG_PID1 / $MG_PID2)"
else
  PASS=$((PASS+1)); echo "  PASS: hook reaped all session grips"
fi
if [ -f "$MG_PID_FILE" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL: hook did not remove multi-grip PID file"
else
  PASS=$((PASS+1)); echo "  PASS: hook removed multi-grip PID file"
fi
kill "$MG_PID1" "$MG_PID2" 2>/dev/null
rm -rf "$MG_A" "$MG_B"

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

# --- Test: escape-currency-dollars.py escapes currency, preserves code and math ---
# go-grip's MathJax extension pairs any two $ in one block as inline math, so
# currency like "$1,200 ... $3,400" italicizes the prose between the amounts and
# swallows **bold**. The skill's serve step must escape every currency $ as \$,
# while leaving code (a backslash there would render literally) and real math
# ($x^2$ — no digit after the opening $) untouched.
ESC="$DOTFILES/.claude/skills/grip-review/escape-currency-dollars.py"

ESC_DIR=$(mktemp -d)
ESC_MD="$ESC_DIR/sample.md"
cat > "$ESC_MD" <<'EOF'
The migration costs $1,200 up front and **$3,400 per month** after that.
A pre-escaped amount \$50 must stay escaped, not double-escaped.
Non-currency $vars and real math $x^2$ must stay untouched.

```bash
export MONTHLY_BUDGET=$3400
```

Run `awk '{sum+=$100}' ledger` to total the ledger.
EOF

ESC_OUT=$("$ESC" "$ESC_MD")
# Exactly two currency $ in prose: $1,200 and $3,400.
assert_contains "escape reports 2 replacements" "$ESC_OUT" "2"

PROSE=$(sed -n '1,3p' "$ESC_MD")
assert_contains "currency $ escaped" "$PROSE" '\$1,200 up front and **\$3,400 per month**'
assert_contains "pre-escaped \$50 not double-escaped" "$PROSE" '\$50'
assert_contains "non-currency \$vars untouched" "$PROSE" '$vars'
assert_contains "real math \$x^2\$ untouched" "$PROSE" '$x^2$'

FENCE=$(sed -n '6p' "$ESC_MD")
assert_contains "code fence \$ untouched" "$FENCE" '$3400'

SPAN=$(sed -n '9p' "$ESC_MD")
assert_contains "inline code \$ untouched" "$SPAN" 'sum+=$100'

# Idempotent: a second pass must change nothing.
ESC_OUT2=$("$ESC" "$ESC_MD")
assert_contains "second pass reports 0 replacements" "$ESC_OUT2" "0"

# Directory arguments NEVER write — a bulk directory rewrite is the footgun
# this design exists to avoid. A directory arg scans read-only and reports
# only the affected files; escaping happens per single file, chosen by
# judgment. --check does the same for a single file argument.
ESC_DIR2=$(mktemp -d)
mkdir -p "$ESC_DIR2/sub" "$ESC_DIR2/.hidden"
printf 'Costs $99 today.\n' > "$ESC_DIR2/with-currency.md"
printf 'No money here.\n' > "$ESC_DIR2/clean.md"
printf 'Owes $7 to $12 in prose.\n' > "$ESC_DIR2/sub/nested.md"
printf 'Hidden $5 note.\n' > "$ESC_DIR2/.hidden/secret.md"
printf 'Binary \xff\xfe here.\n' > "$ESC_DIR2/nonutf8.md"

ESC_DIR_OUT=$("$ESC" "$ESC_DIR2" 2>&1)
assert_contains "dir scan reports affected sibling" "$ESC_DIR_OUT" "with-currency.md: 1 unescaped currency \$"
assert_contains "dir scan reports affected nested" "$ESC_DIR_OUT" "sub/nested.md: 2 unescaped currency \$"
if echo "$ESC_DIR_OUT" | grep -qF "clean.md"; then
  FAIL=$((FAIL+1)); echo "  FAIL: dir scan lists clean file (noise)"
else
  PASS=$((PASS+1)); echo "  PASS: dir scan omits clean file"
fi
if echo "$ESC_DIR_OUT" | grep -qF ".hidden"; then
  FAIL=$((FAIL+1)); echo "  FAIL: dir scan descends into hidden dir"
else
  PASS=$((PASS+1)); echo "  PASS: dir scan skips hidden dirs"
fi
assert_contains "dir scan leaves sibling unmodified" "$(cat "$ESC_DIR2/with-currency.md")" 'Costs $99 today.'
assert_contains "dir scan leaves nested unmodified" "$(cat "$ESC_DIR2/sub/nested.md")" 'Owes $7 to $12 in prose.'
if echo "$ESC_DIR_OUT" | grep -qF "nonutf8.md"; then
  PASS=$((PASS+1)); echo "  PASS: dir scan reports non-UTF-8 file as error"
else
  FAIL=$((FAIL+1)); echo "  FAIL: dir scan swallowed non-UTF-8 file silently"
fi

# Escaping happens per file: the sibling in scope gets escaped, the rest of
# the tree stays as-is.
"$ESC" "$ESC_DIR2/with-currency.md" >/dev/null
assert_contains "per-file escape rewrites sibling" "$(cat "$ESC_DIR2/with-currency.md")" '\$99'
assert_contains "per-file escape leaves nested alone" "$(cat "$ESC_DIR2/sub/nested.md")" 'Owes $7 to $12 in prose.'

# --check on a single file: reports the count, writes nothing.
ESC_CHECK_FILE=$("$ESC" --check "$ESC_DIR2/sub/nested.md")
assert_contains "check on single file reports count" "$ESC_CHECK_FILE" "2 unescaped currency \$"
assert_contains "check left single file unmodified" "$(cat "$ESC_DIR2/sub/nested.md")" 'Owes $7 to $12 in prose.'

# A nonexistent path is an error, not silence.
ESC_MISSING_OUT=$("$ESC" "$ESC_DIR2/nope.md" 2>&1)
ESC_MISSING_RC=$?
if [ "$ESC_MISSING_RC" -ne 0 ] && echo "$ESC_MISSING_OUT" | grep -qF "no such file or directory"; then
  PASS=$((PASS+1)); echo "  PASS: nonexistent path errors with nonzero exit"
else
  FAIL=$((FAIL+1)); echo "  FAIL: nonexistent path rc=$ESC_MISSING_RC out=$ESC_MISSING_OUT"
fi

# A bad arg must not suppress a good arg's scan summary (per-arg error flag).
ESC_MIXED=$("$ESC" "$ESC_DIR2/nope.md" "$ESC_DIR2" 2>&1)
assert_contains "mixed args still summarize the good dir" "$ESC_MIXED" "of 4 markdown files scanned; see errors above"

# Partial summary with exactly one readable file: the noun describes the total
# set, so it must pluralize from the scanned count, not the successful count.
ESC_PART=$(mktemp -d)
printf 'Costs $99 today.\n' > "$ESC_PART/good.md"
printf 'Binary \xff\xfe here.\n' > "$ESC_PART/bad.md"
ESC_PART_OUT=$("$ESC" "$ESC_PART" 2>&1)
assert_contains "partial summary pluralizes from scanned count" "$ESC_PART_OUT" "1 of 2 markdown files scanned"
rm -rf "$ESC_PART"

rm -rf "$ESC_DIR2"

# CRLF files must keep their line endings: reading in default text mode
# translates \r\n to \n, so a rewrite would silently reflow the whole file.
ESC_CRLF=$(mktemp --suffix=.md)
printf 'Costs $99 total.\r\nSecond line.\r\n' > "$ESC_CRLF"
"$ESC" "$ESC_CRLF" >/dev/null
CR_COUNT=$(tr -cd '\r' < "$ESC_CRLF" | wc -c)
assert_eq "CRLF file keeps its carriage returns" "$CR_COUNT" "2"
assert_contains "CRLF file still escaped" "$(cat "$ESC_CRLF")" '\$99'
rm -f "$ESC_CRLF"
rm -rf "$ESC_DIR"

echo
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
