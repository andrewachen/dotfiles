# Codex Gate Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the diff-mode mismatch hole in the codex pre-push gate by having `codex-review-capture` itself capture exactly what codex reviewed, while preserving session-keyed sentinels so multiple Claude sessions in the same repo don't interfere.

**Architecture:** The wrapper detects the codex review mode (`--commit X` / `--base B` / `--uncommitted`) and computes `(BASE, DIFF_HASH)` for the diff codex actually reviews — *before* invoking codex, eliminating the working-tree race during a long review. It writes that pair to a PID-suffixed staged file and prints the path to stderr. The PostToolUse hook (`codex-gate-pass.sh`) parses the wrapper's stderr from the tool response, locates the exact staged file for *this* invocation, and atomically renames it to a session-keyed sentinel. The PreToolUse hook (`codex-gate.sh`) is unchanged in logic.

**Tech Stack:** Bash, jq (with python3 fallback), sha256sum (with shasum -a 256 fallback), Claude Code hooks (PreToolUse / PostToolUse with `if` filtering).

---

## File Structure

**Modified files:**

- `bin/codex-review-capture` — gains review-mode parsing, pre-codex `(BASE, HASH)` computation, atomic staged-file write, exit-code-aware cleanup. Mode parsing covers exactly the three documented codex review modes; unrecognized invocations skip sentinel-writing entirely (fail-closed).

- `.claude/hooks/codex-gate-pass.sh` — becomes a thin promote-shim. Reads `tool_response.stderr` from the hook input, extracts `staged=<path>`, mvs that exact file to the session-keyed sentinel. No diff computation, no hashing.

- `.claude/hooks/codex-gate.sh` — no functional change. Comment update only, since the sentinel's `BASE` field can now legitimately be HEAD (uncommitted), `X^` (commit), or `merge-base(B, HEAD)` (base mode); the verification math (`git diff $BASE | sha256` against current tree) is the same.

- `.claude/hooks/settings.local.example.json` — no change. Already correct: PreToolUse for `git push` / `gh pr create`, PostToolUse for `codex review` / `codex-review-capture`, all gated by `if` clauses.

- `README.md` — update the "codex pre-push gate" section to describe the new flow (wrapper does the work, hook is a shim) and document the concurrent-review caveat.

- `.claude/skills/codex-review/SKILL.md` — note that the wrapper writes a sentinel only after a successful codex review with one of the three explicit mode flags. Bare `codex-review-capture` without a mode flag won't gate.

**New files:**

- `tests/codex-gate/test.sh` — bash test harness. Spins up a temp git repo, stubs `codex` on PATH to return controlled exit codes, invokes the wrapper and hooks with synthesized JSON, asserts on staged/sentinel file contents. No external test framework — plain bash with a small assert helper.

- `tests/codex-gate/fake-codex.sh` — stub `codex` binary used by the harness. Reads `FAKE_CODEX_RC` from env (default 0), writes a stub transcript with the `^codex$` marker so the wrapper's verdict-extraction path works.

---

## Limitations Documented in the Plan

- **`codex review` with no mode flag does not write a sentinel.** Codex's default mode is undocumented in the dotfiles' codex-review skill, so we fail-closed: gate will block, user must re-run with `--uncommitted` / `--commit` / `--base`.
- **macOS `shasum -a 256` and Linux `sha256sum` produce identical hex output.** Verified by manual test in this plan's smoke-test task.
- **`--uncommitted` review with untracked files is rejected.** The wrapper fails closed in this case (refuses to write the staged file with a stderr message). The user must `git add` the untracked files first, then re-run `codex-review-capture --uncommitted`. Trade-off: cleaner soundness (no index mutation, no replay logic in the gate) at the cost of an extra `git add` step.

## Validation Gaps — Resolved

