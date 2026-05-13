#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["bashlex"]
# ///
# ABOUTME: PreToolUse Bash hook denying single-file cat/head/sed/echo invocations
# ABOUTME: when Read/Write/Edit covers the case; skips pipes, multi-file, scripts.

import json
import re
import shlex
import sys

import bashlex
import bashlex.errors

HOOK_EVENT = "PreToolUse"

# `sed -n '<range>p'` where range is N or N,M -- the only sed-print form Read
# can replicate exactly (single contiguous line window).
SED_PRINT_RE = re.compile(r"^\d+(?:,\d+)?p$")

# `s<delim>X<delim>Y<delim>[flags]` -- single substitution, any single-char
# delimiter. Lenient by design: false-allows are acceptable.
SED_SUB_RE = re.compile(r"^s(.).*?\1.*?\1[gIp]*$")


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


def has_only_path_parts(word_node) -> bool:
    """True if the word can be treated as a literal path argument. Tilde sub-
    parts are accepted because Read/Write/Edit handle `~` expansion; any other
    sub-part (parameter, command substitution, process substitution) means the
    tool can't replicate the path bash would resolve.
    """
    parts = getattr(word_node, "parts", []) or []
    return all(p.kind == "tilde" for p in parts)


def has_only_literal_parts(word_node) -> bool:
    """True if the word is a pure literal — no expansions of any kind. Used
    for echo content, where bash expands tilde and `$X` before echo sees them,
    so a literal Write call could not reproduce the same bytes.
    """
    return not (getattr(word_node, "parts", []) or [])


def word_text(word_node) -> str:
    return getattr(word_node, "word", "") or ""


def iter_simple_commands(node):
    """Yield each `command` node that's a candidate for blocking.

    A command is a candidate if it sits at the top of a list or alone; commands
    inside pipelines, compound statements (for/while/if/case), function
    definitions, and command substitutions are skipped because either the user
    is composing (pipe) or the construct isn't a plain single-file invocation.
    """
    kind = node.kind
    if kind == "command":
        yield node
        return
    if kind == "list":
        for part in node.parts:
            if part.kind == "operator":
                continue
            yield from iter_simple_commands(part)


def split_command(cmd_node):
    """Return (head_text, arg_words, redirects). Returns (None, [], []) if the
    command has no head word (e.g. assignment-only commands like `X=$(cmd)`)
    or has any leading assignment (env-prefix like `FOO=bar echo hi > out`).
    Env-prefixed commands sometimes care about the prefix and sometimes don't;
    the hook can't tell, so we preserve the existing "allow through" behavior
    by refusing to inspect any assignment-prefixed command.
    """
    words: list = []
    redirects: list = []
    for part in cmd_node.parts:
        if part.kind == "assignment":
            return None, [], []
        if part.kind == "word":
            words.append(part)
        elif part.kind == "redirect":
            redirects.append(part)
    if not words:
        return None, [], []
    return word_text(words[0]), words[1:], redirects


def check_cat(args, redirects) -> str | None:
    # Only `cat <single-literal-file>` -- no flags, no redirects, no pipes
    # (pipes can't reach a command node here, since pipeline commands are
    # filtered out upstream).
    if redirects:
        return None
    if len(args) != 1:
        return None
    arg = args[0]
    text = word_text(arg)
    if not text or text.startswith("-"):
        return None
    if not has_only_path_parts(arg):
        return None
    file_q = shlex.quote(text)
    return (
        f"`cat {file_q}` reads a file -- use the Read tool instead. Read "
        "returns line-numbered output and supports offset/limit for large "
        "files. (This hook only blocks single-file `cat <file>`; `cat` with "
        "flags, pipes, multiple files, or redirects is allowed.)"
    )


def check_head(args, redirects) -> str | None:
    # `head <file>`, `head -n N <file>`, `head -N <file>`. Other flags skip.
    if redirects:
        return None
    n = 10  # GNU head default
    file_word = None
    i = 0
    while i < len(args):
        a = word_text(args[i])
        if a == "-n" and i + 1 < len(args) and word_text(args[i + 1]).isdigit():
            n = int(word_text(args[i + 1]))
            i += 2
        elif len(a) > 1 and a[0] == "-" and a[1:].isdigit():
            n = int(a[1:])
            i += 1
        elif a.startswith("-"):
            return None
        else:
            if file_word is not None:
                return None
            if not a or not has_only_path_parts(args[i]):
                return None
            file_word = args[i]
            i += 1
    if file_word is None:
        return None
    file_q = shlex.quote(word_text(file_word))
    return (
        f"`head -n {n} {file_q}` reads the first {n} lines -- use the Read "
        f"tool with limit={n}. Read also returns line-numbered output."
    )


