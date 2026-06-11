#!/usr/bin/env python3
# ABOUTME: PreToolUse hook forcing an explicit `model` on subagent dispatches —
# ABOUTME: denies model-less Agent/Task calls and Workflow scripts with bare agent().

import json
import re
import sys

HOOK_EVENT = "PreToolUse"

# Match a call to the global `agent(` function in a Workflow script. The negative
# lookbehind for `.` and word chars excludes method calls (`x.agent(`) and longer
# identifiers (`subagent(`, `myagent(`). `\s*` tolerates `agent (`.
AGENT_CALL = re.compile(r"(?<![.\w])agent\s*\(")
# The dispatch model option key, as the property name in the options object:
# bare `model:` or quoted `'model':` / `"model":`. `\b` keeps `submodel:` out.
MODEL_KEY = re.compile(r"""(?:\bmodel|(['"])model\1)\s*:""")


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


def skip_string(s: str, i: int) -> int:
    """Index just past the string literal opening at s[i] (a ' " or ` quote),
    honouring backslash escapes. Returns len(s) if the string is unterminated."""
    quote = s[i]
    i += 1
    n = len(s)
    while i < n:
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == quote:
            return i + 1
        i += 1
    return n


def blank_code(script: str) -> str:
    """Length-preserving copy of the script with the contents of string/template
    literals and `//` / `/* */` comments replaced by spaces (newlines kept so
    line numbers stay accurate). Blanking means an `agent(`, a `model:`, or a
    paren that appears only inside a string or a comment is invisible to the
    lint — it can neither be mistaken for a call nor unbalance paren matching,
    and (critically) an apostrophe in a comment like `// don't` can't open a
    phantom string that hides the next real call.

    Heuristic limit: regex literals (`/.../`) are not recognised, so a quote or
    paren inside one is mis-read. JS regex-vs-division can't be disambiguated
    without a full lexer; this is documented and errs toward allowing.
    """
    out = []
    i = 0
    n = len(script)
    while i < n:
        two = script[i:i + 2]
        if two == "//":
            while i < n and script[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if two == "/*":
            while i < n and script[i:i + 2] != "*/":
                out.append("\n" if script[i] == "\n" else " ")
                i += 1
            out.append("  "[: min(2, n - i)])  # blank the closing */
            i += 2
            continue
        if script[i] in ("'", '"', "`"):
            end = skip_string(script, i)
            for j in range(i, end):
                out.append("\n" if script[j] == "\n" else " ")
            i = end
            continue
        out.append(script[i])
        i += 1
    return "".join(out)


def matching_paren(text: str, open_idx: int) -> int:
    """Index of the `)` matching the `(` at open_idx (len(text) if unmatched)."""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return len(text)


def has_own_model(inner: str) -> bool:
    """True if the agent() argument text has the dispatch `model` option as a
    *top-level* key of its options object — i.e. at paren-depth 0, brace-depth 1.
    A `model:` nested in a sibling config, an inline schema, a nested agent()
    call, a value string, or a comment does not count. Bare and quoted keys
    (model: / 'model': / "model":) both qualify."""
    paren = brace = 0
    i = 0
    n = len(inner)
    while i < n:
        two = inner[i:i + 2]
        if two == "//":
            j = inner.find("\n", i)
            i = n if j == -1 else j
            continue
        if two == "/*":
            j = inner.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        c = inner[i]
        if c in ("'", '"', "`"):
            if paren == 0 and brace == 1 and MODEL_KEY.match(inner, i):
                return True  # quoted top-level key, e.g. {'model': ...}
            i = skip_string(inner, i)
            continue
        if paren == 0 and brace == 1 and MODEL_KEY.match(inner, i):
            return True
        if c == "(":
            paren += 1
        elif c == ")":
            paren -= 1
        elif c == "{":
            brace += 1
        elif c == "}":
            brace -= 1
        i += 1
    return False


def find_modelless_agents(script: str) -> list[str]:
    """Return a one-line snippet per agent() call lacking a top-level model option."""
    blanked = blank_code(script)  # indices stay aligned with `script`
    offenders = []
    for m in AGENT_CALL.finditer(blanked):
        open_idx = m.end() - 1  # index of the '(' the regex consumed
        close = matching_paren(blanked, open_idx)
        if not has_own_model(script[open_idx + 1:close]):
            line = script.count("\n", 0, m.start()) + 1
            snippet = script[m.start():].splitlines()[0][:80]
            offenders.append(f"line {line}: {snippet}")
    return offenders


def main() -> None:
    data = json.load(sys.stdin)
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input") or {}

    if tool_name in ("Agent", "Task"):
        if not tool_input.get("model"):
            deny(
                "This subagent dispatch has no explicit `model`, so it silently "
                "inherits the session model (Opus). Choose the cheapest model that "
                "can do the job — default to \"haiku\" and step up only when the "
                "task demonstrably needs it:\n"
                "  - \"haiku\": THE DEFAULT. Mechanical, fully-specified work — "
                "grep/search, reading a known file, a localized edit, running a "
                "command, summarizing output. If you can describe the exact steps, "
                "use haiku.\n"
                "  - \"sonnet\": genuine code comprehension or judgment haiku "
                "would get wrong — writing non-trivial new code, reviewing a diff "
                "for correctness, a cross-file refactor, debugging a non-localized "
                "cause, reasoning about unfamiliar code to answer a question. Name "
                "why haiku is insufficient before choosing it; but don't starve a "
                "task that needs it — a haiku run that botches comprehension work "
                "just gets redone on sonnet, costing more than starting here.\n"
                "  - \"opus\": hard reasoning, ambiguous design, subtle debugging.\n"
                "Picking sonnet \"to be safe\" is the mistake this hook exists to "
                "catch — most subagent tasks are haiku work. If you truly want the "
                "session model, pass `model: \"inherit\"` to say so explicitly."
            )
        sys.exit(0)

    if tool_name == "Workflow":
        offenders = find_modelless_agents(tool_input.get("script", ""))
        if offenders:
            listing = "\n".join(f"  - {o}" for o in offenders)
            deny(
                "This Workflow script has agent() call(s) with no `model` option, "
                "so each spawned subagent silently inherits the session model "
                "(Opus). Add a `model:` to each, defaulting to the cheapest model "
                "that can do the job:\n"
                "  - 'haiku': THE DEFAULT for mechanical, fully-specified work "
                "(search, reading a known file, a localized edit, summarizing). "
                "Most workflow fan-out is haiku work.\n"
                "  - 'sonnet': genuine code comprehension or judgment haiku would "
                "get wrong — writing non-trivial code, reviewing a diff, a "
                "cross-file refactor, debugging a non-localized cause. Name why "
                "haiku won't do; but don't starve a stage that needs it — a botched "
                "haiku run just gets redone on sonnet.\n"
                "  - 'opus': hard reasoning, ambiguous design, subtle debugging.\n"
                "Use {model: 'inherit'} to opt into the session model on purpose:\n"
                + listing
            )
        sys.exit(0)

    # Any other tool: not our concern.
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open: a hook bug must never block a dispatch. Malformed/empty
        # stdin, unexpected shapes, etc. all land here and allow.
        sys.exit(0)
