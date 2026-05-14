#!/usr/bin/env bash
# ABOUTME: Smoke-test harness for codex-review-capture and the codex-gate hooks.
# ABOUTME: Spins up a throwaway git repo per test, stubs `codex` on PATH, and
# ABOUTME: drives the wrapper / hooks with synthesized JSON.

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

assert_file_exists() {
  if [[ -f "$1" ]]; then
    printf '  ok file exists: %s\n' "$1"
    PASSED=$((PASSED+1))
  else
    printf '  FAIL file missing: %s\n' "$1"
    FAILED=$((FAILED+1))
  fi
}

assert_no_file() {
  if [[ ! -e "$1" ]]; then
    printf '  ok file absent: %s\n' "$1"
    PASSED=$((PASSED+1))
  else
    printf '  FAIL file present: %s\n' "$1"
    FAILED=$((FAILED+1))
  fi
}

setup_repo() {
  # A few tests toggle `set +e ... set -e` to call the gate without aborting
  # on its expected non-zero exit, but the trailing `set -e` leaks into later
  # tests. Reset to no-`-e` here so every test starts in a known state.
  set +e
  REPO=$(mktemp -d -t codex-gate-test.XXXXXX)
  cd "$REPO"
  git init -q
  git symbolic-ref HEAD refs/heads/main
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  REPO_NAME=$(basename "$REPO")
  HARNESS_BIN=$(mktemp -d -t codex-gate-bin.XXXXXX)
  ln -sf "$HARNESS_DIR/fake-codex.sh" "$HARNESS_BIN/codex"
  export PATH="$HARNESS_BIN:$PATH"
  export FAKE_CODEX_RC=0
  # Isolate codex's session-file scan from the user's real ~/.codex/sessions so
  # the wrapper's token-summary lookup only sees files this test produced.
  export CODEX_HOME=$(mktemp -d -t codex-home.XXXXXX)
  # Isolate the wrapper from the surrounding Claude Code session: tests that
  # want to exercise the Claude-Code-promotes-its-own-sentinel path set this
  # explicitly. Others should see the legacy staged-file-only behavior.
  unset CLAUDE_CODE_SESSION_ID
}

teardown_repo() {
  cd /
  rm -rf "$REPO"
  rm -f "/tmp/codex-gate-staged-${UID}-${REPO_NAME}-"* 2>/dev/null
  rm -f "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-"* 2>/dev/null
  rm -f "/tmp/codex-gate-"*"-${REPO_NAME}" 2>/dev/null
  [[ -n "${HARNESS_BIN:-}" ]] && rm -rf "$HARNESS_BIN"
  [[ -n "${CODEX_HOME:-}" ]] && rm -rf "$CODEX_HOME"
  unset CODEX_HOME FAKE_CODEX_TOKENS FAKE_CODEX_MODEL FAKE_CODEX_TURN1_TOTAL
}

# Tests appended below

