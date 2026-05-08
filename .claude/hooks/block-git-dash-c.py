#!/usr/bin/env python3
# ABOUTME: PreToolUse Bash hook that denies redundant repo relocation -- `git -C <cwd>`,
# ABOUTME: `git --git-dir <cwd>/.git`, `git --work-tree <cwd>`, and `cd <cwd> && git ...` --
# ABOUTME: where the path resolves to the current working directory. These trigger
# ABOUTME: unnecessary sandbox approval prompts. Returns permissionDecision=deny with a
# ABOUTME: reason so Claude retries without the relocation.

import json
import os
import shlex
import sys

HOOK_EVENT = "PreToolUse"
SEPARATORS = {"&&", ";"}
GIT_LOCATION_FLAGS = {"-C", "--git-dir", "--work-tree"}
GIT_LOCATION_EQ_PREFIXES = ("--git-dir=", "--work-tree=")


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


def is_redundant(path: str, cwd: str) -> bool:
    try:
        expanded = os.path.realpath(os.path.expandvars(os.path.expanduser(path)))
    except (OSError, ValueError):
        return False
    return expanded == cwd or expanded == os.path.join(cwd, ".git")


def find_redundant_git_relocation(
    tokens: list[str], cwd: str
) -> tuple[str, str] | None:
    """Return (rendered_flag, path) for the first redundant location flag found.

    rendered_flag is the user-facing form to quote in the deny message:
    `-C`, `--git-dir`, or `--work-tree` for space-separated args, or
    `--git-dir=` / `--work-tree=` (trailing `=`) for equal-form args.
    """
    for i, tok in enumerate(tokens):
        if tok != "git":
            continue
        j = i + 1
        while j < len(tokens):
            t = tokens[j]
            if t in GIT_LOCATION_FLAGS and j + 1 < len(tokens):
                if is_redundant(tokens[j + 1], cwd):
                    return t, tokens[j + 1]
                j += 2
            elif t.startswith(GIT_LOCATION_EQ_PREFIXES):
                flag, _, path = t.partition("=")
                if path and is_redundant(path, cwd):
                    return f"{flag}=", path
                j += 1
            elif t == "-c" and j + 1 < len(tokens):
                j += 2
            elif t.startswith("-"):
                j += 1
            else:
                break
    return None


def find_redundant_cd_git(tokens: list[str], cwd: str) -> str | None:
    for i in range(len(tokens) - 3):
        if (
            tokens[i] == "cd"
            and tokens[i + 2] in SEPARATORS
            and tokens[i + 3] == "git"
            and is_redundant(tokens[i + 1], cwd)
        ):
            return tokens[i + 1]
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

    try:
        tokens = shlex.split(cmd)
    except ValueError:
        sys.exit(0)

    cwd = os.path.realpath(data.get("cwd") or os.getcwd())
    # Pin $PWD so os.path.expandvars resolves "$PWD" / "${PWD}" against the
    # authoritative session cwd rather than whatever the harness happened to
    # inherit.
    os.environ["PWD"] = cwd

    hit = find_redundant_git_relocation(tokens, cwd)
    if hit is not None:
        flag, path = hit
        invocation = f"{flag}{path}" if flag.endswith("=") else f"{flag} {path}"
        deny(
            f"`git {invocation}` points at the current working directory "
            f"({cwd}). Drop this flag and keep any other flags that are "
            "genuinely needed. If your cwd is wrong for this work, that's a "
            "dispatch problem -- main session: `cd` to the right place once "
            "(persists within the project); subagent: bail and have your "
            "parent dispatch you with the right cwd (subagent `cd` doesn't "
            "persist between calls). Don't paper over wrong cwd with "
            "redundant relocation flags."
        )

    cd_path = find_redundant_cd_git(tokens, cwd)
    if cd_path is not None:
        deny(
            f"`cd {cd_path} && git ...` cd's into the current working directory "
            f"({cwd}) and then runs git. The cd is redundant -- drop it and "
            "run plain `git`. If your cwd is wrong for this work, that's a "
            "dispatch problem -- main session: `cd` to the right place once "
            "(persists within the project); subagent: bail and have your "
            "parent dispatch you with the right cwd (subagent `cd` doesn't "
            "persist between calls). Don't chain redundant cd's into every "
            "command."
        )

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open: this is a quality-of-life hook, not a security boundary.
        # A crash must not block the user's Bash call.
        sys.exit(0)
