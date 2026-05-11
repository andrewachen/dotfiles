#!/usr/bin/env bash
# ABOUTME: Stub tmux for tests/screen. has-session honors STUB_TMUX_SESSIONS;
# ABOUTME: every invocation appends its argv to $STUB_TMUX_LOG.

set -uo pipefail

if [[ -n "${STUB_TMUX_LOG:-}" ]]; then
    printf 'tmux'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
fi >> "${STUB_TMUX_LOG:-/dev/null}"

if [[ "${1:-}" == "has-session" ]]; then
    target=
    while (($#)); do
        case "$1" in
            -t) shift; target="${1:-}"; shift ;;
            *) shift ;;
        esac
    done
    for s in ${STUB_TMUX_SESSIONS:-}; do
        if [[ "$s" == "$target" ]]; then exit 0; fi
    done
    exit 1
fi

if [[ "${1:-}" == "list-sessions" ]]; then
    shift
    fmt=
    while (($#)); do
        case "$1" in
            -F) shift; fmt="${1:-}"; shift ;;
            *) shift ;;
        esac
    done
    for s in ${STUB_TMUX_SESSIONS:-}; do
        if [[ "$fmt" == "#{session_name}" ]]; then
            printf '%s\n' "$s"
        else
            printf '%s: 1 windows\n' "$s"
        fi
    done
    exit 0
fi

exit 0
