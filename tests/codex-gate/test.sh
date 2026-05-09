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
}

teardown_repo() {
  cd /
  rm -rf "$REPO"
  rm -f "/tmp/codex-gate-staged-${UID}-${REPO_NAME}-"* 2>/dev/null
  rm -f "/tmp/codex-gate-"*"-${REPO_NAME}" 2>/dev/null
  [[ -n "${HARNESS_BIN:-}" ]] && rm -rf "$HARNESS_BIN"
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

for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
