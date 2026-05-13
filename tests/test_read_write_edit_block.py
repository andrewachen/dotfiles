#!/usr/bin/env python3
# ABOUTME: Test suite for .claude/hooks/read-write-edit-block.py — pipes synthetic
# ABOUTME: PreToolUse JSON in and asserts deny/allow. Run: python3 tests/test_*.py.

import json
import subprocess
import sys
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / ".claude" / "hooks" / "read-write-edit-block.py"
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
    # cat <single-file> -> Read
    ("cat plain",                    "cat foo.txt"),
    ("cat absolute path",            "cat /tmp/x.log"),
    ("cat relative path",            "cat ./foo.txt"),
    ("cat in subdir compound",       "ls /tmp; cat foo.txt"),
    ("cat after &&",                 "echo done && cat foo.txt"),

    # head [-n N | -N] <file> -> Read with limit
    ("head plain",                   "head foo.txt"),
    ("head -n 20",                   "head -n 20 foo.txt"),
    ("head -20",                     "head -20 foo.txt"),

    # sed -n 'N[,M]p' <file> -> Read with offset/limit
    ("sed -n single line",           "sed -n '5p' foo.txt"),
    ("sed -n range",                 "sed -n '5,10p' foo.txt"),
    ("sed -n range no quotes",       "sed -n 5,10p foo.txt"),
    ("sed -n range absolute path",   "sed -n '140,160p' /tmp/foo"),

    # sed -i '<sub>' <file> -> Edit
    ("sed -i substitute",            "sed -i 's/old/new/' foo.txt"),
    ("sed -i with g flag",           "sed -i 's/old/new/g' foo.txt"),
    ("sed -i pipe delimiter",        "sed -i 's|a|b|' foo.txt"),

    # echo ... > <file> -> Write ;  echo ... >> <file> -> Edit
    ("echo redirect",                "echo hello > foo.txt"),
    ("echo redirect quoted",         'echo "hi there" > foo.txt'),
    ("echo append",                  "echo hello >> foo.txt"),
    ("echo append quoted",           'echo "line two" >> foo.txt'),
    ("echo explicit fd1 redirect",   "echo hello 1> out"),

    # Quote-aware splitter: separators inside quoted strings stay in the
    # argument; the outer command still matches a clean replacement.
    ("echo quoted semicolon",        "echo 'a;b' > foo.txt"),
    ("echo dq quoted ampersand",     'echo "a&&b" > foo.txt'),
    ("sed -i pipe inside script",    "sed -i 's|x|y;z|' foo.txt"),

    # Newline as a command separator (bash treats `\n` like `;`).
    ("cat after newline",            "ls /tmp\ncat foo.txt"),
]

ALLOW_CASES = [
    # Multi-file / pipe / redirect cases that have no Read/Write/Edit equivalent.
    ("cat multi-file",               "cat a.txt b.txt"),
    ("cat with flag",                "cat -n foo.txt"),
    ("cat pipe",                     "cat foo.txt | grep x"),
    ("cat redirect",                 "cat foo.txt > bar.txt"),
    ("cat heredoc",                  "cat <<EOF"),
    ("cat stdin",                    "cat - < foo.txt"),
    ("cat command sub",              "cat $(printf foo)"),
    ("cat backtick",                 "cat `printf foo`"),

    # Parameter expansions can't be replicated by Read/Write (the tool needs
    # a literal path / literal content), so they no longer get misdirected.
    ("cat parameter",                "cat $foo"),
    ("cat braced parameter",         "cat ${VAR}"),
    ("echo redirect var",            "echo $X > foo.txt"),
    ("echo redirect quoted var",     'echo "$X" > foo.txt'),
    ("echo redirect mixed var",      'echo "hello $X" > foo.txt'),
    ("echo redirect cmdsub",         "echo $(cmd) > foo.txt"),
    ("head parameter",               "head $file"),
    ("sed -n parameter file",        "sed -n '5p' $file"),
    # Non-stdout fd redirects: Write only writes echo's stdout, so an explicit
    # fd 2 / fd N / &> destination is not a clean Write/Edit case.
    ("echo redirect to stderr",      "echo hello 2> err"),
    ("echo redirect to fd10",        "echo hello 10> log"),
    ("echo redirect both",           "echo hello &> out"),
    # Command substitution with internal `;`: the inner separator must stay
    # inside the substitution. (Today this is allowed by an accident of the
    # custom splitter mis-splitting; bashlex makes it principled.)
    ("cat cmdsub internal semicolon", "cat $(echo a;b)"),

    # head: multi-file, byte count, follow, pipe — no clean Read mapping.
    ("head multi-file",              "head a.txt b.txt"),
    ("head byte count",              "head -c 100 foo.txt"),
    ("head pipe",                    "head foo.txt | grep x"),

    # tail / awk: no clean Read/Edit/Write mapping at all — never blocked.
    ("tail follow",                  "tail -f log.txt"),
    ("tail -n",                      "tail -n 10 foo.txt"),
    ("awk plain",                    "awk '{print}' foo.txt"),
    ("awk sum",                      "awk '{sum+=$1} END {print sum}' data"),

    # sed without -i/-n (transformation print) -> not a Read/Edit case.
    ("sed plain transform",          "sed 's/x/y/' foo.txt"),
    ("sed -E transform",             "sed -E 's/x/y/' foo.txt"),

    # sed -n with non-numeric range or regex -> Read can't replicate.
    ("sed -n regex pattern",         "sed -n '/pattern/p' foo.txt"),
    ("sed -n to end",                "sed -n '5,$p' foo.txt"),
    ("sed -n multi range",           "sed -n '1,5p;10,15p' foo.txt"),

    # sed -n / sed -i with pipe or multi-file — no clean mapping.
    ("sed -n piped",                 "sed -n '5p' foo.txt | grep x"),
    ("sed -i multi-file",            "sed -i 's/x/y/' a.txt b.txt"),
    ("sed -i multi -e",              "sed -i -e 'cmd1' -e 'cmd2' foo.txt"),

    # echo without redirect — just printing to stdout, no Write/Edit mapping.
    ("echo no redirect",             "echo hello"),
    ("echo pipe",                    "echo hello | grep h"),
    ("echo to var",                  'X=$(echo hi)'),

    # echo flags change semantics Write can't replicate (-n suppresses newline,
    # -e interprets backslash escapes). Skip rather than mis-direct to Write.
    ("echo -n redirect",             "echo -n hi > foo.txt"),
    ("echo -e redirect",             'echo -e "a\\nb" > foo.txt'),
    ("echo -ne redirect",            "echo -ne hi > foo.txt"),

    # echo with no content writes a single newline; Write of "" is 0 bytes.
    ("echo empty redirect",          "echo > foo.txt"),
    ("echo empty quoted",            'echo "" > foo.txt'),

    # Other commands entirely.
    ("plain ls",                     "ls /tmp"),
    ("plain pwd",                    "pwd"),
    ("git status",                   "git status"),

    # printf — not handled (format-string semantics differ from echo).
    ("printf redirect",              "printf 'foo\\n' > out.txt"),
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