def check_sed(args, redirects) -> str | None:
    # `sed -n '<range>p' <file>` -> Read offset/limit
    # `sed -i '<s/X/Y/[flags]>' <file>` -> Edit
    if redirects:
        return None
    if len(args) != 3:
        return None
    flag = word_text(args[0])
    script = word_text(args[1])
    file_word = args[2]
    if not has_only_path_parts(file_word):
        return None
    file_text = word_text(file_word)
    if not file_text or file_text.startswith("-"):
        return None
    file_q = shlex.quote(file_text)

    if flag == "-n" and SED_PRINT_RE.match(script):
        if "," in script:
            n_str, m_str = script[:-1].split(",")
            n, m = int(n_str), int(m_str)
            return (
                f"`sed -n '{script}' {file_q}` prints lines {n}-{m} -- use the "
                f"Read tool with offset={n}, limit={m - n + 1}."
            )
        n = int(script[:-1])
        return (
            f"`sed -n '{script}' {file_q}` prints line {n} -- use the Read "
            f"tool with offset={n}, limit=1."
        )

    if flag == "-i" and SED_SUB_RE.match(script):
        return (
            f"`sed -i '{script}' {file_q}` edits the file in place -- use the "
            "Edit tool. Edit shows the diff and is reviewable."
        )

    return None


def check_echo(args, redirects) -> str | None:
    # `echo <content>... > <file>`  -> Write
    # `echo <content>... >> <file>` -> Edit (append)
    # Requires exactly one redirect, of type > or >>, to a literal file.
    # Refuses if echo flags (-n / -e / -E) change semantics in ways Write
    # can't match, or if the redirect has no content.
    if len(redirects) != 1:
        return None
    r = redirects[0]
    if r.type not in (">", ">>"):
        return None
    if r.input not in (None, 1):
        # Non-stdout fd (`2> err`, `10> log`): the file captures something other
        # than echo's stdout, so Write/Edit can't replicate. Allow through.
        return None
    if r.output is None or not has_only_path_parts(r.output):
        return None
    file_text = word_text(r.output)
    if not file_text:
        return None

    # Content words (everything after `echo`, before the redirect). No flags,
    # at least one non-empty literal word. A non-literal word (variable, cmd
    # substitution, tilde) means Write can't reproduce the echoed bytes -- the
    # shell would expand before echo saw it -- so don't nudge.
    if not args:
        return None
    for w in args:
        if word_text(w).startswith("-"):
            return None
        if not has_only_literal_parts(w):
            return None
    if all(word_text(w) == "" for w in args):
        return None

    file_q = shlex.quote(file_text)
    newline_note = (
        " Note: echo adds a trailing newline; include `\\n` in the "
        "Write content if you want it."
    )
    if r.type == ">":
        return (
            f"`echo ... > {file_q}` writes a file -- use the Write "
            f"tool. Write owns file creation/replacement.{newline_note}"
        )
    return (
        f"`echo ... >> {file_q}` appends to a file -- use the Edit "
        "tool to add the new content (or Read+Write for a full "
        f"replacement).{newline_note}"
    )


CHECKS = {
    "cat": check_cat,
    "head": check_head,
    "sed": check_sed,
    "echo": check_echo,
}


def check_command(cmd_node) -> str | None:
    head, args, redirects = split_command(cmd_node)
    if head is None:
        return None
    check = CHECKS.get(head)
    if check is None:
        return None
    return check(args, redirects)


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

    try:
        trees = bashlex.parse(cmd)
    except bashlex.errors.ParsingError:
        # Invalid bash (e.g. `cat <<EOF` with no body, unbalanced quotes).
        # Fail open: don't block on what we can't parse.
        sys.exit(0)

    for tree in trees:
        for cmd_node in iter_simple_commands(tree):
            reason = check_command(cmd_node)
            if reason is not None:
                deny(reason)

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open: this is a quality-of-life hook, not a security boundary.
        # A crash must not block the user's Bash call.
        sys.exit(0)
