#!/usr/bin/env bash
# ABOUTME: Stub /usr/bin/screen for tests/screen. -ls prints STUB_SCREEN_LS;
# ABOUTME: every invocation appends its argv to $STUB_SCREEN_LOG.

set -uo pipefail

if [[ -n "${STUB_SCREEN_LOG:-}" ]]; then
    printf 'screen'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
fi >> "${STUB_SCREEN_LOG:-/dev/null}"

if [[ "${1:-}" == "-ls" ]]; then
    printf '%b' "${STUB_SCREEN_LS:-}"
    exit "${STUB_SCREEN_LS_RC:-0}"
fi

exit 0
