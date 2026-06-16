#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["bashlex"]
# ///
# ABOUTME: PreToolUse Bash hook denying any `echo ... $?` that isn't the exact
# ABOUTME: canonical `echo "EXIT=$?"`. Variants register as distinct permission
# ABOUTME: rules and re-trigger prompts; this converges every agent on one form.

import json
import re
import sys

import bashlex
import bashlex.errors

HOOK_EVENT = "PreToolUse"

# The one allowlisted literal for reporting a previous command's exit code.
CANONICAL = 'echo "EXIT=$?"'

# Degenerate fallback: split a command line into simple-command segments on the
# shell operators that start a new command. `||`/`&&` precede the single-char
# class so the alternation consumes them whole. Only used when bashlex can't
# parse the command (e.g. `[[ ]]`, array assignments) — the offending segments
# (`[[ -f x ]]`, `arr=(a b)`) land in non-echo segments the predicate ignores,
# while a trailing `&& echo …=$?` is still caught.
SEGMENT_SPLIT = re.compile(r"\|\||&&|[|;&\n]")


def deny(reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": HOOK_EVENT,
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    sys.exit(0)


def classify_echo(text: str) -> str | None:
    """Return `text` (stripped) if it's a non-canonical exit-code echo, else None.

    The discriminator is quoting, so this works on RAW text — `echo "EXIT=$?"`
    and `echo EXIT=$?` are different permission rules. Both the bashlex path
    (raw slice of a command node) and the regex fallback (a split segment) feed
    raw text here so they can't disagree on what counts as offending.
    """
    s = text.strip()
    # `echo` must be a bare leading word — not `echoed=…` or `echoes …`.
    if not s.startswith("echo"):
        return None
    after_echo = s[len("echo"):]
    if after_echo and not after_echo[0].isspace():
        return None
    # Only exit-code echoes are in scope; a plain `echo "hi"` is fine. `${?}`
    # is the braced-parameter equivalent of `$?` and just as much an exit-code
    # echo, so catch both forms.
    if "$?" not in s and "${?}" not in s:
        return None
    if s == CANONICAL:
        return None
    return s


def walk_command_nodes(node):
    """Yield every `command` node in a bashlex tree, descending through lists,
    pipelines, compounds, and command substitutions so a trailing or nested
    echo is reached wherever it sits."""
    if node.kind == "command":
        yield node
    for child in getattr(node, "parts", []) or []:
        yield from walk_command_nodes(child)
    # Compound nodes (`{ … }`, `( … )`, `if`/`while`/`for`) store their body in
    # `.list` as a Python list of child nodes, not a single node.
    sublist = getattr(node, "list", None)
    if isinstance(sublist, list):
        for child in sublist:
            yield from walk_command_nodes(child)
    elif sublist is not None:
        yield from walk_command_nodes(sublist)
    subcommand = getattr(node, "command", None)
    if subcommand is not None:
        yield from walk_command_nodes(subcommand)


def command_word_span(node, cmd: str) -> str | None:
    """Raw source of a command node's word parts, excluding trailing/leading
    redirects. bashlex includes redirects in `node.pos`, so slicing the full
    span would fold `> /dev/null` into the text and reject an otherwise
    canonical echo. Slice from the first word to the last word instead."""
    words = [p for p in node.parts if p.kind != "redirect"]
    if not words:
        return None
    return cmd[words[0].pos[0]:words[-1].pos[1]]


def inspect_via_bashlex(cmd: str) -> str | None:
    """Precise path: find echo command nodes and judge their raw source text.

    Heredoc bodies are redirect content, not command nodes, so they're never
    reached here — no special-casing needed."""
    for tree in bashlex.parse(cmd):
        for node in walk_command_nodes(tree):
            text = command_word_span(node, cmd)
            if text is None:
                continue
            hit = classify_echo(text)
            if hit is not None:
                return hit
    return None


def inspect_via_regex(cmd: str) -> str | None:
    """Degenerate fallback for commands bashlex can't parse (it raises on
    `[[ ]]`, arrays, and all heredocs).

    Skip anything with a heredoc: a literal `echo "rc=$?"` line inside a
    heredoc body is script content, not an interactive exit-code check, and the
    fallback can't tell body lines from a real trailing `echo $?` without
    re-implementing heredoc-delimiter tracking that bashlex itself punts on.
    Accepted fail-open gap: a genuine `cat <<EOF…EOF ; echo $?` slips through."""
    if "<<" in cmd:
        return None
    for segment in SEGMENT_SPLIT.split(cmd):
        hit = classify_echo(segment)
        if hit is not None:
            return hit
    return None


def find_offender(cmd: str) -> str | None:
    try:
        return inspect_via_bashlex(cmd)
    except Exception:
        # ANY bashlex failure (ParsingError on `[[ ]]`/arrays, or otherwise)
        # routes to the regex backstop rather than failing fully open — the
        # trailing `&& echo …=$?` is the dominant case and must not escape.
        return inspect_via_regex(cmd)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    if data.get("tool_name") != "Bash":
        sys.exit(0)

    cmd = (data.get("tool_input") or {}).get("command", "")
    if not cmd:
        sys.exit(0)

    offender = find_offender(cmd)
    if offender is not None:
        deny(
            f"`{offender}` is a non-canonical way to echo a previous command's "
            f'exit code. Use EXACTLY `{CANONICAL}` — same casing, label, and '
            "quoting. Each variant registers as a distinct permission rule and "
            "re-triggers prompts; only the canonical form is on the allowlist."
        )

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open: this is a quality-of-life hook, not a security boundary.
        # A crash must not block the user's Bash call.
        sys.exit(0)
