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

`CLAUDE.md` and Andrew's personal skills (`java-style`, `grip-review`, `e2e-scenario-testing`) live in this repo. Install them into `~/.claude/` with symlinks:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/skills

ln -sf "$PWD/.claude/CLAUDE.md" ~/.claude/CLAUDE.md

for s in java-style grip-review e2e-scenario-testing; do
  ln -sf "$PWD/.claude/skills/$s" "$HOME/.claude/skills/$s"
done
```

This coexists with the Superpowers plugin skills and any other skill dirs under `~/.claude/skills/`. `e2e-scenario-testing` (merged from upstream) verifies a running app through its real interface via agent-run scenario cards; see [`docs/e2e-scenario-testing.md`](docs/e2e-scenario-testing.md) for when and how to use it. The many other upstream skills under `.claude/skills/` (roborev, obsidian, windows-vm, …) are left unsymlinked and inert.

### Slash commands: symlink the whole dir from this repo

Unlike skills (which must coexist with the Superpowers plugin under `~/.claude/skills/`, so they're symlinked per-skill), the commands dir has no such neighbor — symlink the whole thing, and every command in this repo is wired at once:

```bash
cd "$(git rev-parse --show-toplevel)"
ln -sfn "$PWD/.claude/commands" "$HOME/.claude/commands"
```

- `/par` — dispatches two subagents to review your work adversarially, competing to find the most legitimate issues (disqualified for BS or inflated severity). A lightweight, model-internal mid-task review; complements the heavier `reviewers:codex` / `reviewers:bitbot` completion gate.
- `/story-loop` — drives a repo to a known-good state by cataloguing every capability as `e2e-scenario-testing` cards, then looping test → fix → re-test. Pairs with the `e2e-scenario-testing` skill.

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
| [`enforce-subagent-model.py`](#optional-enforce-an-explicit-model-on-every-subagent-dispatch) | PreToolUse — `Agent`/`Task`/`Workflow` | Deny a subagent dispatch with no explicit `model` (except frontmatter-pinned `local-*` agents) |
| [`block-git-dash-c.py`](#optional-bash-behavior-nudge-hooks) | PreToolUse — `Bash(git */cd *)` | Block redundant `git -C` / `cd <cwd> && git …` |
| [`block-git-add-all.py`](#optional-bash-behavior-nudge-hooks) | PreToolUse — `Bash(git *)` | Block bulk `git add -A`/`--all`/`.`/`./`/`*` |
| [`read-write-edit-block.py`](#optional-bash-behavior-nudge-hooks) | PreToolUse — `Bash(cat/head/sed/echo *)` | Nudge single-file `cat`/`head`/`sed`/`echo` to Read/Write/Edit |
| [`block-docker-root.py`](#optional-block-docker-containers-running-as-root) | PreToolUse — `Bash(docker */docker-compose *)` | Deny `docker run`/`exec`/`create`/`compose run`/`compose exec` lacking a non-root `--user` |
| [`codex-gate.sh`](#optional-codex-pre-push-gate) (+ `codex-gate-pass.sh`) | PreToolUse `git push`/`gh pr create` + PostToolUse | Block a push/PR until a `codex review` ran on the diff |
| [`edit-mismatch-hint.py`](#optional-hint-the-exact-region-when-an-edit-anchor-misses) | `PostToolBatch` (no matcher) | On an Edit rejected with "String to replace not found", inject the likeliest-match line number and exact `Read(offset, limit)` parameters as context |

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

Three PreToolUse hooks that steer Bash invocations toward better-behaved forms — the dedicated Read/Write/Edit tools, cleaner git usage, or explicit staging:

- `block-git-dash-c.py` — denies `git -C/--git-dir/--work-tree <path-in-cwd>` and `cd <cwd> && git ...`. Both defeat Claude Code's auto-allow matcher for read-only git subcommands and force needless permission prompts.
- `read-write-edit-block.py` — denies single-file `cat`/`head`/`sed`/`echo` invocations covered by Read/Write/Edit. Skips pipes, multi-file, sed scripts, echo flags (`-n`/`-e`), and other shapes the dedicated tools can't replicate.
- `block-git-add-all.py` — denies bulk `git add` (`-A`, `--all`, `.`, `./`, `*`) that sweeps untracked scratch/litter into the index. Allows explicit paths, `git add <dir>/`, targeted globs (`*.py`), and `-u`. Parses with bashlex; fail-open.

Install the scripts:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks

for h in block-git-dash-c.py read-write-edit-block.py block-git-add-all.py; do
  ln -sf "$PWD/.claude/hooks/$h" "$HOME/.claude/hooks/$h"
done
```

