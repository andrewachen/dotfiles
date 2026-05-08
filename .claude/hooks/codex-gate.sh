#!/usr/bin/env bash
# ABOUTME: PreToolUse hook that blocks the gated tool call unless a codex
# ABOUTME: review sentinel exists with a matching diff hash. Filtering to
# ABOUTME: specific commands (e.g. `git push`, `gh pr create`) is the caller's
# ABOUTME: job via the hook's `if` field -- see settings.local.example.json.

set -euo pipefail

# Extract a top-level string field from JSON on stdin, with a default. Prefers
# jq; falls back to python3 if jq is not installed.
if command -v jq >/dev/null 2>&1; then
  _json_get() { jq -r --arg k "$1" --arg d "${2:-}" '.[$k] // $d'; }
elif command -v python3 >/dev/null 2>&1; then
  _json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], sys.argv[2]))' "$1" "${2:-}"; }
else
  echo "codex-gate: requires jq or python3 to parse hook input" >&2
  exit 1
fi

# sha256sum is GNU-only; macOS ships shasum -a 256 instead.
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256 | cut -d' ' -f1; }
else
  echo "codex-gate: requires sha256sum or shasum" >&2
  exit 1
fi

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | _json_get session_id nosession)
CWD=$(echo "$INPUT" | _json_get cwd)

cd "$CWD"

# Allow through if not in a git repo (hooks are repo-scoped, but be safe)
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  exit 0
fi

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
SENTINEL="/tmp/codex-gate-${SESSION_ID}-${REPO_NAME}"

if [[ ! -f "$SENTINEL" ]]; then
  echo "BLOCKED: No codex review found for this session." >&2
  echo "Run: codex-review-capture --base <branch>  (or --commit HEAD, --uncommitted)" >&2
  echo "Then retry the push." >&2
  exit 2
fi

# Sentinel format: line 1 = HEAD_AT_REVIEW, line 2 = DIFF_HASH.
# DIFF_HASH was computed at review time as sha256(git diff HEAD).
# We recompute the diff from HEAD_AT_REVIEW to the current working tree: this
# covers both commits made since the review and any remaining uncommitted
# changes. If the net diff matches what was reviewed, allow the push.
{ read -r HEAD_AT_REVIEW; read -r STORED_HASH; } < "$SENTINEL"

if [[ -z "$HEAD_AT_REVIEW" || -z "$STORED_HASH" ]]; then
  echo "BLOCKED: Codex review sentinel is malformed." >&2
  echo "Run codex-review-capture again, then retry." >&2
  exit 2
fi

if ! git rev-parse --verify "$HEAD_AT_REVIEW^{commit}" >/dev/null 2>&1; then
  echo "BLOCKED: The commit reviewed by codex ($HEAD_AT_REVIEW) is no longer" >&2
  echo "reachable (rebased, reset, or branch deleted). Run codex-review-capture" >&2
  echo "again against the current branch, then retry." >&2
  exit 2
fi

CURRENT_DIFF_HASH=$(git diff "$HEAD_AT_REVIEW" 2>/dev/null | _sha256)

if [[ "$CURRENT_DIFF_HASH" != "$STORED_HASH" ]]; then
  echo "BLOCKED: Code changed since last codex review." >&2
  echo "The diff from the reviewed base ($HEAD_AT_REVIEW) to the current tree" >&2
  echo "no longer matches what codex saw. Either you added work beyond what was" >&2
  echo "reviewed, or you modified the reviewed changes. Run codex-review-capture" >&2
  echo "again, then retry." >&2
  exit 2
fi

# Consume the sentinel so the next push requires a fresh review
rm -f "$SENTINEL"
exit 0
