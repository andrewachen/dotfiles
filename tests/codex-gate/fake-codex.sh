#!/usr/bin/env bash
# ABOUTME: Stub `codex` binary for the codex-gate test harness. Writes a
# ABOUTME: minimal transcript with the `^codex$` marker so the wrapper's
# ABOUTME: verdict-extraction path works, then exits with $FAKE_CODEX_RC.
# ABOUTME: If FAKE_CODEX_TOKENS="input cached output reasoning total" is set
# ABOUTME: (with CODEX_HOME pointing at a writable dir), also writes a synthetic
# ABOUTME: session JSONL with two token_count events so the wrapper's
# ABOUTME: token-summary path is exercised. FAKE_CODEX_TURN1_TOTAL (same 5-tuple
# ABOUTME: format) overrides the first event's cumulative snapshot; default is
# ABOUTME: a tiny "1 2 3 4 5" so single-turn tests still see clean deltas.

if [[ "${1:-}" == "review" ]]; then
  cat <<'EOF'
some exploration log line
codex
verdict goes here
EOF

  if [[ -n "${FAKE_CODEX_TOKENS:-}" && -n "${CODEX_HOME:-}" ]]; then
    read -r t2_in t2_ca t2_ou t2_re t2_to <<<"$FAKE_CODEX_TOKENS"
    read -r t1_in t1_ca t1_ou t1_re t1_to <<<"${FAKE_CODEX_TURN1_TOTAL:-0 0 0 0 0}"
    sess_dir="$CODEX_HOME/sessions/$(date -u +%Y/%m/%d)"
    mkdir -p "$sess_dir"
    # Two token_count events with cumulative total_token_usage snapshots. The
    # wrapper computes per-turn cost via deltas between consecutive snapshots,
    # so any turn-1 cumulative telescopes into the final FAKE_CODEX_TOKENS total
    # and matches single-turn test expectations regardless of the turn-1 split.
    {
      printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"fake","timestamp":"2026-01-01T00:00:00Z","cwd":"%s","originator":"codex_exec","cli_version":"test","source":{"subagent":"review"}}}\n' "$PWD"
      if [[ -n "${FAKE_CODEX_MODEL:-}" ]]; then
        printf '{"timestamp":"2026-01-01T00:00:00.500Z","type":"turn_context","payload":{"turn_id":"fake-turn","model":"%s"}}\n' "$FAKE_CODEX_MODEL"
      fi
      printf '{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s,"reasoning_output_tokens":%s,"total_tokens":%s}}}}\n' \
        "$t1_in" "$t1_ca" "$t1_ou" "$t1_re" "$t1_to"
      printf '{"timestamp":"2026-01-01T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s,"reasoning_output_tokens":%s,"total_tokens":%s}}}}\n' \
        "$t2_in" "$t2_ca" "$t2_ou" "$t2_re" "$t2_to"
    } > "$sess_dir/rollout-fake.jsonl"
  fi

  exit "${FAKE_CODEX_RC:-0}"
fi

exit 0
