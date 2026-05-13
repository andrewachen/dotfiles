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

# Split a STUB_TMUX_SESSIONS entry "name[:group]" into name and group.
session_name_of() { printf '%s' "${1%%:*}"; }
session_group_of() {
    if [[ "$1" == *:* ]]; then printf '%s' "${1#*:}"; fi
}

if [[ "${1:-}" == "has-session" ]]; then
    target=
    while (($#)); do
        case "$1" in
            -t) shift; target="${1:-}"; shift ;;
            *) shift ;;
        esac
    done
    # Exact match first.
    for s in ${STUB_TMUX_SESSIONS:-}; do
        if [[ "$(session_name_of "$s")" == "$target" ]]; then exit 0; fi
    done
    # Unique prefix match second (mirrors real tmux -t behavior).
    count=0
    for s in ${STUB_TMUX_SESSIONS:-}; do
        n=$(session_name_of "$s")
        if [[ "$n" == "$target"* ]]; then count=$((count+1)); fi
    done
    if (( count == 1 )); then exit 0; fi
    exit 1
fi

if [[ "${1:-}" == "list-sessions" ]]; then
    shift
    fmt=
    filter=
    while (($#)); do
        case "$1" in
            -F) shift; fmt="${1:-}"; shift ;;
            -f) shift; filter="${1:-}"; shift ;;
            *) shift ;;
        esac
    done
    if [[ -n $filter && -n "${STUB_TMUX_LS_FILTER_LOG:-}" ]]; then
        printf '%s\n' "$filter" >> "$STUB_TMUX_LS_FILTER_LOG"
    fi
    for s in ${STUB_TMUX_SESSIONS:-}; do
        n=$(session_name_of "$s")
        g=$(session_group_of "$s")
        case "$fmt" in
            '#{session_name}')              printf '%s\n' "$n" ;;
            '#{session_name}|#{session_group}') printf '%s|%s\n' "$n" "$g" ;;
            *)                              printf '%s: 1 windows\n' "$n" ;;
        esac
    done
    exit 0
fi

if [[ "${1:-}" == "display-message" ]]; then
    shift
    target=
    fmt=
    while (($#)); do
        case "$1" in
            -t) shift; target="${1:-}"; shift ;;
            -p) shift; fmt="${1:-}"; shift ;;
            *) shift ;;
        esac
    done
    # tmux accepts `name:` as the current window of session `name`; for
    # our lookup we only care about the session, so strip the trailing colon.
    target=${target%:}
    if [[ "$fmt" == "#{session_name}" || "$fmt" == "#{session_group}" ]]; then
        # Exact match first.
        for s in ${STUB_TMUX_SESSIONS:-}; do
            n=$(session_name_of "$s")
            if [[ "$n" == "$target" ]]; then
                if [[ "$fmt" == "#{session_group}" ]]; then
                    printf '%s\n' "$(session_group_of "$s")"
                else
                    printf '%s\n' "$n"
                fi
                exit 0
            fi
        done
        # Unique prefix match second.
        match_entry=
        count=0
        for s in ${STUB_TMUX_SESSIONS:-}; do
            n=$(session_name_of "$s")
            if [[ "$n" == "$target"* ]]; then
                match_entry=$s
                count=$((count+1))
            fi
        done
        if (( count == 1 )); then
            if [[ "$fmt" == "#{session_group}" ]]; then
                printf '%s\n' "$(session_group_of "$match_entry")"
            else
                printf '%s\n' "$(session_name_of "$match_entry")"
            fi
            exit 0
        fi
        exit 1
    fi
    exit 0
fi

exit 0