test_wrapper_commit_mode_records_parent_as_base() {
  setup_repo
  echo "first" > a.txt
  git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m "add a"
  COMMIT=$(git rev-parse HEAD)
  echo "uncommitted_dirty" > b.txt
  "$DOTFILES/bin/codex-review-capture" --commit "$COMMIT" >/dev/null 2>&1
  expected_base=$(git rev-parse "$COMMIT^")
  expected_hash=$(git diff "$COMMIT^" "$COMMIT" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${expected_hash}"
  assert_file_exists "$reviewed"
  if [[ -f "$reviewed" ]]; then
    assert_eq "$(cat "$reviewed")" "$expected_base" "commit mode: BASE = parent of reviewed commit (dirty tree ignored)"
  fi
  rm -f "$reviewed"
  teardown_repo
}

test_wrapper_base_mode_records_merge_base() {
  setup_repo
  echo "main_change" > m.txt
  git add m.txt && git -c user.email=t@t -c user.name=t commit -q -m "main"
  git checkout -q -b feature
  echo "feat_change" > f.txt
  git add f.txt && git -c user.email=t@t -c user.name=t commit -q -m "feat"
  "$DOTFILES/bin/codex-review-capture" --base main >/dev/null 2>&1
  expected_base=$(git merge-base main HEAD)
  expected_hash=$(git diff "$expected_base" HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${expected_hash}"
  assert_file_exists "$reviewed"
  if [[ -f "$reviewed" ]]; then
    assert_eq "$(cat "$reviewed")" "$expected_base" "base mode: BASE = merge-base(main, HEAD)"
  fi
  rm -f "$reviewed"
  teardown_repo
}

test_wrapper_removes_staged_on_codex_failure() {
  setup_repo
  # Stage the file so there are no untracked files; the fail-closed untracked
  # guard must not fire — this test exercises the codex-exit-code cleanup path.
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_RC=42 "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null) || true
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  if [[ -n "$staged" ]]; then
    assert_no_file "$staged"
  else
    printf '  FAIL no staged path emitted\n'
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_skips_staged_for_unknown_mode() {
  setup_repo
  stderr=$("$DOTFILES/bin/codex-review-capture" 2>&1 >/dev/null)
  staged_line=$(echo "$stderr" | grep -E 'staged=' || true)
  assert_eq "$staged_line" "" "no staged file written when no mode flag"
  teardown_repo
}

test_wrapper_uncommitted_with_untracked_fails_closed() {
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "untracked_content" > new.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged_line=$(echo "$stderr" | grep -E '^codex-review-capture: staged=' || true)
  assert_eq "$staged_line" "" "no staged file when untracked files present"
  if echo "$stderr" | grep -q 'untracked files'; then
    printf '  ok stderr explains the untracked-files reason\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not mention untracked files\n'
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_accepts_equals_form_commit_flag() {
  setup_repo
  echo "first" > a.txt
  git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m "add a"
  COMMIT=$(git rev-parse HEAD)
  "$DOTFILES/bin/codex-review-capture" "--commit=$COMMIT" >/dev/null 2>&1
  expected_base=$(git rev-parse "$COMMIT^")
  expected_hash=$(git diff "$COMMIT^" "$COMMIT" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${expected_hash}"
  assert_file_exists "$reviewed"
  if [[ -f "$reviewed" ]]; then
    assert_eq "$(cat "$reviewed")" "$expected_base" "equals-form --commit= parsed correctly"
  fi
  rm -f "$reviewed"
  teardown_repo
}

test_wrapper_uncommitted_detects_untracked_from_subdir() {
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  mkdir sub
  echo "sneaky" > sneaky.txt   # untracked, in repo root
  cd sub
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged_line=$(echo "$stderr" | grep -E '^codex-review-capture: staged=' || true)
  assert_eq "$staged_line" "" "no staged file when untracked exist outside cwd"
  if echo "$stderr" | grep -q 'sneaky.txt'; then
    printf '  ok stderr names the untracked file\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not name sneaky.txt\n'
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_accepts_equals_form_base_flag() {
  setup_repo
  echo "main_change" > m.txt
  git add m.txt && git -c user.email=t@t -c user.name=t commit -q -m "main"
  git checkout -q -b feature
  echo "feat_change" > f.txt
  git add f.txt && git -c user.email=t@t -c user.name=t commit -q -m "feat"
  "$DOTFILES/bin/codex-review-capture" "--base=main" >/dev/null 2>&1
  expected_base=$(git merge-base main HEAD)
  expected_hash=$(git diff "$expected_base" HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${expected_hash}"
  assert_file_exists "$reviewed"
  if [[ -f "$reviewed" ]]; then
    assert_eq "$(cat "$reviewed")" "$expected_base" "equals-form --base= uses merge-base"
  fi
  rm -f "$reviewed"
  teardown_repo
}

test_e2e_uncommitted_review_then_push_passes() {
  setup_repo
  echo "feature" > feat.txt
  git add feat.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline before feature"
  echo "modified feature" > feat.txt
  "$DOTFILES/bin/codex-review-capture" --uncommitted >/dev/null 2>&1
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate accepts after fresh uncommitted review"
  expected_hash=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  rm -f "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${expected_hash}"
  teardown_repo
}

test_e2e_uncommitted_review_then_extra_edit_blocks() {
  setup_repo
  echo "feature" > feat.txt
  git add feat.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified feature" > feat.txt
  reviewed_hash=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  "$DOTFILES/bin/codex-review-capture" --uncommitted >/dev/null 2>&1
  echo "extra modification" > feat.txt
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks (exit 2) when tree diverges from review"
  rm -f "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${reviewed_hash}"
  teardown_repo
}

test_e2e_commit_review_with_dirty_tree_blocks_unreviewed_commit() {
  setup_repo
  echo "reviewed_change" > r.txt
  git add r.txt && git -c user.email=t@t -c user.name=t commit -q -m "reviewed"
  COMMIT=$(git rev-parse HEAD)
  reviewed_hash=$(git diff "$COMMIT^" "$COMMIT" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  echo "unreviewed_dirty" > u.txt
  git add u.txt
  "$DOTFILES/bin/codex-review-capture" --commit "$COMMIT" >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -q -m "unreviewed"
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "P1 #2: gate blocks when committing unreviewed dirty edits after --commit review"
  rm -f "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${reviewed_hash}"
  teardown_repo
}

test_gate_blocks_on_empty_sentinel_file() {
  # A reviewed-* file with no BASE line is unverifiable. Gate must skip it
  # like any other unparseable sentinel and report "no review found" if
  # nothing else matches.
  setup_repo
  echo "feature" > feat.txt
  git add feat.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  fake_hash="2222222222222222222222222222222222222222222222222222222222222222"
  : > "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${fake_hash}"
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  set +e
  out=$(echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate exits 2 when only sentinel on file is empty"
  if echo "$out" | grep -q 'BLOCKED'; then
    printf '  ok stderr says BLOCKED\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not say BLOCKED, got: %s\n' "$out"
    FAILED=$((FAILED+1))
  fi
  rm -f "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${fake_hash}"
  teardown_repo
}

test_wrapper_includes_elapsed_in_tokens_summary() {
  # Pin the format shape, not just presence: the duration must match one of
  # the three branches of `format_elapsed` (Ns / NmNNs / NhNNmNNs). Catches
  # a regression where a buggy formatter prints `0s` for every input.
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TOKENS="100 50 200 30 330" "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  if echo "$stderr" | grep -qE 'codex-review-capture: tokens .* elapsed=([0-9]+s|[0-9]+m[0-9]{2}s|[0-9]+h[0-9]{2}m[0-9]{2}s)( |$)'; then
    printf '  ok tokens line includes elapsed= field in a valid format\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL no elapsed= field in tokens line (or wrong format)\n    stderr:\n%s\n' "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_emits_tokens_summary_from_session() {
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TOKENS="100 50 200 30 330" "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=100 cached=50 output=200 reasoning=30 total=330'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok tokens summary present in stderr\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL no tokens summary in stderr; expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_appends_cost_for_gpt_5_5() {
  # gpt-5.5 standard pricing per 1M: input $5, cached $0.5, output $30.
  # Math: non-cached = 1000 - 400 = 600.
  # cost = (600*5 + 400*0.5 + 200*30) / 1_000_000 = 9200 / 1_000_000 = $0.0092
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TOKENS="1000 400 200 50 1200" FAKE_CODEX_MODEL="gpt-5.5" "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=1,000 cached=400 output=200 reasoning=50 total=1,200 cost=$0.0092 model=gpt-5.5'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok cost line correct for gpt-5.5\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_appends_cost_for_gpt_5_4() {
  # gpt-5.4 standard pricing per 1M: input $2.5, cached $0.25, output $15.
  # cost = (600*2.5 + 400*0.25 + 200*15) / 1_000_000 = 4600 / 1_000_000 = $0.0046
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TOKENS="1000 400 200 50 1200" FAKE_CODEX_MODEL="gpt-5.4" "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=1,000 cached=400 output=200 reasoning=50 total=1,200 cost=$0.0046 model=gpt-5.4'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok cost line correct for gpt-5.4\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_tolerates_orchestrator_session_in_candidates() {
  # Real `codex review` emits TWO session files: an orchestrator with
  # source=="exec" (a string) and a review sub-agent with source=={...}.
  # If the wrapper's candidate-scan trips on the orchestrator's shape, the
  # sub-agent is never inspected and the tokens line goes missing.
  setup_repo
  decoy_dir="$CODEX_HOME/sessions/$(date -u +%Y/%m/%d)"
  mkdir -p "$decoy_dir"
  printf '{"type":"session_meta","payload":{"source":"exec","cwd":"%s","timestamp":"2026-01-01T00:00:00Z"}}\n' "$REPO" \
    > "$decoy_dir/rollout-orchestrator.jsonl"
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TOKENS="1000 400 200 50 1200" \
           FAKE_CODEX_MODEL="gpt-5.5" \
           "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=1,000 cached=400 output=200 reasoning=50 total=1,200 cost=$0.0092 model=gpt-5.5'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok orchestrator-style decoy does not break sub-agent extraction\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_sums_mixed_tier_costs_per_turn() {
  # Turn 1: delta=(50k, 10k, 1k) — short. cost = 40k*5 + 10k*0.5 + 1k*30 = 235,000
  # Turn 2: delta=(300k, 100k, 500) — long.  cost = 200k*10 + 100k*1 + 500*45 = 2,122,500
  # Total: 2,357,500 / 1M = $2.3575. This protects the per-turn tier decision —
  # a regression that decided tier once from the final turn would mis-bill.
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TURN1_TOTAL="50000 10000 1000 100 51000" \
           FAKE_CODEX_TOKENS="350000 110000 1500 150 351500" \
           FAKE_CODEX_MODEL="gpt-5.5" \
           "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=350,000 cached=110,000 output=1,500 reasoning=150 total=351,500 cost=$2.3575 model=gpt-5.5'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok mixed-tier cost summed per turn\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_handles_duplicate_token_count_events() {
  # Real codex emits each token_count snapshot twice per turn. With delta-based
  # billing, the second occurrence telescopes to delta=(0,0,0) and contributes
  # nothing. Set turn-1 cumulative == final cumulative to simulate the duplicate
  # pattern; cost should still be the single-turn amount, not 2x.
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TURN1_TOTAL="1000 400 200 50 1200" \
           FAKE_CODEX_TOKENS="1000 400 200 50 1200" \
           FAKE_CODEX_MODEL="gpt-5.5" \
           "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=1,000 cached=400 output=200 reasoning=50 total=1,200 cost=$0.0092 model=gpt-5.5'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok duplicate events do not inflate cost\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_uses_long_context_rates_when_turn_exceeds_threshold() {
  # Per-turn input 300K >= 272K threshold: long-context rates for gpt-5.5 ($10 / $1 / $45 per 1M).
  # cost = (300000-100000)*10 + 100000*1 + 1000*45 = 2,145,000 / 1M = $2.1450
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TOKENS="300000 100000 1000 200 301000" FAKE_CODEX_MODEL="gpt-5.5" "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=300,000 cached=100,000 output=1,000 reasoning=200 total=301,000 cost=$2.1450 model=gpt-5.5'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok long-context: cost computed at long-tier rates\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_omits_cost_for_unknown_model() {
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$(FAKE_CODEX_TOKENS="1000 400 200 50 1200" FAKE_CODEX_MODEL="gpt-5.5-pro" "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  expected='codex-review-capture: tokens input=1,000 cached=400 output=200 reasoning=50 total=1,200 model=gpt-5.5-pro'
  if echo "$stderr" | grep -qF "$expected"; then
    printf '  ok unknown model: model shown, cost omitted\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL expected:\n    %s\n  got stderr:\n%s\n' "$expected" "$stderr"
    FAILED=$((FAILED+1))
  fi
  if echo "$stderr" | grep -qE '^codex-review-capture: tokens .* cost='; then
    printf '  FAIL cost= appeared for unknown model\n'
    FAILED=$((FAILED+1))
  else
    printf '  ok no cost= for unknown model\n'
    PASSED=$((PASSED+1))
  fi
  teardown_repo
}

test_wrapper_omits_tokens_summary_when_no_session() {
  setup_repo
  echo "x" > x.txt
  git add x.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  if echo "$stderr" | grep -qE '^codex-review-capture: tokens '; then
    printf '  FAIL unexpected tokens line in stderr:\n%s\n' "$stderr"
    FAILED=$((FAILED+1))
  else
    printf '  ok no tokens line when no session file present\n'
    PASSED=$((PASSED+1))
  fi
  teardown_repo
}

test_wrapper_no_sentinel_when_codex_fails() {
  setup_repo
  echo "x" > x.txt
  git add x.txt
  FAKE_CODEX_RC=42 "$DOTFILES/bin/codex-review-capture" --uncommitted >/dev/null 2>&1 || true
  shopt -s nullglob
  leaked_reviewed=( /tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-* )
  leaked_staged=( /tmp/codex-gate-staged-${UID}-${REPO_NAME}-* )
  shopt -u nullglob
  assert_eq "${#leaked_reviewed[@]}" "0" "no reviewed sentinel when codex exits nonzero"
  assert_eq "${#leaked_staged[@]}" "0" "staged file also cleaned up on codex failure"
  teardown_repo
}

test_gate_passes_compound_without_push_intent() {
  # Claude Code's `if: "Bash(<pat>)"` matcher fires every configured hook on
  # commands it can't parse (while/until/for loops, multi-line forms). The gate
  # must defend itself by parsing tool_input.command and exiting 0 when no real
  # push or PR-create appears.
  setup_repo
  gate_input=$(printf '{"session_id":"sessA","cwd":"%s","tool_input":{"command":"git tag foo HEAD && git tag --list pat"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on compound git-tag command (no push)"
  teardown_repo
}

test_gate_passes_while_loop_without_push_intent() {
  setup_repo
  gate_input=$(printf '{"session_id":"sessB","cwd":"%s","tool_input":{"command":"while read sha; do git show $sha; done"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on while-loop git-show command"
  teardown_repo
}

test_gate_passes_until_loop_with_gh_run_view() {
  setup_repo
  gate_input=$(printf '{"session_id":"sessC","cwd":"%s","tool_input":{"command":"until gh run view 123; do sleep 45; done"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on until-loop gh-run-view (not pr-create)"
  teardown_repo
}

test_gate_blocks_when_compound_includes_push() {
  setup_repo
  gate_input=$(printf '{"session_id":"sessD","cwd":"%s","tool_input":{"command":"git tag x && git push origin x"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate still blocks when compound command actually pushes"
  teardown_repo
}

test_gate_blocks_when_compound_includes_pr_create() {
  setup_repo
  gate_input=$(printf '{"session_id":"sessE","cwd":"%s","tool_input":{"command":"git tag x && gh pr create --title foo"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate still blocks when compound command creates a PR"
  teardown_repo
}

test_gate_passes_when_push_appears_only_as_substring() {
  # `git pushd` is not a real command but illustrates: word-boundary matters.
  # Equally important, `gitpush` (no space) must NOT match.
  setup_repo
  gate_input=$(printf '{"session_id":"sessF","cwd":"%s","tool_input":{"command":"echo gitpush-friendly-text"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate does not match 'gitpush' (no whitespace between git and push)"
  teardown_repo
}

test_gate_blocks_push_after_comment_line() {
  # Codex review caught this: when a comment line precedes the real push,
  # bash strips the comment per-line and runs the push. A flat tokenizer that
  # treats `#` globally would consume the whole multi-line block as a comment
  # and let the push slip past. bashlex models bash comment scoping natively.
  setup_repo
  cmd='# note about this run\ngit push origin main'
  gate_input=$(printf '{"session_id":"sessCmt1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push when a comment line precedes it"
  teardown_repo
}

test_gate_passes_comment_with_fake_push_followed_by_tag() {
  # `# fake ; git push` is entirely a bash comment -- the `;` inside doesn't
  # terminate anything because the whole line is a comment. The real command
  # is `git tag x` on the next line. bashlex's per-line comment scoping
  # ensures we don't over-fire the gate just because comment text mentions
  # push.
  setup_repo
  cmd='# fake ; git push origin main\ngit tag x'
  gate_input=$(printf '{"session_id":"sessCmt2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 when only a comment mentions push"
  teardown_repo
}

test_gate_blocks_push_after_bare_newline() {
  # Codex review caught this: a multi-line bash input where `git push` follows
  # an unescaped newline -- which bash treats as a command terminator -- must
  # still trigger the gate. shlex with whitespace_split absorbs newlines as
  # whitespace by default, so we have to pre-replace newlines with `; `.
  setup_repo
  cmd='git tag x\ngit push origin main'
  gate_input=$(printf '{"session_id":"sessNL1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push after bare newline in compound command"
  teardown_repo
}

test_gate_blocks_pr_create_after_bare_newline() {
  setup_repo
  cmd='git tag x\ngh pr create --title foo'
  gate_input=$(printf '{"session_id":"sessNL2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks pr create after bare newline"
  teardown_repo
}

test_gate_blocks_push_with_dynamic_option_value() {
  # Codex review caught: a valued option's value may word-split if dynamic.
  # `git -C $x origin main` where $x expands to `. push` runs `git -C . push
  # origin main` -- a real push. We have to fail closed when consuming a
  # dynamic value, not silently skip it as one token.
  setup_repo
  cmd='for x in y; do git -C $x origin main; done'
  gate_input=$(printf '{"session_id":"sessDynV1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push when valued-option value is dynamic"
  teardown_repo
}

test_gate_blocks_push_with_exec_prefix() {
  # exec replaces the shell with the named command; `exec git push` runs the
  # push. Adding `exec` to PASSTHROUGH picks it up via the recursive scan.
  setup_repo
  cmd="for x in y; do exec git push origin main; done"
  gate_input=$(printf '{"session_id":"sessExec1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push with exec prefix"
  teardown_repo
}

test_gate_blocks_push_via_eval_quoted_string() {
  # eval evaluates its arg(s) as shell. The quoted single-arg form keeps the
  # push as one word, so PASSTHROUGH adjacency doesn't see it -- need to
  # join args and parse as bash.
  setup_repo
  cmd="for x in y; do eval 'git push origin main'; done"
  gate_input=$(printf '{"session_id":"sessEval1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push via eval 'git push ...'"
  teardown_repo
}

test_gate_blocks_push_via_eval_unquoted_args() {
  # `eval git push origin main` has multiple args. eval joins them with
  # spaces, runs as shell. Same handling -- join and parse.
  setup_repo
  cmd="for x in y; do eval git push origin main; done"
  gate_input=$(printf '{"session_id":"sessEval2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push via eval with unquoted args"
  teardown_repo
}

test_gate_passes_eval_with_non_push_body() {
  # Negative case: eval with a non-push body must NOT over-fire.
  setup_repo
  gate_input=$(printf '{"session_id":"sessEval3","cwd":"%s","tool_input":{"command":"eval '"'"'echo hello'"'"'"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on eval with non-push body"
  teardown_repo
}

test_gate_blocks_push_with_env_then_optioned_git() {
  # Codex review caught: `env git -C ../repo push origin main` after env
  # passes through to git with global options. Adjacency-only matching on
  # the rest misses this (no adjacent `git push`). We need to recursively
  # classify after PASSTHROUGH, not just scan for adjacency.
  setup_repo
  cmd="for x in y; do env git -C ../repo push origin main; done"
  gate_input=$(printf '{"session_id":"sessRec1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks env-wrapped git push with -C option"
  teardown_repo
}

test_gate_blocks_push_with_sudo_then_shell_c() {
  setup_repo
  cmd="for x in y; do sudo sh -c 'gh pr create --title foo'; done"
  gate_input=$(printf '{"session_id":"sessRec2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks sudo-wrapped shell -c with pr create"
  teardown_repo
}

test_gate_blocks_push_with_shell_combined_flags() {
  # Codex review caught: `bash -lc '...'` has `-c` bundled with `-l`. An
  # exact `-c` lookup misses this; need to detect any short-flag bundle
  # containing `c`.
  setup_repo
  cmd="for x in y; do bash -lc 'git push origin main'; done"
  gate_input=$(printf '{"session_id":"sessFlag1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks bash -lc push (combined flag bundle)"
  teardown_repo
}

test_gate_blocks_pr_create_with_shell_ec_flags() {
  setup_repo
  cmd="for x in y; do sh -ec 'gh pr create --title x'; done"
  gate_input=$(printf '{"session_id":"sessFlag2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks sh -ec pr create (combined flag bundle)"
  teardown_repo
}

test_gate_blocks_push_in_process_substitution_redirect() {
  # Codex review caught: `cat < <(git push)` bash spawns git push as a
  # process substitution feeding cat's stdin. bashlex stores the inner
  # command under RedirectNode.output rather than .parts, so we have to
  # walk redirect targets too.
  setup_repo
  cmd='cat < <(git push origin main)'
  gate_input=$(printf '{"session_id":"sessRedir1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push hidden in process-substitution redirect"
  teardown_repo
}

test_gate_blocks_push_in_command_substitution_redirect_target() {
  setup_repo
  cmd=': > $(git push origin main)'
  gate_input=$(printf '{"session_id":"sessRedir2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push hidden in redirect-target substitution"
  teardown_repo
}

test_gate_blocks_push_with_dynamic_subcommand() {
  # Codex review caught this: bashlex flattens WordNodes to literal strings,
  # so `git $SUB origin main` (where $SUB might expand to `push`) compares
  # the literal '$SUB' against 'push' and reports no intent. We have to
  # fail closed whenever a dynamic word (parameter, command substitution,
  # tilde, etc.) sits in the head, option, or subcommand position.
  setup_repo
  cmd='for x in push; do git $x origin main; done'
  gate_input=$(printf '{"session_id":"sessDyn1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push with dynamic subcommand (for x in push)"
  teardown_repo
}

test_gate_blocks_push_with_dynamic_head() {
  setup_repo
  cmd='for tool in git; do $tool push origin main; done'
  gate_input=$(printf '{"session_id":"sessDyn2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push with dynamic command head"
  teardown_repo
}

test_gate_passes_real_push_with_dynamic_arg_after_subcommand() {
  # `git push $REMOTE` has $REMOTE in arg-position (after the push subcommand).
  # Since we already know it's a push, the dynamic remote name doesn't change
  # the intent -- still a push, gate fires. Pinning this to prevent over-
  # cautious fail-closing in arg positions that don't affect classification.
  setup_repo
  cmd='git push $REMOTE main'
  gate_input=$(printf '{"session_id":"sessDyn3","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks real push with dynamic remote arg"
  teardown_repo
}

test_gate_blocks_bash_dash_c_push() {
  # Codex review caught: `bash -c 'git push origin main'` delegates the push
  # to a subshell. Without recursive parsing of the -c body, the head is
  # 'bash' (not git/gh) and the push slips past. Solution: when head is a
  # shell wrapper with -c, recursively parse the body.
  setup_repo
  cmd="for x in y; do bash -c 'git push origin main'; done"
  gate_input=$(printf '{"session_id":"sessShell1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push via bash -c body"
  teardown_repo
}

test_gate_blocks_sh_dash_c_pr_create() {
  setup_repo
  cmd="for x in y; do sh -c 'gh pr create --title foo'; done"
  gate_input=$(printf '{"session_id":"sessShell2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks gh pr create via sh -c body"
  teardown_repo
}

test_gate_passes_bash_dash_c_non_push() {
  # A bash -c with no push in the body must still be allowed through.
  setup_repo
  gate_input=$(printf '{"session_id":"sessShell3","cwd":"%s","tool_input":{"command":"bash -c '"'"'echo hello world'"'"'"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on bash -c with non-push body"
  teardown_repo
}

test_gate_blocks_push_with_env_i_option() {
  # Codex review caught: env's own options (`-i`, `-u`, ...) sit between `env`
  # and the wrapped command. After stripping `env`, `-i` ends up as the head
  # and the parser misses the real push that follows. Each wrapper has its
  # own option grammar so we don't try to parse them precisely; instead we
  # switch to loose `git push` / `gh ... pr create` adjacency once a wrapper
  # is recognized.
  setup_repo
  cmd="for x in y; do env -i git push origin main; done"
  gate_input=$(printf '{"session_id":"sessW1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push wrapped by env with -i option"
  teardown_repo
}

test_gate_blocks_push_with_nice_n_value() {
  setup_repo
  cmd="for x in y; do nice -n 5 git push origin main; done"
  gate_input=$(printf '{"session_id":"sessW2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push wrapped by nice -n 5"
  teardown_repo
}

test_gate_blocks_push_with_sudo_wrapper() {
  # sudo was acknowledged as a minor gap in a prior review. The loose
  # adjacency approach makes it trivial to cover -- adding sudo to the
  # PASSTHROUGH set is enough (no need to parse sudo's option grammar).
  setup_repo
  cmd="for x in y; do sudo -u alice git push origin main; done"
  gate_input=$(printf '{"session_id":"sessW3","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push wrapped by sudo -u user"
  teardown_repo
}

test_gate_passes_env_with_non_push() {
  # The loose adjacency must not over-fire on env-wrapped non-pushes.
  setup_repo
  gate_input=$(printf '{"session_id":"sessW4","cwd":"%s","tool_input":{"command":"env -i git tag --list pat"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on env-wrapped non-push git command"
  teardown_repo
}

test_gate_blocks_push_with_env_wrapper() {
  # Codex review caught: `env GIT_SSH_COMMAND=... git push` is a real push that
  # the intent parser must recognize. Same for `command git push`.
  setup_repo
  cmd="for x in y; do env GIT_SSH_COMMAND=ssh git push origin main; done"
  gate_input=$(printf '{"session_id":"sessEnv1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push wrapped by env with var assignment"
  teardown_repo
}

test_gate_blocks_push_with_command_wrapper() {
  setup_repo
  cmd="while true; do command git push origin main; done"
  gate_input=$(printf '{"session_id":"sessEnv2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push wrapped by command builtin"
  teardown_repo
}

test_gate_blocks_push_with_unknown_global_option() {
  # Codex review caught: if `skip_options` treats an unknown valued option
  # like `--hostname VAL` as boolean, it stops at VAL and misses the real
  # push that follows. Fail-closed on unknown options: the segment falls
  # through to the gate.
  setup_repo
  cmd="for x in y; do gh --hostname ghe.example.com pr create --title foo; done"
  gate_input=$(printf '{"session_id":"sessUnk1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks gh pr create with valued option we recognize"
  teardown_repo
}

test_gate_passes_quoted_push_in_echo() {
  # The `git push` substring lives inside a quoted echo argument, not as an
  # actual command. A naive textual split on `;`/`&&` would mis-segment quoted
  # content; shlex respects the quotes and yields ["echo", "git push origin"]
  # as a single argument, so we correctly see no push intent.
  # The JSON value below must escape the embedded " as \" -- a regular bash
  # string `echo "git push origin main"` would produce invalid JSON.
  setup_repo
  cmd='echo \"git push origin main\"'
  gate_input=$(printf '{"session_id":"sessQ1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on echo of quoted git-push string"
  teardown_repo
}

test_gate_passes_commit_with_separator_in_message() {
  # `&&` inside a quoted -m message must not be mis-segmented. A textual splitter
  # would break the message and the second pseudo-segment "git push'" might be
  # mistaken for a push command. shlex keeps the message as one token.
  setup_repo
  cmd='git commit -m \"fix push && other regressions\"'
  gate_input=$(printf '{"session_id":"sessQ2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate exits 0 on commit with && and push inside -m message"
  teardown_repo
}

test_gate_blocks_push_with_p_boolean_option() {
  # The `-p` boolean option (paginate) doesn't take a value. A regex that
  # greedily consumes the next token as -p's value would miss the real push.
  # shlex + a whitelist of value-taking options (which -p is NOT in) handles
  # this correctly.
  setup_repo
  cmd="for x in y; do git -p push origin main; done"
  gate_input=$(printf '{"session_id":"sessQ3","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push with boolean -p global option"
  teardown_repo
}

test_gate_blocks_push_with_git_c_option() {
  # Codex review caught this: a real push that includes git-level options
  # between `git` and `push` (e.g., gh internally uses `git -c
  # credential.helper=...`) would slip past a strict `git[[:space:]]+push`
  # regex and false-allow when wrapped in an unparseable container (loop,
  # multi-line). The matcher fires the hook for the container; the hook must
  # still recognize the push inside.
  setup_repo
  cmd="for x in y; do git -c protocol.version=2 push origin main; done"
  gate_input=$(printf '{"session_id":"sessOpt1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push with -c k=v global option"
  teardown_repo
}

test_gate_blocks_push_with_no_pager_option() {
  setup_repo
  cmd="while true; do git --no-pager push origin main; done"
  gate_input=$(printf '{"session_id":"sessOpt2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push with --no-pager global option"
  teardown_repo
}

test_gate_blocks_push_with_multiple_c_options() {
  setup_repo
  cmd="for x in y; do git -c http.proxy=p -c init.defaultBranch=main push origin main; done"
  gate_input=$(printf '{"session_id":"sessOpt3","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks push with multiple -c options"
  teardown_repo
}

test_gate_blocks_pr_create_with_gh_global_option() {
  setup_repo
  cmd="for x in y; do gh -R foo/bar pr create --title x; done"
  gate_input=$(printf '{"session_id":"sessOpt4","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks gh pr create with -R global option"
  teardown_repo
}

test_gate_blocks_line_continued_push() {
  # Codex review caught this: a real `git push` written as
  #   git \
  #     push origin main
  # is still a push to bash, but the raw command string the hook sees has
  # backslash-newline between `git` and `push`, defeating the word-boundary
  # regex. Without normalization the gate would exit 0 and let an unreviewed
  # push through -- a false-allow on the gate's safety property.
  # The literal sequence `\\\n` in the cmd arg becomes JSON `\\\n`, which jq
  # decodes to backslash + newline -- the on-disk form of a line continuation.
  setup_repo
  cmd='git \\\npush origin main'
  gate_input=$(printf '{"session_id":"sessLC1","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks line-continued git push"
  teardown_repo
}

test_gate_blocks_line_continued_pr_create_between_pr_and_create() {
  setup_repo
  cmd='gh pr \\\ncreate --title foo'
  gate_input=$(printf '{"session_id":"sessLC2","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks line-continued gh pr create (between pr and create)"
  teardown_repo
}

test_gate_blocks_line_continued_compound_push() {
  setup_repo
  cmd='git tag x \\\n&& git push origin x'
  gate_input=$(printf '{"session_id":"sessLC3","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  assert_eq "$rc" "2" "gate blocks line-continued compound that ends in push"
  teardown_repo
}

test_gate_falls_through_when_tool_command_absent() {
  # Legacy / test inputs without tool_input.command must keep the previous
  # behavior: full sentinel check. With no sentinel present, the gate blocks.
  setup_repo
  gate_input=$(printf '{"session_id":"sessG","cwd":"%s"}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate falls through to full check when tool_input.command absent"
  teardown_repo
}

# A push whose refspecs are all `:`-prefix deletions has no commits to review,
# so the gate must let it through. Detection is positional-only -- any option
# after `push`, or any dynamic word, gates instead (fail-closed). `--delete`
# and `-d` flag forms are intentionally NOT supported: a valued option earlier
# on the line (e.g. `-o --delete`) can consume the flag, false-allowing a
# real push. Recovery for the rare flag form is a normal codex-review-capture
# run.

test_gate_passes_pure_delete_via_empty_source_refspec() {
  setup_repo
  gate_input=$(printf '{"session_id":"sessDel1","cwd":"%s","tool_input":{"command":"git push fork :refs/heads/foo"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate passes pure-delete push via empty source refspec"
  teardown_repo
}

test_gate_passes_pure_delete_via_short_branch_name() {
  # `:foo` (no refs/heads/ prefix) is also a delete refspec.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDel2","cwd":"%s","tool_input":{"command":"git push fork :foo"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate passes pure-delete push via short :name refspec"
  teardown_repo
}

test_gate_passes_pure_delete_default_remote() {
  # `git push :foo` against the default-configured remote is still a delete.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDel3","cwd":"%s","tool_input":{"command":"git push :refs/heads/foo"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate passes pure-delete push to default remote"
  teardown_repo
}

test_gate_passes_pure_delete_with_multiple_refspecs() {
  setup_repo
  gate_input=$(printf '{"session_id":"sessDel4","cwd":"%s","tool_input":{"command":"git push fork :refs/heads/foo :refs/heads/bar"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate passes pure-delete push with multiple delete refspecs"
  teardown_repo
}

test_gate_blocks_mixed_push_and_delete() {
  # `git push fork foo :refs/heads/bar` pushes `foo` and deletes `bar`. The
  # push half is unreviewed, so the gate still fires.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDel5","cwd":"%s","tool_input":{"command":"git push fork foo :refs/heads/bar"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks mixed push+delete (push half is unreviewed)"
  teardown_repo
}

test_gate_blocks_push_with_dynamic_refspec() {
  # A dynamic refspec (`for x in y; do git push fork $x; done`) could expand
  # to either a delete or a regular push. Fail closed -- gate it.
  setup_repo
  cmd='for x in y; do git push fork $x; done'
  gate_input=$(printf '{"session_id":"sessDelDynRef","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks push with dynamic refspec (could expand to non-delete)"
  teardown_repo
}

# Cases below pin codex-caught false-allow shapes the simple positional rule
# must NOT permit.

test_gate_blocks_delete_flag_when_consumed_by_push_option() {
  # `git push -o --delete origin main` makes `-o` (push-option) consume
  # `--delete` as its value. Real command is `git push origin main`. The
  # rule must not allow this -- modelling option grammar is the trap codex
  # caught. We gate on the presence of any option after `push`.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDelFalseAllow1","cwd":"%s","tool_input":{"command":"git push -o --delete origin main"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks '-o --delete' (push-option consumes --delete as value)"
  teardown_repo
}

test_gate_blocks_tags_with_delete_refspec() {
  # `git push --tags origin :old` pushes all tags AND deletes old. The
  # positional refspec is :old but --tags adds refs, so this is not a pure
  # delete. Any option after `push` -> gate.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDelFalseAllow2","cwd":"%s","tool_input":{"command":"git push --tags origin :refs/heads/old"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks --tags with :delete refspec (--tags adds refs)"
  teardown_repo
}

test_gate_blocks_dynamic_first_positional() {
  # `git push $remote :old` -- if $remote expands to `origin main`, runtime
  # is `git push origin main :old`, which pushes main. Dynamic words gate.
  setup_repo
  cmd='for x in y; do git push $remote :refs/heads/old; done'
  gate_input=$(printf '{"session_id":"sessDelFalseAllow3","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks dynamic first positional (could expand to push+remote)"
  teardown_repo
}

test_gate_blocks_bare_colon_refspec() {
  # `git push origin :` is git matching-branches push (sends commits to
  # any local branch that matches a remote branch by name), NOT a deletion.
  # The startswith(":") check must reject the bare-colon form explicitly.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDelBareColon","cwd":"%s","tool_input":{"command":"git push origin :"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks bare \`:\` refspec (matching-branches push, not delete)"
  teardown_repo
}

test_gate_blocks_brace_expanded_refspec() {
  # `git push origin :{,foo}` brace-expands to `git push origin : :foo`:
  # the bare `:` half is git matching-branches push (sends commits), the
  # `:foo` half deletes foo. bashlex leaves `:{,foo}` as one literal word,
  # so without an explicit metacharacter check the rule would false-allow.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDelBrace","cwd":"%s","tool_input":{"command":"git push origin :{,foo}"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks brace-expanded refspec (bash expands to bare-colon push)"
  teardown_repo
}

test_gate_blocks_glob_refspec() {
  # `:*` would glob-expand against the cwd. Refnames cannot contain `*`,
  # so any literal `*` in a refspec is shell metacharacter.
  setup_repo
  gate_input=$(printf '{"session_id":"sessDelGlob","cwd":"%s","tool_input":{"command":"git push origin :*"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks glob in refspec (runtime expansion unknown)"
  teardown_repo
}

test_gate_blocks_push_with_delete_flag_after_simplification() {
  # Documents the trade-off: the simpler positional-only rule gates the
  # `--delete` flag form. Recovery is a normal codex-review-capture run.
  # This test pins that behavior so a future "let me support --delete"
  # change has to address the valued-option consumption hazard codex caught
  # (e.g. `-o --delete origin main`).
  setup_repo
  gate_input=$(printf '{"session_id":"sessDelFlagGated","cwd":"%s","tool_input":{"command":"git push fork --delete foo"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks --delete flag form (any option after push gates)"
  teardown_repo
}

test_gate_uv_runs_bashlex_isolated_from_broken_project_pyproject() {
  # When the hook fires in a project whose pyproject.toml can't be resolved by uv
  # (platform-conditional deps not on PyPI, broken constraints, etc.), the
  # bashlex parser path must still run — it doesn't need any project deps, just
  # `bashlex` via --with. Without project isolation (`--no-project`), uv tries
  # to resolve the surrounding pyproject and exits nonzero. The gate then falls
  # through to the sentinel check, over-gating benign commands.
  setup_repo
  cat > pyproject.toml <<'PYEOF'
[project]
name = "broken"
version = "0.0.0"
dependencies = ["this-package-does-not-exist-on-pypi-codexgate-test"]
PYEOF
  gate_input=$(printf '{"session_id":"sessUvIso","cwd":"%s","tool_input":{"command":"echo hello"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate uv-runs bashlex isolated from broken surrounding pyproject"
  teardown_repo
}

test_wrapper_writes_hash_keyed_reviewed_sentinel() {
  # After a successful codex review, the wrapper must promote the staged file
  # to /tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${HASH} with BASE as the
  # one-line content. Replaces the old session_id-keyed promotion -- the gate
  # now scans this filename pattern instead of looking up a session-specific
  # path.
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  expected_base=$(git rev-parse HEAD)
  expected_hash=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  "$DOTFILES/bin/codex-review-capture" --uncommitted >/dev/null 2>&1
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${expected_hash}"
  assert_file_exists "$reviewed"
  if [[ -f "$reviewed" ]]; then
    assert_eq "$(cat "$reviewed")" "$expected_base" "reviewed sentinel content = BASE"
  fi
  # And the intermediate staged file must be gone -- promotion is a move.
  shopt -s nullglob
  leaked=( /tmp/codex-gate-staged-${UID}-${REPO_NAME}-* )
  shopt -u nullglob
  assert_eq "${#leaked[@]}" "0" "no staged file left after promotion"
  rm -f "$reviewed"
  teardown_repo
}

test_wrapper_refuses_to_write_sentinel_for_empty_diff() {
  # Pre-existing safety hole exposed during the hash-keyed redesign: a clean
  # working tree + --uncommitted produces sha256("") as the review hash. The
  # gate, computing the same hash later against another clean tree, would
  # match and open the gate -- unblocking the push of any unpushed commits
  # the codex never saw. Fail closed: refuse to write a sentinel for an
  # empty diff.
  setup_repo
  echo "clean" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "clean"
  # Working tree is now clean -- `git diff HEAD` is empty.
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null) || true
  empty_hash="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  assert_no_file "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${empty_hash}"
  shopt -s nullglob
  leaked_staged=( /tmp/codex-gate-staged-${UID}-${REPO_NAME}-* )
  shopt -u nullglob
  assert_eq "${#leaked_staged[@]}" "0" "no staged file for empty diff"
  if echo "$stderr" | grep -q 'empty'; then
    printf '  ok stderr mentions the empty-diff reason\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not explain empty diff\n    stderr:\n%s\n' "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_refuses_empty_diff_for_commit_mode() {
  # `--commit X` on an --allow-empty commit produces a zero-byte diff that
  # hashes to sha256(""). Same false-allow risk as --uncommitted on a clean
  # tree: refuse the sentinel.
  setup_repo
  echo "x" > x.txt
  git add x.txt && git -c user.email=t@t -c user.name=t commit -q -m "x"
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "empty"
  empty_commit=$(git rev-parse HEAD)
  empty_hash="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  stderr=$("$DOTFILES/bin/codex-review-capture" --commit "$empty_commit" 2>&1 >/dev/null) || true
  assert_no_file "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${empty_hash}"
  if echo "$stderr" | grep -q 'empty'; then
    printf '  ok stderr mentions empty diff for --commit on --allow-empty commit\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not explain empty diff for --commit\n    stderr:\n%s\n' "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_refuses_empty_diff_for_base_when_merge_base_equals_HEAD() {
  # `--base HEAD` produces merge-base(HEAD, HEAD) = HEAD, so `git diff HEAD
  # HEAD` is empty. Same false-allow risk; refuse the sentinel.
  setup_repo
  echo "main" > main.txt
  git add main.txt && git -c user.email=t@t -c user.name=t commit -q -m "main"
  empty_hash="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  stderr=$("$DOTFILES/bin/codex-review-capture" --base HEAD 2>&1 >/dev/null) || true
  assert_no_file "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${empty_hash}"
  if echo "$stderr" | grep -q 'empty'; then
    printf '  ok stderr mentions empty diff for --base HEAD (merge-base == HEAD)\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not explain empty diff for --base HEAD\n    stderr:\n%s\n' "$stderr"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_wrapper_revalidates_cached_base_against_current_tree() {
  # Cache filename is keyed on diff hash alone, but two different (BASE,
  # current_tree) pairs can produce the same diff content (e.g., adding the
  # same new file on different branches with different committed trees).
  # Without re-validation the wrapper would short-circuit on a sentinel whose
  # BASE doesn't describe the current tree, and the gate would later block
  # since `git diff cached_base` against the current tree no longer matches
  # the cached filename hash. Test: fabricate exactly that mismatch and
  # confirm the wrapper falls through to codex AND drops the stale cache.
  setup_repo
  echo "base content" > a.txt
  git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m "base"
  fake_base=$(git rev-parse HEAD)
  echo "more content" >> a.txt
  git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m "more"
  # Current state has more in HEAD than fake_base; staging foo.txt now
  # gives us a current-tree diff (vs HEAD) whose hash is X, and a
  # current-tree diff vs fake_base whose hash is Y != X.
  echo "foo content" > foo.txt
  git add foo.txt
  hash_vs_head=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  hash_vs_fake=$(git diff "$fake_base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  if [[ "$hash_vs_head" == "$hash_vs_fake" ]]; then
    printf '  FAIL test setup: failed to construct a stale-cache scenario\n'
    FAILED=$((FAILED+1))
    teardown_repo
    return
  fi
  # Plant a cache file whose name matches our --uncommitted hash, but whose
  # stored BASE produces a different hash against the current tree.
  cache="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash_vs_head}"
  printf '%s\n' "$fake_base" > "$cache"
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  rc=$?
  assert_eq "$rc" "0" "wrapper runs codex (rc=0 from fake) instead of short-circuiting on stale cache"
  if grep -q "already reviewed" <<<"$stderr"; then
    printf '  FAIL wrapper short-circuited on stale-content cache\n'
    FAILED=$((FAILED+1))
  else
    printf '  ok wrapper bypassed stale cache and ran codex\n'
    PASSED=$((PASSED+1))
  fi
  # After re-review, the cache should have been updated by the real wrapper
  # promotion to a sentinel whose BASE produces the matching hash.
  if [[ -f "$cache" ]]; then
    final_base=$(cat "$cache")
    final_check=$(git diff "$final_base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
    assert_eq "$final_check" "$hash_vs_head" "fresh cache base produces matching hash against current tree"
  fi
  rm -f "$cache"
  teardown_repo
}

test_wrapper_short_circuits_when_already_reviewed() {
  # If a reviewed sentinel for this exact diff hash already exists (and the
  # BASE is still reachable), the wrapper skips codex entirely. Saves an
  # expensive review for an answer that's already on file.
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  base=$(git rev-parse HEAD)
  echo "modified" > foo.txt
  hash=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash}"
  printf '%s\n' "$base" > "$reviewed"
  # FAKE_CODEX_RC=99 -- if codex were called the wrapper would exit nonzero.
  # The short-circuit should keep us at exit 0 without invoking codex.
  stderr=$(FAKE_CODEX_RC=99 "$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  rc=$?
  assert_eq "$rc" "0" "wrapper exits 0 on cache hit (codex not invoked)"
  if grep -q "already reviewed" <<<"$stderr"; then
    printf '  ok wrapper reports already-reviewed status\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL no already-reviewed stderr message\n    stderr:\n%s\n' "$stderr"
    FAILED=$((FAILED+1))
  fi
  assert_file_exists "$reviewed"
  rm -f "$reviewed"
  teardown_repo
}

test_wrapper_does_not_short_circuit_when_cache_base_unreachable() {
  # A cached sentinel pointing at a base that's been rebased/reset away is
  # unverifiable -- the gate would skip it too. Don't short-circuit in that
  # case; run codex afresh.
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  hash=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash}"
  printf 'deadbeefcafebabe1234567890abcdef12345678\n' > "$reviewed"  # nonexistent base
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  rc=$?
  assert_eq "$rc" "0" "wrapper runs codex (rc=0 from fake) when cached base is unreachable"
  if grep -q "already reviewed" <<<"$stderr"; then
    printf '  FAIL wrapper short-circuited on stale-base cache hit\n'
    FAILED=$((FAILED+1))
  else
    printf '  ok wrapper bypassed stale-base cache and ran codex\n'
    PASSED=$((PASSED+1))
  fi
  rm -f "$reviewed"
  teardown_repo
}

test_gate_allows_when_hash_keyed_sentinel_matches() {
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  base=$(git rev-parse HEAD)
  echo "modified" > foo.txt
  hash=$(git diff "$base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash}"
  printf '%s\n' "$base" > "$reviewed"
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate allows push when hash-keyed sentinel matches current diff"
  # Sentinel is NOT consumed on match: a single review covers the full ship
  # sequence (git push + gh pr create). The sentinel becomes invalid the
  # moment the diff changes, since the new hash won't match its filename.
  assert_file_exists "$reviewed"
  rm -f "$reviewed"
  teardown_repo
}

test_gate_allows_repeated_calls_until_diff_changes() {
  # The real ship workflow: codex-review-capture, then `git push`, then
  # `gh pr create`. Both gated calls must pass on one review.
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  base=$(git rev-parse HEAD)
  echo "modified" > foo.txt
  hash=$(git diff "$base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash}"
  printf '%s\n' "$base" > "$reviewed"

  push_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  echo "$push_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc1=$?
  assert_eq "$rc1" "0" "first gated call (git push) passes on the review"
  assert_file_exists "$reviewed"

  pr_input=$(printf '{"cwd":"%s","tool_input":{"command":"gh pr create --title foo"}}' "$REPO")
  echo "$pr_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc2=$?
  assert_eq "$rc2" "0" "second gated call (gh pr create) also passes on the same review"
  assert_file_exists "$reviewed"

  # Now mutate the tree -- sentinel becomes invalid.
  echo "further modified" > foo.txt
  set +e
  echo "$push_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc3=$?
  set -e
  assert_eq "$rc3" "2" "gate blocks once the diff drifts past the reviewed hash"

  rm -f "$reviewed"
  teardown_repo
}

test_gate_blocks_when_no_reviewed_sentinel_exists() {
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  set +e
  out=$(echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks push when no reviewed sentinel exists"
  if echo "$out" | grep -q 'No codex review found'; then
    printf '  ok stderr reports "no review found"\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not say "no review found"; got: %s\n' "$out"
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}

test_gate_blocks_when_hash_differs_from_current_tree() {
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  base=$(git rev-parse HEAD)
  echo "originally modified" > foo.txt
  hash=$(git diff "$base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash}"
  printf '%s\n' "$base" > "$reviewed"
  # Now further-modify the tree so the diff hash changes.
  echo "further modified" > foo.txt
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  set +e
  out=$(echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks when tree diverged from reviewed hash"
  if echo "$out" | grep -q 'changed'; then
    printf '  ok stderr explains the diff drifted\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not mention the diff changing; got: %s\n' "$out"
    FAILED=$((FAILED+1))
  fi
  assert_file_exists "$reviewed"  # un-consumed on block
  rm -f "$reviewed"
  teardown_repo
}

test_gate_handles_multiple_reviewed_sentinels() {
  # Two reviews on file at different bases (initial commit vs main). Both
  # describe valid views of the current diff. Gate finds one and allows.
  setup_repo
  init_commit=$(git rev-parse HEAD)
  echo "main_change" > m.txt
  git add m.txt && git -c user.email=t@t -c user.name=t commit -q -m "main"
  git checkout -q -b feature
  echo "feat" > f.txt
  git add f.txt && git -c user.email=t@t -c user.name=t commit -q -m "feat"
  base1=$(git rev-parse main)        # merge-base view: diff just the feat commit
  base2="$init_commit"                # full-history view: main + feat
  hash1=$(git diff "$base1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  hash2=$(git diff "$base2" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  # Sanity: confirm we picked two genuinely different diffs.
  if [[ "$hash1" == "$hash2" ]]; then
    printf '  FAIL test setup: chose two bases producing the same hash\n'
    FAILED=$((FAILED+1))
    teardown_repo
    return
  fi
  r1="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash1}"
  r2="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${hash2}"
  printf '%s\n' "$base1" > "$r1"
  printf '%s\n' "$base2" > "$r2"
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin feature"}}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate allows when at least one of multiple sentinels matches"
  # Sentinels survive (no consume-on-match).
  assert_file_exists "$r1"
  assert_file_exists "$r2"
  rm -f "$r1" "$r2"
  teardown_repo
}

test_gate_skips_sentinel_with_unreachable_base() {
  # A sentinel whose BASE has been rebased/reset away can't be hash-validated.
  # The gate must skip it (not blow up) and report "no codex review found" if
  # no other valid sentinel exists. Also: the file should NOT be deleted by
  # the gate; that would clobber a sentinel a different worktree might still
  # validate.
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  fake_hash="0000000000000000000000000000000000000000000000000000000000000000"
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${fake_hash}"
  printf 'deadbeefcafebabe1234567890abcdef12345678\n' > "$reviewed"
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks (no valid sentinel) when only stale-base file present"
  assert_file_exists "$reviewed"
  rm -f "$reviewed"
  teardown_repo
}

test_gate_skips_empty_sentinel_file() {
  # An empty file (no BASE line) is meaningless. Skip it like any other
  # unverifiable sentinel.
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  fake_hash="1111111111111111111111111111111111111111111111111111111111111111"
  reviewed="/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${fake_hash}"
  : > "$reviewed"  # empty file
  gate_input=$(printf '{"cwd":"%s","tool_input":{"command":"git push origin main"}}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks on empty sentinel file"
  rm -f "$reviewed"
  teardown_repo
}

test_pass_hook_is_noop() {
  # Wrapper now promotes its own sentinel directly. PostToolUse hook is kept
  # only so legacy settings entries don't break; it must do nothing.
  setup_repo
  staged="/tmp/codex-gate-staged-${UID}-${REPO_NAME}-99999"
  printf 'somebase\n' > "$staged"
  input=$(printf '{"session_id":"x","cwd":"%s","tool_response":{"stderr":"codex-review-capture: staged=%s"}}' "$REPO" "$staged")
  echo "$input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  rc=$?
  assert_eq "$rc" "0" "pass hook exits 0"
  # Hook must not have moved the staged file
  assert_file_exists "$staged"
  # Hook must not have created any session-keyed or reviewed-keyed sentinel
  assert_no_file "/tmp/codex-gate-x-${REPO_NAME}"
  shopt -s nullglob
  reviewed_leaked=( /tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-* )
  shopt -u nullglob
  assert_eq "${#reviewed_leaked[@]}" "0" "pass hook did not create any reviewed sentinel"
  rm -f "$staged"
  teardown_repo
}

for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
