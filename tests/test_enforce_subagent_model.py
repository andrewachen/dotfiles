#!/usr/bin/env python3
# ABOUTME: Test suite for .claude/hooks/enforce-subagent-model.py — pipes synthetic
# ABOUTME: PreToolUse JSON in and asserts deny/allow. Run: python3 tests/test_*.py.

import json
import subprocess
import sys
from pathlib import Path

HOOK = (
    Path(__file__).resolve().parent.parent
    / ".claude"
    / "hooks"
    / "enforce-subagent-model.py"
)


def run(payload: dict) -> tuple[int, str]:
    result = subprocess.run(
        [str(HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout


def run_raw(stdin: str) -> tuple[int, str]:
    result = subprocess.run(
        [str(HOOK)],
        input=stdin,
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout


def deny_reason(out: str) -> str | None:
    """Return the deny reason if the output is a deny decision, else None."""
    if not out:
        return None
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return None
    hso = data.get("hookSpecificOutput", {})
    if hso.get("permissionDecision") != "deny":
        return None
    return hso.get("permissionDecisionReason", "")


def agent(model=None, tool="Agent") -> dict:
    tool_input: dict = {"description": "do a thing", "prompt": "..."}
    if model is not None:
        tool_input["model"] = model
    return {"tool_name": tool, "tool_input": tool_input}


def workflow(script: str) -> dict:
    return {"tool_name": "Workflow", "tool_input": {"script": script}}


def main() -> int:
    failures: list[str] = []
    ran = 0  # counted, not hard-coded, so adding a case can't desync the summary

    def expect_allow(label: str, payload: dict):
        nonlocal ran
        ran += 1
        code, out = run(payload)
        if code != 0:
            failures.append(f"FAIL [{label}]: non-zero exit {code}")
            return
        if deny_reason(out) is not None:
            failures.append(f"FAIL [{label}]: expected ALLOW, got DENY; out={out!r}")

    def expect_deny(label: str, payload: dict, must_mention: str | None = None):
        nonlocal ran
        ran += 1
        code, out = run(payload)
        if code != 0:
            failures.append(f"FAIL [{label}]: non-zero exit {code}")
            return
        reason = deny_reason(out)
        if reason is None:
            failures.append(f"FAIL [{label}]: expected DENY, got ALLOW; out={out!r}")
            return
        if must_mention is not None and must_mention not in reason:
            failures.append(
                f"FAIL [{label}]: deny reason missing {must_mention!r}; reason={reason!r}"
            )

    # --- Agent / Task path ---
    expect_allow("Agent with model=haiku", agent(model="haiku"))
    expect_allow("Agent with model=sonnet", agent(model="sonnet"))
    expect_deny("Agent without model", agent(model=None), must_mention="model")
    expect_deny("Task alias without model", agent(model=None, tool="Task"))
    expect_allow("Task alias with model", agent(model="haiku", tool="Task"))
    # "inherit" is a deliberate, conscious choice — it passes.
    expect_allow("Agent with model=inherit", agent(model="inherit"))
    # Empty-string model is no choice at all — deny.
    expect_deny("Agent with empty model", agent(model=""))

    # --- Workflow script-lint path ---
    all_have_model = """
        phase('Build')
        const a = await agent('do x', {model: 'haiku', schema: S})
        const b = await agent('do y', {schema: S, model: "sonnet"})
    """
    expect_allow("Workflow all agents have model", workflow(all_have_model))

    one_missing = """
        const a = await agent('do x', {model: 'haiku'})
        const b = await agent('do y', {schema: S})
    """
    expect_deny("Workflow one agent missing model", workflow(one_missing), "do y")

    expect_allow("Workflow no agent calls", workflow("log('hello'); phase('x')"))

    # Multi-line agent() call with model: spread across lines → allow.
    multiline_ok = """
        const r = await agent(
            'a long prompt that wraps',
            {
                label: 'review',
                model: 'haiku',
                schema: FINDINGS,
            },
        )
    """
    expect_allow("Workflow multi-line agent with model", workflow(multiline_ok))

    # model: appears only inside the PROMPT STRING, not as an option → deny.
    model_in_string = """
        const r = await agent('pick a model: haiku or sonnet', {schema: S})
    """
    expect_deny("Workflow model only in prompt string", workflow(model_in_string), "agent(")

    # `subagent(` and other words ending in agent must not be treated as agent().
    not_agent = """
        const x = subagent('do x', {schema: S})
        const y = myagent('do y')
    """
    expect_allow("Workflow subagent/myagent not matched", workflow(not_agent))

    # Parens inside the prompt string must not unbalance span detection.
    parens_in_prompt = """
        const a = await agent('count the (nested) (parens) here', {schema: S})
        const b = await agent('next', {model: 'haiku'})
    """
    expect_deny("Workflow parens in prompt, first missing model", workflow(parens_in_prompt), "count the")

    # Realistic pipeline shape: nested agent() inside parallel(), all have model.
    nested_ok = """
        const results = await pipeline(
            DIMENSIONS,
            d => agent(d.prompt, {label: d.key, model: 'sonnet', schema: F}),
            review => parallel(review.findings.map(f => () =>
                agent('verify ' + f.title, {model: 'haiku', schema: V})
                    .then(v => ({...f, verdict: v}))
            ))
        )
    """
    expect_allow("Workflow nested pipeline all have model", workflow(nested_ok))

    # `agent(` inside a string literal (e.g. the meta description) is not a real
    # call and must not trip the lint — the one real call has a model.
    agent_in_string = """
        export const meta = {
            name: 'x',
            description: 'dispatches an agent() to do the work',
            phases: [{ title: 'Run' }],
        }
        const r = await agent('go', {model: 'haiku'})
    """
    expect_allow("Workflow agent( inside description string", workflow(agent_in_string))

    # A real model-less call still caught even when a string also says "agent(".
    string_plus_real = """
        export const meta = { name: 'x', description: 'spawns an agent() helper' }
        const r = await agent('go', {schema: S})
    """
    expect_deny("Workflow string mentions agent + real missing", workflow(string_plus_real), "go")

    # A `model:` must be the agent's OWN top-level option, not one nested in a
    # sibling config, an inline schema, or a nested agent() call. Otherwise the
    # model-less dispatch — the exact thing we block — slips through.
    nested_config = """
        const r = await agent('go', {schema: S, retry: {model: 'fallback'}})
    """
    expect_deny("Workflow model nested in sibling config", workflow(nested_config), "go")

    schema_model_field = """
        const r = await agent('extract', {schema: obj({model: int()})})
    """
    expect_deny("Workflow model is a schema field", workflow(schema_model_field), "extract")

    model_in_nested_call = """
        const r = await agent('go', mapFn({model: 'x'}))
    """
    expect_deny("Workflow model inside nested call arg", workflow(model_in_nested_call), "go")

    # Outer call is model-less; the inner (modeled) agent must not satisfy it.
    nested_agent_outer_missing = """
        const r = await agent('outer', {cb: () => agent('inner', {model: 'haiku'})})
    """
    expect_deny("Workflow nested agent, outer missing model", workflow(nested_agent_outer_missing), "outer")

    # Top-level model present alongside legitimate deeper nesting → allow.
    top_level_with_nesting = """
        const r = await agent('go', {model: 'haiku', opts: {retry: {model: 'x'}}})
    """
    expect_allow("Workflow top-level model + nested model", workflow(top_level_with_nesting))

    # `model:` appearing only inside a value string is not the option key.
    model_in_value_string = """
        const r = await agent('go', {label: 'use model: haiku', schema: S})
    """
    expect_deny("Workflow model only in a value string", workflow(model_in_value_string), "go")

    # Quoted option keys are valid JS and satisfy the requirement.
    quoted_key = """
        const r = await agent('go', {'model': 'haiku', schema: S})
    """
    expect_allow("Workflow single-quoted model key", workflow(quoted_key))

    double_quoted_key = """
        const r = await agent('go', {"model": "haiku"})
    """
    expect_allow("Workflow double-quoted model key", workflow(double_quoted_key))

    # A comment (even with an apostrophe) must not hide a following real call.
    comment_before_call = """
        // don't fan out — keep it cheap
        const r = await agent('go', {schema: S})
    """
    expect_deny("Workflow comment with apostrophe before model-less call", workflow(comment_before_call), "go")

    # A commented-out agent() doesn't count; the real call has a model → allow.
    commented_out_agent = """
        // old: agent('x', {schema: S})
        const r = await agent('go', {model: 'haiku'})
    """
    expect_allow("Workflow commented-out agent ignored", workflow(commented_out_agent))

    # Block comment containing agent() / model: is ignored.
    block_comment = """
        /* agent('x') with no model: here */
        const r = await agent('go', {model: 'haiku'})
    """
    expect_allow("Workflow block comment ignored", workflow(block_comment))

    # --- Fail-open / passthrough cases ---
    ran += 1
    code, out = run({"tool_name": "Bash", "tool_input": {"command": "ls"}})
    if code != 0 or out.strip():
        failures.append(f"FAIL [Bash passthrough]: expected silent allow; code={code}; out={out!r}")

    ran += 1
    code, out = run({"tool_name": "Edit", "tool_input": {"file_path": "/tmp/x"}})
    if code != 0 or out.strip():
        failures.append(f"FAIL [Edit passthrough]: expected silent allow; code={code}; out={out!r}")

    ran += 1
    code, out = run_raw("")
    if code != 0 or out.strip():
        failures.append(f"FAIL [empty stdin]: expected silent allow; code={code}; out={out!r}")

    ran += 1
    code, out = run_raw("not json")
    if code != 0 or out.strip():
        failures.append(f"FAIL [malformed json]: expected silent allow; code={code}; out={out!r}")

    # Agent with tool_input entirely absent → fail-open allow (malformed shape).
    ran += 1
    code, out = run({"tool_name": "Agent"})
    if code != 0:
        failures.append(f"FAIL [Agent no tool_input]: non-zero exit {code}")
    elif deny_reason(out) is None:
        # No tool_input means no model → this SHOULD deny like any model-less Agent.
        failures.append(f"FAIL [Agent no tool_input]: expected DENY, got ALLOW; out={out!r}")

    total = ran
    if failures:
        for f in failures:
            print(f)
        print(f"\n{len(failures)} of {total} cases failed.")
        return 1
    print(f"OK: all {total} cases passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
