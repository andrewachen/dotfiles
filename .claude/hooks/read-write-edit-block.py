#!/usr/bin/env python3
# ABOUTME: PreToolUse Bash hook denying single-file cat/head/sed/echo invocations
# ABOUTME: when Read/Write/Edit covers the case; skips pipes, multi-file, scripts.

import json
import re
import shlex
import sys

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


def is_filename_arg(s: str) -> bool:
    """Reject tokens that are obviously not a literal file path.

    shlex preserves shell metacharacters that aren't quoted, so a token
    starting with one of these means the segment is doing something the
    dedicated tools can't replicate (heredoc, command sub, subshell, etc.).
    """
    if not s:
        return False
    if s[0] in "<>|()&;`":
        return False
    if s.startswith("$("):
        return False
    return True


def split_segments(cmd: str) -> list[str]:
    """Split on shell-level separators (`;`, newline, `&&`, `||`), respecting
    single/double quotes and backslash escapes so that quoted separators stay
    inside their argument (e.g. `echo 'a;b' > f` is one segment, not two).
    """
    segments: list[str] = []
    buf: list[str] = []
    quote: str | None = None
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote == "'":
            buf.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            buf.append(c)
            if c == "\\" and i + 1 < n:
                buf.append(cmd[i + 1])
                i += 2
                continue
            if c == '"':
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            buf.append(c)
            buf.append(cmd[i + 1])
            i += 2
            continue
        if c == "'" or c == '"':
            quote = c
            buf.append(c)
            i += 1
            continue
        if c == ";" or c == "\n":
            seg = "".join(buf).strip()
            if seg:
                segments.append(seg)
            buf = []
            i += 1
            continue
        if i + 1 < n and cmd[i:i + 2] in ("&&", "||"):
            seg = "".join(buf).strip()
            if seg:
                segments.append(seg)
            buf = []
            i += 2
            continue
        buf.append(c)
        i += 1
    seg = "".join(buf).strip()
    if seg:
        segments.append(seg)
    return segments


def check_cat(args: list[str]) -> str | None:
    # Only `cat <single-file>` -- no flags, no pipes, no redirects.
    if len(args) != 1:
        return None
    if not is_filename_arg(args[0]) or args[0].startswith("-"):
        return None
    file_q = shlex.quote(args[0])
    return (
        f"`cat {file_q}` reads a file -- use the Read tool instead. Read "
        "returns line-numbered output and supports offset/limit for large "
        "files. (This hook only blocks single-file `cat <file>`; `cat` with "
        "flags, pipes, multiple files, or redirects is allowed.)"
    )


def check_head(args: list[str]) -> str | None:
    # `head <file>`, `head -n N <file>`, `head -N <file>`. Other flags skip.
    n = 10  # GNU head default
    file: str | None = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-n" and i + 1 < len(args) and args[i + 1].isdigit():
            n = int(args[i + 1])
            i += 2
        elif len(a) > 1 and a[0] == "-" and a[1:].isdigit():
            n = int(a[1:])
            i += 1
        elif a.startswith("-"):
            return None
        else:
            if file is not None:
                return None
            if not is_filename_arg(a):
                return None
            file = a
            i += 1
    if file is None:
        return None
    file_q = shlex.quote(file)
    return (
        f"`head -n {n} {file_q}` reads the first {n} lines -- use the Read "
        f"tool with limit={n}. Read also returns line-numbered output."
    )


def check_sed(args: list[str]) -> str | None:
    # `sed -n '<range>p' <file>` -> Read offset/limit
    # `sed -i '<s/X/Y/[flags]>' <file>` -> Edit
    if len(args) != 3:
        return None
    flag, script, file = args
    if not is_filename_arg(file):
        return None
    file_q = shlex.quote(file)

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


def check_echo(tokens: list[str]) -> str | None:
    # `echo <args>... > <file>`  -> Write
    # `echo <args>... >> <file>` -> Edit (append)
    # Requires `>` or `>>` as a standalone token followed by a single file
    # token at the end. Refuses if a pipe / other redirect is present, or if
    # echo flags (-n / -e / -E) change semantics in ways Write can't match,
    # or if the redirect has no content (echo writes "\n", Write writes "").
    if "|" in tokens or "<" in tokens or "<<" in tokens:
        return None

    for op in (">>", ">"):
        if op in tokens:
            idx = tokens.index(op)
            # Must be exactly: echo <args>... OP <file>  with file last.
            if idx != len(tokens) - 2:
                return None
            file = tokens[idx + 1]
            if not is_filename_arg(file):
                return None
            content = tokens[1:idx]
            if any(a.startswith("-") for a in content):
                return None
            if not content or all(a == "" for a in content):
                return None
            file_q = shlex.quote(file)
            newline_note = (
                " Note: echo adds a trailing newline; include `\\n` in the "
                "Write content if you want it."
            )
            if op == ">":
                return (
                    f"`echo ... > {file_q}` writes a file -- use the Write "
                    f"tool. Write owns file creation/replacement.{newline_note}"
                )
            return (
                f"`echo ... >> {file_q}` appends to a file -- use the Edit "
                "tool to add the new content (or Read+Write for a full "
                f"replacement).{newline_note}"
            )
    return None


def check_segment(seg: str) -> str | None:
    """Return a deny reason if this segment is a clean Read/Write/Edit case."""
    try:
        tokens = shlex.split(seg)
    except ValueError:
        return None
    if not tokens:
        return None

    cmd_name = tokens[0]
    args = tokens[1:]

    if cmd_name == "cat":
        # Refuse if any redirect/pipe metacharacter is in the segment.
        if any(t in (">", ">>", "<", "<<", "|") for t in args):
            return None
        return check_cat(args)
    if cmd_name == "head":
        if any(t in (">", ">>", "<", "<<", "|") for t in args):
            return None
        return check_head(args)
    if cmd_name == "sed":
        if any(t in (">", ">>", "<", "<<", "|") for t in args):
            return None
        return check_sed(args)
    if cmd_name == "echo":
        return check_echo(tokens)
    return None


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

    for seg in split_segments(cmd):
        reason = check_segment(seg)
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
