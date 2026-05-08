#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that writes a review sentinel after a codex review
# ABOUTME: invocation, allowing the next gated tool call through codex-gate.sh.
# ABOUTME: Filtering to codex-review-capture / codex review is the caller's job
# ABOUTME: via the hook's `if` field -- see settings.local.example.json.

set -euo pipefail

# Extract a top-level string field from JSON on stdin, with a default. Prefers
# jq; falls back to python3 if jq is not installed.
if command -v jq >/dev/null 2>&1; then
  _json_get() { jq -r --arg k "$1" --arg d "${2:-}" '.[$k] // $d'; }
elif command -v python3 >/dev/null 2>&1; then
  _json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], sys.argv[2]))' "$1" "${2:-}"; }
else
  echo "codex-gate-pass: requires jq or python3 to parse hook input" >&2
  exit 1
fi

# sha256sum is GNU-only; macOS ships shasum -a 256 instead.
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256 | cut -d' ' -f1; }
else
  echo "codex-gate-pass: requires sha256sum or shasum" >&2
  exit 1
fi

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | _json_get session_id nosession)
CWD=$(echo "$INPUT" | _json_get cwd)

cd "$CWD"

# Skip if not in a git repo
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  exit 0
fi

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
SENTINEL="/tmp/codex-gate-${SESSION_ID}-${REPO_NAME}"

# Record the HEAD at review time and the hash of `git diff HEAD` at that
# moment. At gate-check time we recompute the diff from HEAD_AT_REVIEW to the
# current working tree; if the user commits the reviewed changes (or any
# subset that preserves the diff), the hash still matches and the push is
# allowed. `git diff HEAD` covers both staged and unstaged changes, so we do
# not need a separate `--cached` term.
HEAD_AT_REVIEW=$(git rev-parse HEAD 2>/dev/null || echo "")
DIFF_HASH=$(git diff HEAD 2>/dev/null | _sha256)

{
  echo "$HEAD_AT_REVIEW"
  echo "$DIFF_HASH"
} > "$SENTINEL"
