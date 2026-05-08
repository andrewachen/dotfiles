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
  echo "x" > x.txt
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

for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