- **`tool_response.stderr` field path confirmed** via the Claude Code hooks reference (https://code.claude.com/docs/en/hooks). PostToolUse input includes a top-level `tool_response` object with `stdout` (string), `stderr` (string), and `exit_code` (number) for Bash tools.
- **Concurrent same-repo race is structurally impossible** with this design. Each PostToolUse hook invocation receives the `tool_response.stderr` of the *specific* tool call that fired it — Claude Code couples them. The wrapper's stderr carries `staged=<path>` where `<path>` includes the wrapper's own PID. Two parallel wrappers (even on the same repo from different sessions) emit different paths in different stderr streams, so each session's hook finds its own wrapper's staged file. There is no shared lookup, no glob, no mtime heuristic — exact 1:1 matching by path.

---

## Task 1: Test harness scaffolding

**Files:**
- Create: `tests/codex-gate/test.sh`
- Create: `tests/codex-gate/fake-codex.sh`

- [ ] **Step 1: Write the test harness skeleton**

```bash
# tests/codex-gate/test.sh
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
  local actual=$1
  local expected=$2
  local label=$3
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
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  REPO_NAME=$(basename "$REPO")
  export PATH="$HARNESS_DIR:$PATH"
  export FAKE_CODEX_RC=0
}

teardown_repo() {
  cd /
  rm -rf "$REPO"
  rm -f /tmp/codex-gate-staged-${UID}-${REPO_NAME}-* 2>/dev/null
  rm -f /tmp/codex-gate-*-${REPO_NAME} 2>/dev/null
}

# Tests appended below
```

- [ ] **Step 2: Write the fake codex stub**

```bash
# tests/codex-gate/fake-codex.sh
#!/usr/bin/env bash
# ABOUTME: Stub `codex` binary for the codex-gate test harness. Writes a
# ABOUTME: minimal transcript with the `^codex$` marker so the wrapper's
# ABOUTME: verdict-extraction path works, then exits with $FAKE_CODEX_RC.

if [[ "${1:-}" == "review" ]]; then
  cat <<'EOF'
some exploration log line
codex
verdict goes here
EOF
  exit "${FAKE_CODEX_RC:-0}"
fi

exit 0
```

- [ ] **Step 3: Make both scripts executable**

Run: `chmod +x tests/codex-gate/test.sh tests/codex-gate/fake-codex.sh`

The stub must be named `codex` on PATH for the wrapper to call it. The harness handles that by putting `tests/codex-gate/` on PATH and symlinking `codex -> fake-codex.sh`.

- [ ] **Step 4: Add the symlink line to the test setup**

Edit `tests/codex-gate/test.sh`'s `setup_repo()` to also create the `codex` alias:

```bash
setup_repo() {
  REPO=$(mktemp -d -t codex-gate-test.XXXXXX)
  cd "$REPO"
  git init -q
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  REPO_NAME=$(basename "$REPO")
  ln -sf "$HARNESS_DIR/fake-codex.sh" "$HARNESS_DIR/codex"
  export PATH="$HARNESS_DIR:$PATH"
  export FAKE_CODEX_RC=0
}
```

- [ ] **Step 5: Verify the harness skeleton runs**

Run: `bash tests/codex-gate/test.sh`
Expected: prints nothing (no tests defined yet), exits 0.

- [ ] **Step 6: Commit**

```bash
git add tests/codex-gate/
git commit -m "test: scaffold codex-gate test harness"
```

---

## Task 2: Failing tests for wrapper sentinel-writing

**Files:**
- Modify: `tests/codex-gate/test.sh` (append test cases)

- [ ] **Step 1: Append uncommitted-mode test**

```bash
test_wrapper_uncommitted_writes_staged() {
  setup_repo
  echo "hello" > foo.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  assert_file_exists "$staged"
  if [[ -f "$staged" ]]; then
    base=$(sed -n 1p "$staged")
    hash=$(sed -n 2p "$staged")
    expected_base=$(git rev-parse HEAD)
    expected_hash=$(git diff HEAD | sha256sum 2>/dev/null | cut -d' ' -f1 || git diff HEAD | shasum -a 256 | cut -d' ' -f1)
    assert_eq "$base" "$expected_base" "uncommitted base = HEAD"
    assert_eq "$hash" "$expected_hash" "uncommitted hash = sha256(git diff HEAD)"
  fi
  teardown_repo
}
```

- [ ] **Step 2: Append commit-mode test**

```bash
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
```

- [ ] **Step 3: Append base-mode test**

```bash
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
```

- [ ] **Step 4: Append failure-cleanup test**

```bash
test_wrapper_removes_staged_on_codex_failure() {
  setup_repo
  echo "x" > x.txt
  FAKE_CODEX_RC=42 stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null) || true
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  if [[ -n "$staged" ]]; then
    assert_no_file "$staged"
  else
    printf '  FAIL no staged path emitted\n'
    FAILED=$((FAILED+1))
  fi
  teardown_repo
}
```

- [ ] **Step 5: Append unknown-mode skip test**

```bash
test_wrapper_skips_staged_for_unknown_mode() {
  setup_repo
  stderr=$("$DOTFILES/bin/codex-review-capture" 2>&1 >/dev/null)
  staged_line=$(echo "$stderr" | grep -E 'staged=' || true)
  assert_eq "$staged_line" "" "no staged file written when no mode flag"
  teardown_repo
}
```

- [ ] **Step 6: Add the test runner block at the end of test.sh**

```bash
for t in $(declare -F | awk '/^declare -f test_/ {print $3}'); do
  printf '\n--- %s\n' "$t"
  $t
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
exit "$FAILED"
```

- [ ] **Step 7: Run tests to verify they fail (wrapper not yet rewritten)**

Run: `bash tests/codex-gate/test.sh`
Expected: all five tests FAIL — current wrapper does not emit `staged=<path>` to stderr.

- [ ] **Step 8: Commit failing tests**

```bash
git add tests/codex-gate/test.sh
git commit -m "test(codex-gate): add failing tests for wrapper staged-file behavior"
```

---

## Task 3: Implement wrapper sentinel-writing

**Files:**
- Modify: `bin/codex-review-capture`

- [ ] **Step 1: Replace the wrapper body**

Full new contents of `bin/codex-review-capture`:

```bash
#!/bin/bash
# ABOUTME: Wrapper around `codex review` that captures the full transcript to
# ABOUTME: a /tmp file (owner-only, auto-cleaned on reboot) and prints only the
# ABOUTME: verdict -- content after the last `^codex$` marker -- to stdout.
# ABOUTME: After a successful review with a recognized mode flag, also writes
# ABOUTME: a staged file that codex-gate-pass.sh promotes into a session-keyed
# ABOUTME: sentinel for codex-gate.sh.

set -uo pipefail

if command -v sha256sum >/dev/null 2>&1; then
    _sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    _sha256() { shasum -a 256 | cut -d' ' -f1; }
else
    _sha256() { return 1; }
fi

# Detect codex review mode and capture (BASE, HASH) for exactly the diff codex
# will see. We do this BEFORE running codex so a long-running review's race
# against working-tree edits doesn't change what we record.
review_mode=""
review_arg=""
argv=("$@")
# `codex review` (clap parser) accepts both `--flag value` and `--flag=value`
# forms. We handle both. Last flag wins on conflict.
for ((i=0; i<${#argv[@]}; i++)); do
    case "${argv[i]}" in
        --commit)      review_mode="commit";      review_arg="${argv[i+1]:-}" ;;
        --commit=*)    review_mode="commit";      review_arg="${argv[i]#--commit=}" ;;
        --base)        review_mode="base";        review_arg="${argv[i+1]:-}" ;;
        --base=*)      review_mode="base";        review_arg="${argv[i]#--base=}" ;;
        --uncommitted) review_mode="uncommitted"; review_arg="" ;;
    esac
done

review_base=""
review_hash=""
repo_name=""
if topdir=$(git rev-parse --show-toplevel 2>/dev/null); then
    repo_name=$(basename "$topdir")
    case "$review_mode" in
        commit)
            if [[ -n "$review_arg" ]] && review_base=$(git rev-parse "${review_arg}^" 2>/dev/null); then
                review_hash=$(git diff "${review_arg}^" "${review_arg}" 2>/dev/null | _sha256) || review_hash=""
            fi
            ;;
        base)
            if [[ -n "$review_arg" ]] && review_base=$(git merge-base "$review_arg" HEAD 2>/dev/null); then
                review_hash=$(git diff "$review_base" HEAD 2>/dev/null | _sha256) || review_hash=""
            fi
            ;;
        uncommitted)
            if review_base=$(git rev-parse HEAD 2>/dev/null); then
                # `codex review --uncommitted` covers staged, unstaged, AND
                # untracked changes. `git diff HEAD` only sees staged + unstaged,
                # so an untracked-only review would record an empty-diff hash and
                # the gate would over-block once those files are committed. Fail
                # closed: if untracked files are present, refuse to write the
                # staged file. The user must `git add` them first.
                # `git ls-files --others` is cwd-scoped without explicit paths,
                # so we use `-C "$topdir"` to scan the whole repo regardless of
                # where the wrapper was invoked.
                untracked=$(git -C "$topdir" ls-files --others --exclude-standard 2>/dev/null)
                if [[ -n "$untracked" ]]; then
                    printf 'codex-review-capture: --uncommitted review includes untracked files,\n' >&2
                    printf 'but the gate cannot verify them. Stage them with `git add` first,\n' >&2
                    printf 'then re-run codex-review-capture.\n\nUntracked:\n%s\n' "$untracked" >&2
                    review_base=""
                else
                    review_hash=$(git diff HEAD 2>/dev/null | _sha256) || review_hash=""
                fi
            fi
            ;;
    esac
fi

staged=""
if [[ -n "$review_base" && -n "$review_hash" && -n "$repo_name" ]]; then
    staged="/tmp/codex-gate-staged-${UID}-${repo_name}-$$"
    printf '%s\n%s\n' "$review_base" "$review_hash" > "$staged"
    printf 'codex-review-capture: staged=%s\n' "$staged" >&2
fi

output=$(mktemp -t codex-review.XXXXXXXX)
printf 'codex-review-capture: full transcript -> %s\n' "$output" >&2

codex review "$@" >"$output" 2>&1
rc=$?

if [[ $rc -ne 0 && -n "$staged" ]]; then
    rm -f "$staged"
fi

if grep -q '^codex$' "$output"; then
    # Keep only the block after the LAST `^codex$` marker: reset buffer on each
    # match, then print whatever remains at EOF.
    awk '/^codex$/ { buf = ""; next } { buf = buf $0 ORS } END { printf "%s", buf }' "$output"
else
    printf 'codex-review-capture: no ^codex$ marker in output; printing full transcript.\n' >&2
    cat "$output"
fi

exit "$rc"
```

- [ ] **Step 2: Run wrapper tests to verify they pass**

Run: `bash tests/codex-gate/test.sh`
Expected: all five wrapper tests PASS, summary `5 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add bin/codex-review-capture
git commit -m "feat(codex-gate): wrapper writes mode-aware staged file pre-review"
```

---

## Task 4: Failing tests for the simplified pass hook

**Files:**
- Modify: `tests/codex-gate/test.sh` (append)

- [ ] **Step 1: Append pass-hook promotion test**

```bash
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
```

- [ ] **Step 2: Append no-staged-line skip test**

```bash
test_pass_hook_noops_without_staged_line() {
  setup_repo
  input=$(printf '{"session_id":"sess2","cwd":"%s","tool_response":{"stderr":"unrelated output"}}' "$REPO")
  echo "$input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  assert_no_file "/tmp/codex-gate-sess2-${REPO_NAME}"
  teardown_repo
}
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `bash tests/codex-gate/test.sh`
Expected: existing 5 wrapper tests still pass; the 2 new pass-hook tests fail because the current pass hook doesn't read `tool_response.stderr` — it parses `tool_input.command` and computes a hash itself.

- [ ] **Step 4: Commit failing tests**

```bash
git add tests/codex-gate/test.sh
git commit -m "test(codex-gate): add failing tests for pass-hook promotion behavior"
```

---

## Task 5: Rewrite the pass hook as a promote-shim

**Files:**
- Modify: `.claude/hooks/codex-gate-pass.sh`

- [ ] **Step 1: Replace pass-hook body**

Full new contents of `.claude/hooks/codex-gate-pass.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that promotes a staged file written by
# ABOUTME: codex-review-capture into a session-keyed sentinel that codex-gate.sh
# ABOUTME: verifies. Filtering to codex-review-capture / codex review is the
# ABOUTME: caller's job via the hook's `if` field -- see settings.local.example.json.

set -euo pipefail

if command -v jq >/dev/null 2>&1; then
    _stderr_field() { jq -r '.tool_response.stderr // ""'; }
    _top_field() { jq -r --arg k "$1" --arg d "${2:-}" '.[$k] // $d'; }
elif command -v python3 >/dev/null 2>&1; then
    _stderr_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("tool_response") or {}; print(r.get("stderr",""))'; }
    _top_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], sys.argv[2]))' "$1" "${2:-}"; }
