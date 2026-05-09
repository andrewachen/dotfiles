#!/usr/bin/env python3
# ABOUTME: PreToolUse Bash hook denying redundant `git -C/--git-dir/--work-tree`
# ABOUTME: into cwd and `cd <cwd> && git ...` — both defeat the auto-allow matcher.

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


def classify_location(path: str, cwd: str) -> str | None:
    """Return 'cwd', 'subdir', or None.

    'cwd':    path resolves to cwd or cwd/.git -- truly redundant relocation.
    'subdir': path resolves to a directory inside cwd -- reachable from cwd
              via plain cd or EnterWorktree without -C / --git-dir / --work-tree.
    None:     path is outside cwd's tree (likely a genuinely different repo).
    """
    try:
        expanded = os.path.realpath(os.path.expandvars(os.path.expanduser(path)))
    except (OSError, ValueError):
        return None
    if expanded == cwd or expanded == os.path.join(cwd, ".git"):
        return "cwd"
    if expanded.startswith(cwd + os.sep):
        return "subdir"
    return None


def find_in_tree_git_relocation(
    tokens: list[str], cwd: str
) -> tuple[str, str, str] | None:
    """Return (rendered_flag, path, kind) for the first in-tree location flag.

    rendered_flag is the user-facing form to quote in the deny message:
    `-C`, `--git-dir`, or `--work-tree` for space-separated args, or
    `--git-dir=` / `--work-tree=` (trailing `=`) for equal-form args.
    kind is the classify_location() result: 'cwd' or 'subdir'.
    """
    for i, tok in enumerate(tokens):
        if tok != "git":
            continue
        j = i + 1
        while j < len(tokens):
            t = tokens[j]
            if t in GIT_LOCATION_FLAGS and j + 1 < len(tokens):
                kind = classify_location(tokens[j + 1], cwd)
                if kind is not None:
                    return t, tokens[j + 1], kind
                j += 2
            elif t.startswith(GIT_LOCATION_EQ_PREFIXES):
                flag, _, path = t.partition("=")
                kind = classify_location(path, cwd) if path else None
                if kind is not None:
                    return f"{flag}=", path, kind
                j += 1
            elif t == "-c" and j + 1 < len(tokens):
                j += 2
            elif t.startswith("-"):
                j += 1
            else:
                break
    return None


def find_redundant_cd_git(tokens: list[str], cwd: str) -> str | None:
    """Block only exact-cwd `cd <cwd> && git ...`. cd to a subdir is genuine."""
    for i in range(len(tokens) - 3):
        if (
            tokens[i] == "cd"
            and tokens[i + 2] in SEPARATORS
            and tokens[i + 3] == "git"
            and classify_location(tokens[i + 1], cwd) == "cwd"
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

    hit = find_in_tree_git_relocation(tokens, cwd)
    if hit is not None:
        flag, path, kind = hit
        invocation = f"{flag}{path}" if flag.endswith("=") else f"{flag} {path}"
        if kind == "cwd":
            deny(
                f"`git {invocation}` points at the current working directory "
                f"({cwd}). Drop this flag and keep any other flags that are "
                "genuinely needed. If your cwd is wrong for this work, that's "
                "a dispatch problem -- main session: `cd` to the right place "
                "once (persists within the project); subagent: bail and have "
                "your parent dispatch you with the right cwd (subagent `cd` "
                "doesn't persist between calls). Don't paper over wrong cwd "
                "with redundant relocation flags."
            )
        else:  # kind == "subdir"
            deny(
                f"`git {invocation}` targets a path inside cwd ({cwd}). Drop "
                "the flag -- `-C/--git-dir/--work-tree` defeats the auto-allow "
                "matcher for read-only git subcommands and forces a permission "
                "prompt. **Main session:** `cd <path>` (cwd persists) or "
                "`EnterWorktree` for a registered worktree. **Subagent:** "
                "`EnterWorktree` isn't available and `cd` doesn't persist "
                "between calls -- bail and have your parent dispatch you with "
                "the right cwd."
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
