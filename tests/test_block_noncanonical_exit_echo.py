#!/usr/bin/env python3
# ABOUTME: Test suite for .claude/hooks/block-noncanonical-exit-echo.py — pipes
# ABOUTME: synthetic PreToolUse JSON in and asserts deny/allow. Run: python3 tests/test_*.py.

import json
import subprocess
import sys
from pathlib import Path

HOOK = (
    Path(__file__).resolve().parent.parent
    / ".claude"
    / "hooks"
    / "block-noncanonical-exit-echo.py"
)
CWD = "/home/achen/git/gh/dotfiles"


def run(cmd: str, tool: str = "Bash") -> tuple[int, str]:
    payload: dict = {"tool_name": tool, "cwd": CWD}
    if tool == "Bash":
        payload["tool_input"] = {"command": cmd}
    else:
        payload["tool_input"] = {"file_path": "/tmp/x"}
    result = subprocess.run(
        [str(HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        cwd=CWD,
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


# Every variant of echoing a previous command's exit code that is NOT the exact
# canonical `echo "EXIT=$?"` re-registers as a distinct permission rule.
DENY_CASES = [
    ("bare echo $?",                  "echo $?"),
    ("lowercase label",               'echo "exit=$?"'),
    ("unquoted canonical label",      "echo EXIT=$?"),
    ("colon label",                   'echo "Exit: $?"'),
    ("rc label",                      'echo "rc=$?"'),
    ("status sentence",               'echo "status: $?"'),
    ("double space before arg",       'echo  "EXIT=$?"'),
    ("compound &&, lowercase",        'make build && echo "exit=$?"'),
    ("compound ;, bare",              "pytest ; echo $?"),
    ("compound ;, bare no space",     "pytest;echo $?"),
    ("after pipe",                    "false | echo $?"),
    ("single quotes wrong label",     "echo 'rc=$?'"),
    # bashlex raises ParsingError on `[[ ]]` and array assignments; the regex
    # fallback must still catch the trailing non-canonical echo in these.
    ("[[ ]] then bad echo",           '[[ -f x ]] && echo "exit=$?"'),
    ("array assign then bad echo",    "arr=(a b) ; echo $?"),
    # Compound bodies live in a list-typed `.list`; the walker must descend in.
    ("brace group bad echo",          "{ echo $?; }"),
    ("subshell bad echo",             "( echo $? )"),
    ("if-then bad echo",              "if true; then echo $?; fi"),
    # `${?}` is the braced equivalent of `$?` — still an exit-code echo.
    ("braced param bare",             'echo "${?}"'),
    ("braced param labelled",         'cmd ; echo "exit=${?}"'),
    ("braced canonical label",        'echo "EXIT=${?}"'),
]

ALLOW_CASES = [
    ("canonical alone",               'echo "EXIT=$?"'),
    ("canonical in &&",               'make build && echo "EXIT=$?"'),
    ("canonical after ;",             'pytest ; echo "EXIT=$?"'),
    ("echo without exit code",        'echo "hello world"'),
    ("echo a normal var",             'rc=$?; echo "rc is $rc"'),
    ("exit code via exit, not echo",  "exit $?"),
    ("exit code via test, not echo",  "test $? -eq 0"),
    ("assign to var, no echo",        "rc=$?"),
    ("unrelated git",                 "git status"),
    # `echoed=...` / `echoes ...` must not match the `echo` word.
    ("echo-prefixed word assign",     "echoed=$?"),
    # Heredocs carry literal script content; skip them entirely rather than
    # false-block a generated script line.
    ("heredoc with echo $?",          "cat > s.sh <<'EOF'\necho \"rc=$?\"\nEOF"),
    # Canonical echo still allowed even when an earlier `[[ ]]` forces the
    # regex-fallback path.
    ("[[ ]] then canonical echo",     '[[ -f x ]] && echo "EXIT=$?"'),
    # bashlex folds a trailing redirect into the command node's span; the
    # canonical echo must stay allowed when redirected.
    ("canonical with redirect",       'echo "EXIT=$?" > /dev/null'),
    ("canonical with 2>&1",           'echo "EXIT=$?" 2>&1'),
    ("canonical in brace group",      '{ echo "EXIT=$?"; }'),
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