else
    echo "codex-gate-pass: requires jq or python3 to parse hook input" >&2
    exit 1
fi

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | _top_field session_id nosession)
CWD=$(echo "$INPUT" | _top_field cwd)

cd "$CWD" 2>/dev/null || exit 0
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

STDERR=$(echo "$INPUT" | _stderr_field)
STAGED=$(echo "$STDERR" | grep -oE 'staged=[^[:space:]]+' | tail -n1 | cut -d= -f2-)

[[ -z "$STAGED" ]] && exit 0
[[ ! -f "$STAGED" ]] && exit 0

mv "$STAGED" "/tmp/codex-gate-${SESSION_ID}-${REPO_NAME}"
```

- [ ] **Step 2: Run tests to verify pass-hook tests pass**

Run: `bash tests/codex-gate/test.sh`
Expected: all 7 tests pass.

- [ ] **Step 3: Commit**

```bash
git add .claude/hooks/codex-gate-pass.sh
git commit -m "refactor(codex-gate): pass hook is a shim; wrapper owns hash"
```

---

## Task 6: Verify gate hook still works end-to-end

**Files:**
- Modify: `tests/codex-gate/test.sh` (append integration test)
- Modify: `.claude/hooks/codex-gate.sh` (comment-only)

- [ ] **Step 1: Append end-to-end test for uncommitted flow**

```bash
test_e2e_uncommitted_review_then_push_passes() {
  setup_repo
  echo "feature" > feat.txt
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
```

- [ ] **Step 2: Append end-to-end test that gate blocks on tree change**

```bash
test_e2e_uncommitted_review_then_extra_edit_blocks() {
  setup_repo
  echo "feature" > feat.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --uncommitted 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  pass_input=$(printf '{"session_id":"e2e2","cwd":"%s","tool_response":{"stderr":"%s"}}' "$REPO" "codex-review-capture: staged=$staged")
  echo "$pass_input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  echo "extra" > extra.txt
  gate_input=$(printf '{"session_id":"e2e2","cwd":"%s"}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "gate blocks (exit 2) when tree diverges from review"
  rm -f "/tmp/codex-gate-e2e2-${REPO_NAME}"
  teardown_repo
}
```

- [ ] **Step 3: Append end-to-end test for the codex P1 #2 attack scenario**

```bash
test_e2e_commit_review_with_dirty_tree_blocks_unreviewed_commit() {
  setup_repo
  echo "reviewed_change" > r.txt
  git add r.txt && git -c user.email=t@t -c user.name=t commit -q -m "reviewed"
  COMMIT=$(git rev-parse HEAD)
  echo "unreviewed_dirty" > u.txt
  stderr=$("$DOTFILES/bin/codex-review-capture" --commit "$COMMIT" 2>&1 >/dev/null)
  staged=$(echo "$stderr" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2-)
  pass_input=$(printf '{"session_id":"e2e3","cwd":"%s","tool_response":{"stderr":"%s"}}' "$REPO" "codex-review-capture: staged=$staged")
  echo "$pass_input" | bash "$DOTFILES/.claude/hooks/codex-gate-pass.sh"
  git add u.txt && git -c user.email=t@t -c user.name=t commit -q -m "unreviewed"
  gate_input=$(printf '{"session_id":"e2e3","cwd":"%s"}' "$REPO")
  set +e
  echo "$gate_input" | bash "$DOTFILES/.claude/hooks/codex-gate.sh" 2>/dev/null
  rc=$?
  set -e
  assert_eq "$rc" "2" "P1 #2: gate blocks when committing unreviewed dirty edits after --commit review"
  rm -f "/tmp/codex-gate-e2e3-${REPO_NAME}"
  teardown_repo
}
```

- [ ] **Step 4: Update the comment in codex-gate.sh**

In `.claude/hooks/codex-gate.sh`, replace the existing "Sentinel format" comment (lines 36-40 of the *current* version, near the `read -r HEAD_AT_REVIEW; read -r STORED_HASH` block) with:

```bash
# Sentinel format: line 1 = BASE_SHA, line 2 = DIFF_HASH.
# BASE_SHA depends on the codex review mode the wrapper observed:
#   --commit X     -> BASE_SHA = X^,                  HASH = sha256(git diff X^ X)
#   --base B       -> BASE_SHA = merge-base(B, HEAD), HASH = sha256(git diff BASE HEAD)
#   --uncommitted  -> BASE_SHA = HEAD,                HASH = sha256(git diff HEAD)
# We recompute HASH = sha256(git diff BASE_SHA) against the current working
# tree. If the user committed exactly the reviewed changes (and nothing more),
# the diff content is byte-identical and the hash matches.
```

Also rename the local var `HEAD_AT_REVIEW` → `BASE` throughout the script for accuracy. Update all the corresponding error messages that say "the commit reviewed by codex" → "the base reviewed by codex" (already mostly accurate; verify each `echo` referencing the variable).

- [ ] **Step 5: Run tests to verify e2e tests pass**

Run: `bash tests/codex-gate/test.sh`
Expected: all 10 tests pass. Specifically, the P1 #2 attack-scenario test should now show that the gate blocks the unreviewed commit — proving the fix.

- [ ] **Step 6: Commit**

```bash
git add tests/codex-gate/test.sh .claude/hooks/codex-gate.sh
git commit -m "test(codex-gate): e2e tests cover P1 #2 fix; rename HEAD_AT_REVIEW → BASE"
```

---

## Task 7: Update README and codex-review skill

**Files:**
- Modify: `README.md` (the "Optional: codex pre-push gate" section added earlier in this branch)
- Modify: `.claude/skills/codex-review/SKILL.md`

- [ ] **Step 1: Rewrite the README gate section**

Replace the current "Optional: codex pre-push gate" section (just below the `codex-review-capture` bullet) with:

```markdown
### Optional: codex pre-push gate

`bin/codex-review-capture` and the hooks in `.claude/hooks/` together implement a per-project gate that blocks `git push` and `gh pr create` until a `codex review` has run with a recognized mode flag in the same Claude Code session, and re-blocks if the diff has changed since.

Flow:
1. The model runs `codex-review-capture --commit <sha>` (or `--base <branch>`, or `--uncommitted`). The wrapper detects the mode and computes `(BASE, HASH)` for exactly the diff codex sees, *before* invoking codex (so a long-running review can't be raced by working-tree edits). On `rc=0` the wrapper leaves a staged file at `/tmp/codex-gate-staged-${UID}-${repo}-${pid}` and prints `staged=<path>` to stderr.
2. `codex-gate-pass.sh` (PostToolUse, only fires on success) reads the staged path from `tool_response.stderr` and renames the file to a session-keyed sentinel `/tmp/codex-gate-${SESSION_ID}-${repo}`.
3. `codex-gate.sh` (PreToolUse on `git push *` / `gh pr create *`) recomputes `git diff BASE` against the current tree, compares to the stored hash, and either consumes the sentinel and allows the push or exits 2 with a message.

Caveats:
- The hooks are opt-in per project. Each project that wants the gate references the scripts from its own `.claude/settings.local.json`.
- Concurrent codex reviews on the *same* repo from two Claude sessions are not supported. The staged path is PID-suffixed, so it works in practice as long as PostToolUse fires before the next wrapper starts; otherwise the model will see "no codex review found" and re-run.
- `codex-review-capture` without a mode flag does not write a sentinel — the gate fails closed.

Install the hook scripts once:

\`\`\`bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks

for h in codex-gate.sh codex-gate-pass.sh; do
  ln -sf "$PWD/.claude/hooks/$h" "$HOME/.claude/hooks/$h"
done
\`\`\`

Activate the gate in a project by merging the contents of [`.claude/hooks/settings.local.example.json`](.claude/hooks/settings.local.example.json) into that project's `.claude/settings.local.json`. The example uses each hook entry's `if` field (permission-rule syntax) so the scripts only spawn for the gated commands — no overhead on every Bash call.
```

(The triple-backticks above are literal in the markdown — replace `\`\`\`` with three backticks in the actual file. The plan author rendered them escaped to keep this codeblock parseable.)

- [ ] **Step 2: Update the codex-review skill**

In `.claude/skills/codex-review/SKILL.md`, find the "When project hooks enforce it" section near the bottom and append:

```markdown

When the dotfiles' codex-gate hooks are wired up, the gate only opens after a `codex-review-capture` invocation that includes one of `--commit <sha>`, `--base <branch>`, or `--uncommitted`. A bare `codex review` or `codex-review-capture` (no mode flag) writes no sentinel and the next push will be blocked. Always pass an explicit mode flag in gated projects.
```

- [ ] **Step 3: Commit**

```bash
git add README.md .claude/skills/codex-review/SKILL.md
git commit -m "docs(codex-gate): describe redesigned wrapper-owned gate flow"
```

---

## Task 8: Final review and cleanup

- [ ] **Step 1: Run the full test suite once more**

Run: `bash tests/codex-gate/test.sh`
Expected: `10 passed, 0 failed`, exit 0.

- [ ] **Step 2: Manual sanity check on a real repo with the real codex CLI**

In a *different* repo (not the dotfiles), with the hooks symlinked, run:

```bash
codex-review-capture --uncommitted
```

Verify (a) the sentinel staged file appears at `/tmp/codex-gate-staged-${UID}-...` mid-review, (b) it persists after codex exits 0, (c) it's renamed to `/tmp/codex-gate-${SESSION_ID}-...` after PostToolUse fires, (d) attempting `git push` after that succeeds the gate.

If any step fails, do not proceed to commit — open a follow-up.

- [ ] **Step 3: Run codex review on the implementation diff**

Run codex-review-capture on this branch's full diff:

```bash
codex-review-capture --base main
```

Triage findings as usual.

- [ ] **Step 4: Final commit**

If the test suite is green and codex review surfaces no new P1s, no further commit required. Otherwise address findings and commit.

---

## Self-Review

**Spec coverage:**
- P1 #2 (diff-mode mismatch): covered by Task 3 (mode-aware wrapper) and Task 6 e2e test 3 (attack scenario).
- Race during long codex run: covered by Task 3 — wrapper computes `(BASE, HASH)` *before* invoking codex.
- Multi-session safety: preserved — sentinel still keyed by SESSION_ID, staged file keyed by UID+PID.
- Cross-platform: covered by Task 3 (sha256sum/shasum fallback already in current scripts).
- Failed review must not write sentinel: covered by Task 3 step 1 (rm on rc≠0) and Task 2 step 4 test.
- Unknown mode must fail closed: covered by Task 2 step 5 test.

**Placeholder scan:** none — every code step contains the actual code.

**Type consistency:** `BASE` (var name) is consistent across wrapper output, pass-hook handoff, gate-hook read. Sentinel format `line1=BASE / line2=HASH` is consistent across writer (wrapper) and reader (gate).

**Outstanding decisions resolved with Andrew before execution:**
- `tests/codex-gate/` is committed to the dotfiles repo (Task 1 step 6).
- `.claude/worktrees/` is added to `.gitignore` in Task 0 ahead of any other work.
