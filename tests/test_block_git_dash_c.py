#!/usr/bin/env python3
# ABOUTME: Test suite for .claude/hooks/block-git-dash-c.py — pipes synthetic
# ABOUTME: PreToolUse JSON in and asserts deny/allow. Run: python3 tests/test_*.py.

import json
import subprocess
import sys
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / ".claude" / "hooks" / "block-git-dash-c.py"
CWD = "/home/achen/git/gh/dotfiles"


def run(cmd: str, tool: str = "Bash", cwd: str = CWD) -> tuple[int, str]:
    payload: dict = {"tool_name": tool, "cwd": cwd}
    if tool == "Bash":
        payload["tool_input"] = {"command": cmd}
    else:
        payload["tool_input"] = {"file_path": "/tmp/x"}
    result = subprocess.run(
        [str(HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    return result.returncode, result.stdout


def is_deny(out: str) -> bool:
    if not out:
        return False
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return False
    return data.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"


DENY_CASES = [
    ("git -C cwd literal",            f"git -C {CWD} status"),
    ("git -C cwd quoted",             f'git -C "{CWD}" status'),
    ('git -C "$PWD"',                 'git -C "$PWD" status'),
    ('git -C ${PWD}',                 'git -C "${PWD}" status'),
    ("git -C .",                      "git -C . status"),
    ("git -c k=v -C cwd",             f"git -c user.email=x -C {CWD} status"),
    ("git --no-pager -C cwd",         f"git --no-pager -C {CWD} log"),
    ("git --git-dir cwd/.git",        f"git --git-dir {CWD}/.git status"),
    ("git --work-tree cwd",           f"git --work-tree {CWD} status"),
    ("git --git-dir=cwd/.git",        f"git --git-dir={CWD}/.git status"),
    ("git --work-tree=cwd",           f"git --work-tree={CWD} status"),
    ("git --git-dir=cwd/.git --work-tree=cwd",
                                      f"git --git-dir={CWD}/.git --work-tree={CWD} status"),
    # Mixed: --git-dir is redundant, --work-tree is genuinely a sub-worktree.
    # Should still deny because --git-dir alone is redundant.
    ("git --git-dir=cwd/.git --work-tree=sub",
                                      f"git --git-dir={CWD}/.git --work-tree={CWD}/.claude/worktrees/x diff"),
    # Reverse order: non-redundant --work-tree first, redundant --git-dir
    # second. Loop must advance past the non-redundant flag to find the
    # redundancy.
    ("git --work-tree=sub --git-dir=cwd/.git",
                                      f"git --work-tree={CWD}/.claude/worktrees/x --git-dir={CWD}/.git diff"),
    # In-tree subdirs: -C/--git-dir/--work-tree to a path inside cwd defeats
    # the auto-allow matcher and forces a permission prompt even though the
    # path is genuinely a different directory. Hook denies with a cd /
    # EnterWorktree hint.
    ("git -C subdir-of-cwd",          f"git -C {CWD}/.claude log --oneline"),
    ("git -C worktree-subpath",       f"git -C {CWD}/.claude/worktrees/codex-gate-redesign log"),
    ("git --git-dir=subpath/.git",    f"git --git-dir={CWD}/.claude/worktrees/codex-gate-redesign/.git status"),
    ("git --work-tree=subpath",       f"git --work-tree={CWD}/.claude/worktrees/codex-gate-redesign diff"),
    ("git --git-dir subpath/.git",    f"git --git-dir {CWD}/.claude/worktrees/codex-gate-redesign/.git status"),
    ("cd cwd && git",                 f"cd {CWD} && git status"),
    ("cd cwd ; git",                  f"cd {CWD} ; git status"),
    ('cd "$PWD" && git',              'cd "$PWD" && git status'),
    ("cd . && git",                   "cd . && git status"),
]

ALLOW_CASES = [
    ("git -C different",              "git -C /home/achen status"),
    ("plain git status",              "git status"),
    ("cd different && git",           "cd /tmp && git status"),
    # `||` runs git only on cd FAILURE — not a redundant relocation.
    ("cd cwd || git",                 f"cd {CWD} || git status"),
    ("plain cd",                      "cd /tmp"),
    # Empty equal-form value: malformed git command, but realpath("") returns
    # cwd. Hook must not generate a misleading "points at cwd" deny for it.
    ("git --git-dir= status",         "git --git-dir= status"),
    ("git --work-tree= status",       "git --work-tree= status"),
    # cd to a subdir of cwd is genuine navigation, not a redundant relocation.
    # Hook only blocks `cd <cwd> && git ...`, not `cd <subdir> && git ...`.
    ("cd subdir && git",              f"cd {CWD}/.claude && git status"),
    ("cd worktree-subpath && git",    f"cd {CWD}/.claude/worktrees/codex-gate-redesign && git diff"),
]


def main() -> int:
    failures: list[str] = []

    for label, cmd in DENY_CASES:
        code, out = run(cmd)
        if code != 0:
            failures.append(f"FAIL [{label}]: non-zero exit {code}; cmd={cmd!r}")
            continue
        if not is_deny(out):
            failures.append(f"FAIL [{label}]: expected DENY, got ALLOW; cmd={cmd!r}; out={out!r}")

    for label, cmd in ALLOW_CASES:
        code, out = run(cmd)
        if code != 0:
            failures.append(f"FAIL [{label}]: non-zero exit {code}; cmd={cmd!r}")
            continue
        if is_deny(out):
            failures.append(f"FAIL [{label}]: expected ALLOW, got DENY; cmd={cmd!r}; out={out!r}")

    # Non-Bash tool: silent allow.
    code, out = run("ignored", tool="Edit")
    if code != 0 or out.strip():
        failures.append(f"FAIL [non-Bash]: expected silent allow; code={code}; out={out!r}")

    # Empty stdin: silent allow.
    result = subprocess.run([str(HOOK)], input="", capture_output=True, text=True, cwd=CWD)
    if result.returncode != 0 or result.stdout.strip():
        failures.append(f"FAIL [empty stdin]: expected silent allow; code={result.returncode}; out={result.stdout!r}")

    # Malformed JSON: silent allow (fail open).
    result = subprocess.run([str(HOOK)], input="not json", capture_output=True, text=True, cwd=CWD)
    if result.returncode != 0 or result.stdout.strip():
        failures.append(f"FAIL [malformed json]: expected silent allow; code={result.returncode}; out={result.stdout!r}")

    total = len(DENY_CASES) + len(ALLOW_CASES) + 3
    if failures:
        for f in failures:
            print(f)
        print(f"\n{len(failures)} of {total} cases failed.")
        return 1
    print(f"OK: all {total} cases passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