Activate per-machine by merging entries from [`.claude/settings.git-dash-C-example.json`](.claude/settings.git-dash-C-example.json), [`.claude/settings.read-write-edit-block-example.json`](.claude/settings.read-write-edit-block-example.json), and [`.claude/settings.block-git-add-all-example.json`](.claude/settings.block-git-add-all-example.json) into `~/.claude/settings.json`. The examples use narrow `if: Bash(<cmd> *)` matchers so the hooks only run for the relevant commands.

### Optional: block docker containers running as root

`block-docker-root.py` is a PreToolUse Bash hook that denies `docker run`, `docker exec`, `docker create`, their `docker container …` aliases, and `docker compose run`/`exec` (and `docker-compose …`) when they lack an explicit **non-root numeric** `--user` — because those default to running the container process as **root** (uid 0), which writes root-owned files into mounted volumes and has broad host-mount access. Allowed: a non-zero numeric uid (`--user 1000`, `--user 65532`) or `--user $(id -u):$(id -g)`. Denied: no `--user`, `--user 0`/`root`, or a username (a name isn't proof of a non-root uid). The deny message steers Claude to `--user $(id -u):$(id -g)` or to hand you the exact command to run manually.

It parses docker's real option grammar with bashlex (per-subcommand value-flag tables, short-flag getopt), so a `--user` belonging to the in-container command isn't mistaken for docker's, and it makes no subprocess calls. Unlike the behavior-nudge hooks it **fails closed**: a parse failure or hook error denies a docker command in command position (but never a non-docker call that merely mentions `docker`).

**This is best-effort accident-prevention, not a security boundary.** Being in the `docker` group already grants host-root via the socket, so a shell hook can't stop a determined caller; it stops the ordinary mistake of running a container as root without thinking. Known gaps (by design): `docker start`/`restart` and `compose up`/`start`/`restart` (no CLI `--user`), invocations that don't begin with the bare command (`DOCKER_HOST=x docker …`, `/usr/bin/docker …`, `env docker …`), shell-expansion injection, non-default daemons, and flag-table drift. See the design spec for the full list.

Install the script:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks
ln -sf "$PWD/.claude/hooks/block-docker-root.py" "$HOME/.claude/hooks/block-docker-root.py"
```

Activate per-machine by merging [`.claude/settings.block-docker-root-example.json`](.claude/settings.block-docker-root-example.json) into `~/.claude/settings.json`. It uses two `if: Bash(docker *)` / `Bash(docker-compose *)` matchers so the hook only runs for docker commands.

### Optional: enforce an explicit model on every subagent dispatch

`enforce-subagent-model.py` is a PreToolUse hook that denies a subagent dispatch with no explicit `model`, so the choice is never left to silent inheritance of the session model. A dispatch with no `model` inherits the session model (often Opus) even when a mechanical, fully-specified task would run fine on a cheaper tier. The hook makes the choice conscious at dispatch time — any explicit model passes, including `"inherit"` if you genuinely want the session model (with one exception for `local-*` agents, below).

- **`Agent` / `Task`** — denied when `tool_input.model` is absent/falsy. **Exception:** when `subagent_type` starts with `local-`, the rule inverts. Such agents pin a full gateway model id in their frontmatter (a value CC's dispatch `model` enum won't accept), and that frontmatter only takes effect when the dispatch is model-less. So a model-less `local-*` dispatch is *allowed*, and a `local-*` dispatch *with* any `model` param (a tier, or `inherit`) is *denied* — the param would override the frontmatter and silently route the work to the cloud instead of the local gateway model. The hook trusts the `local-` prefix: it can't read frontmatter, so a `local-*` agent that omits `model:` in its own frontmatter would slip through — acceptable because this hook is a routing/cost nudge, not a data-residency guarantee (it fails open).
- **`Workflow`** — the launch is denied when any `agent(` call in the workflow script lacks a top-level `model` option (bare `model:` or quoted `'model':`). The script is read from inline `tool_input.script`, or from `tool_input.scriptPath` (the `.js` file on disk) when the launch points at one — file-launched workflows like deep-research carry their agents only there, and `scriptPath` is what actually runs, so it takes precedence over any stale inline `script`. This is a best-effort static text lint of the JavaScript: string/template-literal contents and `//` / `/* */` comments are blanked first, so an `agent(`/`model:` inside a prompt, description, or comment doesn't fool it, and a `model:` nested in a sibling config, an inline schema, or a nested `agent()` call doesn't satisfy the outer call. Known gaps, because this is a text lint rather than a JS parser: a `name`-launched saved/built-in workflow has no inline or file script to lint (a missed deny); a `model` supplied via a variable or spread isn't recognized as present, so such a call is *wrongly denied*; and regex literals (`/.../`) aren't recognized, so a quote inside one can blank following text — either hiding a call (a missed deny) or blanking a real `model:` option (a wrongful block). The wrongful-block cases are recoverable: write a literal `model:` (e.g. `model: 'haiku'`) at the call site. It enforces *presence* of a model, never *correctness of tier*.

The hook fails open: malformed input or an unexpected shape allows the dispatch — a hook bug must never block work.

Install the script:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks
ln -sf "$PWD/.claude/hooks/enforce-subagent-model.py" "$HOME/.claude/hooks/enforce-subagent-model.py"
```

Activate per-machine by merging [`.claude/settings.enforce-subagent-model-example.json`](.claude/settings.enforce-subagent-model-example.json) into `~/.claude/settings.json`. It adds `Agent`, `Task`, and `Workflow` matcher entries to `hooks.PreToolUse` (no `if` field — these match the whole tool, not a Bash sub-command).

### Optional: hint the exact region when an Edit anchor misses

`edit-mismatch-hint.py` is a `PostToolBatch` hook (no matcher — it filters internally). When a batch contains an Edit that failed with "String to replace not found", it finds the likeliest region in the target file and injects recovery context: the 1-based line number, the similarity, and the **exact** `Read(file_path, offset, limit)` parameters for the region (pad 2), plus instructions to copy `old_string` verbatim from that Read (stripping the `<lineno>\t` prefixes) and prefer a small unique snippet. "Likeliest", not "closest": the region is chosen by verbatim-line seeding plus ranked refinement, and on files dense with repeated boilerplate it can be wrong — the hint's Read instruction is what makes that recoverable.

Why `PostToolBatch` and not `PreToolUse`: verified against CC 2.1.309, Edit's `validateInput` rejects a not-found anchor **before** PreToolUse/PostToolUseFailure hooks run, so a PreToolUse hook can never see the failure this targets — and would only ever see already-matching edits, where its plain substring check diverges from CC's normalization (curly quotes, UTF-16) and would falsely deny valid Edits. `PostToolBatch` sees the rejected call with the error in `tool_response`, and its `additionalContext` reaches the model (verified end-to-end). Because it only injects context and never denies, it cannot reject an Edit; a pathological file can only delay the batch within the compute budget (per-comparison product cap, per-hint char budget, 5-hint/8-attempt batch caps, and a 5s wall-clock deadline). The event schema, error string, and `additionalContext` behavior are versioned compatibility dependencies on CC 2.1.309 — re-verify with the probe method after CC upgrades. Steady-state cost of the matcher-less wiring is ~30ms per batch (measured). Generic-only advice (never opening the file) was considered and rejected: the measured failure loop — 18 identical blind retries to compact — happened precisely because self-chosen re-Reads never re-exposed the failing region, which is what the exact `offset`/`limit` prescription fixes.

Design rulings baked in: the hint **never echoes file bytes** — content reaches the model only through the permissioned Read tool, even in the generic branch; it never silently rewrites the anchor (`updatedInput` auto-repair was considered and rejected); only the real string error form counts as a failure, with the not-found marker required **directly after** the `<tool_use_error>` tag, so an ambiguity rejection whose echoed anchor contains the marker text ("Found 2 matches … String: String to replace not found") can't masquerade as not-found, and a dict response serializing the marker inside a successful edit's content can't match either; it fails open everywhere (bad JSON, internal errors → silence; an unreadable transcript degrades to the generic advice, which injects no file metadata). The scan is bounded: snapshots > 5000 lines or anchors > 100 lines skip to generic advice, candidate windows are seeded rarity-first from verbatim anchor lines (boilerplate lines can't flood the budget), short fully-drifted anchors (≤ 5 lines) get a budget-bounded pruned scan, and every char-level comparison plus the whole hint is capped (per-comparison 200k chars, per-hint 300k, 5 hints per batch) — measured worst case ~0.5s. **Ambiguity policy**: a specific offset requires distinctive evidence or a heuristic margin over the refined candidates, and the recommendation is always to narrow the anchor — never `replace_all`, which could silently widen a single-target edit to every occurrence.

**Authorization gate (transcript-derived, snapshot-only).** Line numbers and similarity scores are content-derived metadata — without a gate, a failed Edit against a Read-denied path would let repeated probes measure the file (a content oracle), and PostToolBatch sees Edits rejected *before* any Read permission ran. The hook payload carries `transcript_path`, and the session transcript is Claude Code's own durable read-state: CC's `extractReadFilesFromMessages` rebuilds its in-memory `readFileState` map from exactly these records (verified in the 2.1.303 binary), so the hook reuses CC's own state instead of maintaining a parallel ledger. It parses the transcript tail once per batch (8 MiB bound, deadline-checked, fails closed) and collects, per path, every successful disclosure: a Read `tool_use` joined by `tool_use_id` to a non-errored `tool_result` (see the next paragraph for which content counts as the disclosure), the tool_use input path cross-bound against the result's own `filePath`. Sidechain records are skipped.

The design is **snapshot-only**: the hint is computed purely from that disclosed content; the current file is never opened, and its path is never resolved against the filesystem (path identity is lexical and absolute-paths-only — `normpath`, `~`/`~/` expanded via `$HOME`; `~user`, relative paths, and any `..` component stay unmatched, because `realpath` can block on automounts and lexically collapsing `..` can change meaning across symlinked components). Disclosure proof is exact: only the **visible** `tool_result` numbered dump counts for Reads — exactly the bytes the model saw. The structured `toolUseResult` internal copy is never treated as disclosure (it may retain bytes the rendering truncated), and dump-reconstructed snapshots are treated as partial for the uniqueness exemption. A transcript with no uuids at all offers no proof it was never rewound or concatenated — fail closed to generic; branched transcripts trust only the last record's ancestry. Spellings rejected by the lexical identity (relative, `~user`, `..`) are never recorded under a shared fallback key. Line numbers and similarity can only re-describe what the session already saw, never probe present state. Range-limited Reads carry `startLine`, so hint coordinates and the `Read(offset, limit)` prescription stay in absolute file coordinates; the newest disclosures are tried first (up to 3 per path, older ones labeled "an earlier Read"). Write snapshots come from the model-authored `tool_input.content` (a post-write hook may transform the result), accepted on both `create` and `update` results. Freshness has one coherent model: an anchor that is verbatim in any retained view yet was just rejected proves that view is stale (newest such view wins), so the hint names the anchor's old location (abstaining to generic advice if it occurs more than once in that view) and prescribes a **broad** re-Read covering the whole old anchor plus 25 lines of pad per side — the 100-line anchor cap applies before this classification; an approximate anchor gets the likeliest window from the newest view, labeled "based on your last view" — and if the file drifted, the permissioned Read it prescribes is what shows the model the current truth. Everything else degrades to generic Read advice with no file access at all: no disclosure in the transcript, errored Reads (CC skips them too), empty `transcript_path` (served calls, disabled transcripts), missing transcript file.

Residuals, deliberately accepted: the gate trusts the transcript file's integrity — an existing trust root CC itself maintains; a same-uid process can forge or alter records, which adds no new exposure beyond what editing the transcript already grants. A successful **Edit** does not produce a snapshot (its `old_string`/`new_string` prove knowledge of only those fragments, and replaying CC's match semantics to reconstruct the file is not worth the risk), so after an un-Read mutation the hint is computed from the pre-Edit snapshot and labeled accordingly. A full-file Read of a file longer than CC's Read page (~2000 lines) records a truncated snapshot, so specific hints are effectively limited to files CC Reads whole (`MAX_FILE_LINES` is a cap, not a promise). Uniqueness is measured within one snapshot: for range-limited or dump-reconstructed (treated partial) snapshots the distinctive-evidence exemption is disabled, so only the similarity margin protects against a twin region hidden outside the range — the residual wrong-region risk of heuristic matching, bounded by the ambiguity policy but not eliminated. The tail bound means disclosures older than 8 MiB of transcript are forgotten (safe direction), and multiple partial Reads are not merged into a coverage map — an anchor spanning two ranges falls back to generic advice. Lexical path identity means a Read recorded under a different spelling (symlink vs real path) does not cross-match an Edit spelled the other way — generic advice, the safe direction. Hooks running inside a subagent see only the parent transcript, so a subagent's own Reads don't authorize its hints (generic; safe direction) — `isSidechain` records are skipped outright. The transcript is opened with `O_NOFOLLOW` and fstat'ed on the same descriptor. The deadline remains a cooperative checkpoint; the settings entry adds a host-enforced 10s hook `timeout` as the outer ceiling, so a blocked open or an oversized single parse cannot stall the batch beyond that. It closes accidental metadata flow, not an adversarial boundary — the gate's failure direction is toward *less* disclosure.

Install the scripts:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks
ln -sf "$PWD/.claude/hooks/edit-mismatch-hint.py" "$HOME/.claude/hooks/edit-mismatch-hint.py"
```

Activate per-machine by merging [`.claude/settings.edit-mismatch-hint-example.json`](.claude/settings.edit-mismatch-hint-example.json) into `~/.claude/settings.json` (or the settings file of the profile you want it on, e.g. `~/.claude-personal/settings.json`). It carries only the matcher-less `PostToolBatch` entry for the hint hook, which filters to failed Edits itself; the authorization gate needs no separate hook — it reads the session transcript via the `transcript_path` every hook payload carries.
