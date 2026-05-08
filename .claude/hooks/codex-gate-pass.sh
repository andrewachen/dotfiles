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
STAGED=$(echo "$STDERR" | grep -oE 'staged=[^[:space:]]+' | head -n1 | cut -d= -f2- || true)

[[ -z "$STAGED" ]] && exit 0
[[ ! -f "$STAGED" ]] && exit 0

mv "$STAGED" "/tmp/codex-gate-${SESSION_ID}-${REPO_NAME}"
