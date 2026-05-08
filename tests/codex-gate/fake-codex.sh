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
