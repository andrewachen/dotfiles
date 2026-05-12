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
  rm -f "/tmp/codex-gate-"*"-${REPO_NAME}" 2>/dev/null
  [[ -n "${HARNESS_BIN:-}" ]] && rm -rf "$HARNESS_BIN"
  [[ -n "${CODEX_HOME:-}" ]] && rm -rf "$CODEX_HOME"
  unset CODEX_HOME FAKE_CODEX_TOKENS FAKE_CODEX_MODEL FAKE_CODEX_TURN1_TOTAL
}

# Tests appended below

test_wrapper_uncommitted_writes_staged() {
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  assert_file_exists "$staged"
  if [[ -f "$staged" ]]; then
    base=$(sed -n 1p "$staged")
    hash=$(sed -n 2p "$staged")
    expected_base=$(git rev-parse HEAD)
    expected_hash=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
    assert_eq "$base" "$expected_base" "uncommitted base = HEAD"
    assert_eq "$hash" "$expected_hash" "uncommitted hash = sha256(git diff HEAD)"
  fi
  teardown_repo
}

test_wrapper_commit_mode_hashes_commit_diff() {
  setup_repo
  echo "first" > a.txt
  git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m "add a"
  COMMIT=$(git rev-parse HEAD)
  echo "uncommitted_dirty" > b.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --commit "$COMMIT" 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  assert_file_exists "$staged"
  if [[ -f "$staged" ]]; then
    base=$(sed -n 1p "$staged")
    hash=$(sed -n 2p "$staged")
    expected_base=$(git rev-parse "$COMMIT^")
    expected_hash=$(git diff "$COMMIT^" "$COMMIT" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
    assert_eq "$base" "$expected_base" "commit base = parent"
    assert_eq "$hash" "$expected_hash" "commit hash ignores dirty tree"
  fi
  teardown_repo
}

test_wrapper_base_mode_uses_merge_base() {
  setup_repo
  echo "main_change" > m.txt
  git add m.txt && git -c user.email=t@t -c user.name=t commit -q -m "main"
  git checkout -q -b feature
  echo "feat_change" > f.txt
  git add f.txt && git -c user.email=t@t -c user.name=t commit -q -m "feat"
  stderr=$("$DOTFILES/bin/codex-review-capture" --base main 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  assert_file_exists "$staged"
  if [[ -f "$staged" ]]; then
    base=$(sed -n 1p "$staged")
    expected_base=$(git merge-base main HEAD)
    assert_eq "$base" "$expected_base" "base mode uses merge-base(main, HEAD)"
  fi
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
  stderr=$("$DOTFILES/bin/codex-review-capture" "--commit=$COMMIT" 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  assert_file_exists "$staged"
  if [[ -f "$staged" ]]; then
    base=$(sed -n 1p "$staged")
    expected_base=$(git rev-parse "$COMMIT^")
    assert_eq "$base" "$expected_base" "equals-form --commit= parsed correctly"
  fi
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
  stderr=$("$DOTFILES/bin/codex-review-capture" "--base=main" 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  assert_file_exists "$staged"
  if [[ -f "$staged" ]]; then
    base=$(sed -n 1p "$staged")
    expected_base=$(git merge-base main HEAD)
    assert_eq "$base" "$expected_base" "equals-form --base= uses merge-base"
  fi
  teardown_repo
}

test_pass_hook_promotes_staged_to_sentinel() {
  setup_repo
  staged="/tmp/codex-gate-staged-${UID}-${REPO_NAME}-99999"
  printf 'abcdef\n123hash\n' > "$staged"
  input=$(printf '{"session_id":"sess1","cwd":"%s","tool_response":{"stderr":"codex-review-capture: staged=%s\\n"}}' "$REPO" "$staged")
  echo "$input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  sentinel="/tmp/codex-gate-sess1-${REPO_NAME}"
  assert_file_exists "$sentinel"
  assert_no_file "$staged"
  if [[ -f "$sentinel" ]]; then
    assert_eq "$(sed -n 1p "$sentinel")" "abcdef" "promoted base preserved"
    assert_eq "$(sed -n 2p "$sentinel")" "123hash" "promoted hash preserved"
  fi
  rm -f "$sentinel"
  teardown_repo
}

test_pass_hook_noops_without_staged_line() {
  setup_repo
  input=$(printf '{"session_id":"sess2","cwd":"%s","tool_response":{"stderr":"unrelated output"}}' "$REPO")
  echo "$input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  assert_no_file "/tmp/codex-gate-sess2-${REPO_NAME}"
  teardown_repo
}

test_pass_hook_exits_zero_when_no_staged_marker() {
  setup_repo
  input=$(printf '{"session_id":"sess3","cwd":"%s","tool_response":{"stderr":"bare codex output without marker"}}' "$REPO")
  set +e
  echo "$input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  rc=$?
  set -e
  assert_eq "$rc" "0" "pass-hook exits 0 when stderr has no staged= marker"
  assert_no_file "/tmp/codex-gate-sess3-${REPO_NAME}"
  teardown_repo
}

test_e2e_uncommitted_review_then_push_passes() {
  setup_repo
  echo "feature" > feat.txt
  git add feat.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline before feature"
  echo "modified feature" > feat.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  pass_input=$(printf '{"session_id":"e2e1","cwd":"%s","tool_response":{"stderr":"%s"}}' "$REPO" "codex-review-capture: staged=$staged")
  echo "$pass_input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  gate_input=$(printf '{"session_id":"e2e1","cwd":"%s"}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate accepts after fresh uncommitted review"
  assert_no_file "/tmp/codex-gate-e2e1-${REPO_NAME}"
  teardown_repo
}

test_e2e_uncommitted_review_then_extra_edit_blocks() {
  setup_repo
  echo "feature" > feat.txt
  git add feat.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified feature" > feat.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  pass_input=$(printf '{"session_id":"e2e2","cwd":"%s","tool_response":{"stderr":"%s"}}' "$REPO" "codex-review-capture: staged=$staged")
  echo "$pass_input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  echo "extra modification" > feat.txt
  gate_input=$(printf '{"session_id":"e2e2","cwd":"%s"}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks (exit 2) when tree diverges from review"
  rm -f "/tmp/codex-gate-e2e2-${REPO_NAME}"
  teardown_repo
}

test_e2e_commit_review_with_dirty_tree_blocks_unreviewed_commit() {
  setup_repo
  echo "reviewed_change" > r.txt
  git add r.txt && git -c user.email=t@t -c user.name=t commit -q -m "reviewed"
  COMMIT=$(git rev-parse HEAD)
  echo "unreviewed_dirty" > u.txt
  git add u.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --commit "$COMMIT" 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  pass_input=$(printf '{"session_id":"e2e3","cwd":"%s","tool_response":{"stderr":"%s"}}' "$REPO" "codex-review-capture: staged=$staged")
  echo "$pass_input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  git -c user.email=t@t -c user.name=t commit -q -m "unreviewed"
  gate_input=$(printf '{"session_id":"e2e3","cwd":"%s"}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "P1 #2: gate blocks when committing unreviewed dirty edits after --commit review"
  rm -f "/tmp/codex-gate-e2e3-${REPO_NAME}"
  teardown_repo
}

test_gate_blocks_on_malformed_sentinel() {
  setup_repo
  echo "feature" > feat.txt
  git add feat.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  # Write a sentinel with only one line (missing the hash)
  printf 'truncated\n' > "/tmp/codex-gate-malformedsess-${REPO_NAME}"
  gate_input=$(printf '{"session_id":"malformedsess","cwd":"%s"}' "$REPO")
  set +e
  out=$(echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate exits 2 on malformed sentinel"
  if echo "$out" | grep -q 'BLOCKED'; then
    printf '  ok stderr says BLOCKED\n'
    PASSED=$((PASSED+1))
  else
    printf '  FAIL stderr does not say BLOCKED, got: %s\n' "$out"
    FAILED=$((FAILED+1))
  fi
  rm -f "/tmp/codex-gate-malformedsess-${REPO_NAME}"
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

test_wrapper_promotes_sentinel_when_claude_session_set() {
  # When invoked under Claude Code, the wrapper must write the session sentinel
  # itself: the PostToolUse hook can't see our stderr for background bash tasks
  # (the bash tool returns immediately with a shell id) so promotion-via-hook
  # would never fire and the next gated push would block.
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  CLAUDE_CODE_SESSION_ID="sessbg1" "$DOTFILES/bin/codex-review-capture" --uncommitted >/dev/null 2>&1
  sentinel="/tmp/codex-gate-sessbg1-${REPO_NAME}"
  assert_file_exists "$sentinel"
  if [[ -f "$sentinel" ]]; then
    base=$(sed -n 1p "$sentinel")
    hash=$(sed -n 2p "$sentinel")
    expected_base=$(git rev-parse HEAD)
    expected_hash=$(git diff HEAD | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
    assert_eq "$base" "$expected_base" "promoted sentinel base = HEAD"
    assert_eq "$hash" "$expected_hash" "promoted sentinel hash = sha256(git diff HEAD)"
  fi
  # And the intermediate staged file must be gone — promotion is a move.
  shopt -s nullglob
  leaked=( /tmp/codex-gate-staged-${UID}-${REPO_NAME}-* )
  shopt -u nullglob
  assert_eq "${#leaked[@]}" "0" "no staged file left after promotion"
  rm -f "$sentinel"
  teardown_repo
}

test_wrapper_no_sentinel_when_session_set_but_codex_fails() {
  setup_repo
  echo "x" > x.txt
  git add x.txt
  CLAUDE_CODE_SESSION_ID="sessbg2" FAKE_CODEX_RC=42 \
    "$DOTFILES/bin/codex-review-capture" --uncommitted >/dev/null 2>&1 || true
  assert_no_file "/tmp/codex-gate-sessbg2-${REPO_NAME}"
  shopt -s nullglob
  leaked=( /tmp/codex-gate-staged-${UID}-${REPO_NAME}-* )
  shopt -u nullglob
  assert_eq "${#leaked[@]}" "0" "staged file also cleaned up on codex failure"
  teardown_repo
}

test_e2e_background_invocation_unblocks_gate_without_hook() {
  # Simulates the bug scenario: Bash(codex-review-capture ..., run_in_background:
  # true) returns immediately, PostToolUse fires with empty stderr and no-ops.
  # The wrapper itself must promote the sentinel so the next gated push passes.
  setup_repo
  echo "feature" > feat.txt
  git add feat.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified feature" > feat.txt
  CLAUDE_CODE_SESSION_ID="bgsess" "$DOTFILES/bin/codex-review-capture" --uncommitted >/dev/null 2>&1
  # Deliberately do NOT invoke codex-gate-pass.sh -- in the real bug it sees no
  # staged= line and exits 0 with nothing done.
  gate_input=$(printf '{"session_id":"bgsess","cwd":"%s"}' "$REPO")
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh"
  rc=$?
  assert_eq "$rc" "0" "gate accepts after background-style wrapper promotion"
  assert_no_file "/tmp/codex-gate-bgsess-${REPO_NAME}"
  teardown_repo
}

test_wrapper_no_sentinel_when_session_unset() {
  # Legacy / terminal-invocation behavior: no promotion happens in the wrapper;
  # the staged file is left for the PostToolUse hook to handle (or to expire).
  setup_repo
  echo "baseline" > foo.txt
  git add foo.txt && git -c user.email=t@t -c user.name=t commit -q -m "baseline"
  echo "modified" > foo.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  assert_file_exists "$staged"
  # No sentinel for any session id we might have used in the wrapper.
  shopt -s nullglob
  leaked=( /tmp/codex-gate-*-${REPO_NAME} )
  shopt -u nullglob
  assert_eq "${#leaked[@]}" "0" "no sentinel written when CLAUDE_CODE_SESSION_ID unset"
  teardown_repo
}

for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
