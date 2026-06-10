# dotfiles

Andrew's dotfiles, forked from [obra/dotfiles](https://github.com/obra/dotfiles).

## Claude Code install

### Required: install the Superpowers plugin

The [`obra/superpowers`](https://github.com/obra/superpowers) plugin is a hard dependency of this config, not a recommendation. `CLAUDE.md` and the personal skills in this repo assume its skills are loaded — test-driven-development, systematic-debugging, writing-plans, brainstorming, verification-before-completion, and others are referenced directly. Without it, the workflow breaks.

Install it from the official marketplace before anything else:

```
/plugin install superpowers@claude-plugins-official
```

Use the actively maintained version (v5.0.7+). Skills evolve there faster than in any fork.

### Personal skills + CLAUDE.md: symlink from this repo

`CLAUDE.md` and Andrew's personal skills (`java-style`, `grip-review`) live in this repo. Install them into `~/.claude/` with symlinks:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/skills

ln -sf "$PWD/.claude/CLAUDE.md" ~/.claude/CLAUDE.md

for s in java-style grip-review; do
  ln -sf "$PWD/.claude/skills/$s" "$HOME/.claude/skills/$s"
done
```

This coexists with the Superpowers plugin skills and any other skill dirs under `~/.claude/skills/`.

The grip-review skill also needs its SessionEnd hook symlinked:

```bash
mkdir -p ~/.claude/hooks
ln -sf "$PWD/.claude/hooks/cleanup-grip.sh" "$HOME/.claude/hooks/cleanup-grip.sh"
```

Then merge `.claude/settings.grip-review-example.json` into your live `~/.claude/settings.json` (the live file is intentionally not tracked; the example shows the allow rule and the SessionEnd hook entry to add).

### Helper scripts: symlink from ~/bin

Scripts under `bin/` are meant to live on `PATH` via `~/bin/`:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/bin

for b in bin/*; do
  ln -sf "$PWD/$b" "$HOME/bin/$(basename "$b")"
done
```

- `codex-review-capture` — wrapper around `codex review` used by the [codex pre-push gate](#optional-codex-pre-push-gate) below. Captures the full transcript to `/tmp/codex-review.*` (owner-only, cleaned on reboot) and prints only the verdict (content after the last `^codex$` marker) to stdout.
- `pyparse` — syntax-checks Python files via `ast.parse`, with no `.pyc` / `__pycache__` litter (unlike `python3 -m py_compile`). `pyparse FILE [FILE ...]`.
- `screen` — compatibility wrapper that maps common GNU `screen` invocations to `tmux`.

### Hooks at a glance

The Claude Code hooks in `.claude/hooks/`. All are opt-in: each is a script you symlink into `~/.claude/hooks/`, plus a checked-in `settings.*-example.json` you merge into your live `settings.json`. Details and install steps are in the sections below.

| Hook | Event — matcher | What it does |
|------|-----------------|--------------|
| [`enforce-subagent-model.py`](#optional-enforce-an-explicit-model-on-every-subagent-dispatch) | PreToolUse — `Agent`/`Task`/`Workflow` | Deny a subagent dispatch with no explicit `model` |
| [`block-git-dash-c.py`](#optional-bash-behavior-nudge-hooks) | PreToolUse — `Bash(git */cd *)` | Block redundant `git -C` / `cd <cwd> && git …` |
| [`read-write-edit-block.py`](#optional-bash-behavior-nudge-hooks) | PreToolUse — `Bash(cat/head/sed/echo *)` | Nudge single-file `cat`/`head`/`sed`/`echo` to Read/Write/Edit |
| [`codex-gate.sh`](#optional-codex-pre-push-gate) (+ `codex-gate-pass.sh`) | PreToolUse `git push`/`gh pr create` + PostToolUse | Block a push/PR until a `codex review` ran on the diff |

(`cleanup-grip.sh`, a `SessionEnd` hook that kills leftover grip servers, belongs to the grip-review skill and is covered with it above.)

### Optional: codex pre-push gate

`bin/codex-review-capture` and the hooks in `.claude/hooks/` together implement a per-project gate that blocks `git push` and `gh pr create` until a `codex review` has run with a recognized mode flag in the same Claude Code session, and re-blocks if the diff has changed since.

Flow:
1. The model runs `codex-review-capture --commit <sha>` (or `--base <branch>`, or `--uncommitted`). The wrapper detects the mode and computes `(BASE, HASH)` for exactly the diff codex sees, *before* invoking codex (so a long-running review can't be raced by working-tree edits). On `rc=0` the wrapper leaves a staged file at `/tmp/codex-gate-staged-${UID}-${repo}-${pid}` and prints `staged=<path>` to stderr.
2. `codex-gate-pass.sh` (PostToolUse, only fires on success) reads the staged path from `tool_response.stderr` and renames the file to a session-keyed sentinel `/tmp/codex-gate-${SESSION_ID}-${repo}`.
3. `codex-gate.sh` (PreToolUse on `git push *` / `gh pr create *`) recomputes `git diff BASE` against the current tree, compares to the stored hash, and either consumes the sentinel and allows the push or exits 2 with a message.

Caveats:
- The hooks are opt-in per project. Each project that wants the gate references the scripts from its own `.claude/settings.local.json`.
- `codex-review-capture --uncommitted` requires a clean untracked state. If untracked files are present, the wrapper fails closed with a stderr message asking you to `git add` them first. This avoids index mutation and keeps the gate's verification logic simple.
- `codex-review-capture` without a mode flag does not write a sentinel — the gate fails closed.
- `--commit X` reviews only commit X's diff. The gate then checks that the working tree at push time produces the same diff vs `X^`, but it does NOT verify that only X is being pushed. For multi-commit branches, prefer `--base <branch>` to review the full unpushed range.

Install the hook scripts once:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks

for h in codex-gate.sh codex-gate-pass.sh; do
  ln -sf "$PWD/.claude/hooks/$h" "$HOME/.claude/hooks/$h"
done
```

Activate the gate in a project by merging the contents of [`.claude/hooks/settings.local.example.json`](.claude/hooks/settings.local.example.json) into that project's `.claude/settings.local.json`. The example uses each hook entry's `if` field (permission-rule syntax) so the scripts only spawn for the gated commands — no overhead on every Bash call.

### Optional: bash behavior-nudge hooks

Two PreToolUse hooks that redirect Bash invocations to the dedicated tool when one would do the same job better:

- `block-git-dash-c.py` — denies `git -C/--git-dir/--work-tree <path-in-cwd>` and `cd <cwd> && git ...`. Both defeat Claude Code's auto-allow matcher for read-only git subcommands and force needless permission prompts.
- `read-write-edit-block.py` — denies single-file `cat`/`head`/`sed`/`echo` invocations covered by Read/Write/Edit. Skips pipes, multi-file, sed scripts, echo flags (`-n`/`-e`), and other shapes the dedicated tools can't replicate.

Install the scripts:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks

for h in block-git-dash-c.py read-write-edit-block.py; do
  ln -sf "$PWD/.claude/hooks/$h" "$HOME/.claude/hooks/$h"
done
```

Activate per-machine by merging entries from [`.claude/settings.git-dash-C-example.json`](.claude/settings.git-dash-C-example.json) and [`.claude/settings.read-write-edit-block-example.json`](.claude/settings.read-write-edit-block-example.json) into `~/.claude/settings.json`. Both examples use narrow `if: Bash(<cmd> *)` matchers so the hooks only run for the relevant commands.

### Optional: enforce an explicit model on every subagent dispatch

`enforce-subagent-model.py` is a PreToolUse hook that denies a subagent dispatch with no explicit `model`, so the choice is never left to silent inheritance of the session model. A dispatch with no `model` inherits the session model (often Opus) even when a mechanical, fully-specified task would run fine on a cheaper tier. The hook makes the choice conscious at dispatch time — any explicit model passes, including `"inherit"` if you genuinely want the session model.

- **`Agent` / `Task`** — denied when `tool_input.model` is absent/falsy.
- **`Workflow`** — the launch is denied when any `agent(` call in `tool_input.script` lacks a top-level `model` option (bare `model:` or quoted `'model':`). This is a best-effort static text lint of the JavaScript: string/template-literal contents and `//` / `/* */` comments are blanked first, so an `agent(`/`model:` inside a prompt, description, or comment doesn't fool it, and a `model:` nested in a sibling config, an inline schema, or a nested `agent()` call doesn't satisfy the outer call. Known gaps (all err toward *allowing* — a missed deny, never a wrongful block): regex literals (`/.../`) aren't recognized, so a quote inside one can blank a following call; and a `model` supplied via a variable or spread isn't seen. It enforces *presence* of a model, never *correctness of tier*.

The hook fails open: malformed input or an unexpected shape allows the dispatch — a hook bug must never block work.

Install the script:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks
ln -sf "$PWD/.claude/hooks/enforce-subagent-model.py" "$HOME/.claude/hooks/enforce-subagent-model.py"
```

Activate per-machine by merging [`.claude/settings.enforce-subagent-model-example.json`](.claude/settings.enforce-subagent-model-example.json) into `~/.claude/settings.json`. It adds `Agent`, `Task`, and `Workflow` matcher entries to `hooks.PreToolUse` (no `if` field — these match the whole tool, not a Bash sub-command).
