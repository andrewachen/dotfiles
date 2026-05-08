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

`CLAUDE.md` and Andrew's personal skills (`codex-review`, `java-style`) live in this repo. Install them into `~/.claude/` with symlinks:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/skills

ln -sf "$PWD/.claude/CLAUDE.md" ~/.claude/CLAUDE.md

for s in codex-review java-style; do
  ln -sf "$PWD/.claude/skills/$s" "$HOME/.claude/skills/$s"
done
```

This coexists with the Superpowers plugin skills and any other skill dirs under `~/.claude/skills/`.

### Helper scripts: symlink from ~/bin

Scripts under `bin/` are meant to live on `PATH` via `~/bin/`:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/bin

for b in bin/*; do
  ln -sf "$PWD/$b" "$HOME/bin/$(basename "$b")"
done
```

- `codex-review-capture` — wrapper around `codex review` used by the `codex-review` skill. Captures the full transcript to `/tmp/codex-review.*` (owner-only, cleaned on reboot) and prints only the verdict (content after the last `^codex$` marker) to stdout.

### Hooks: symlink from this repo, wire into settings.json

`PreToolUse` hooks live under `.claude/hooks/`. Symlink them into `~/.claude/hooks/`:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p ~/.claude/hooks

for h in block-git-dash-c.py; do
  ln -sf "$PWD/.claude/hooks/$h" "$HOME/.claude/hooks/$h"
done
```

Then merge `.claude/settings.git-dash-C-example.json` into `~/.claude/settings.json` to wire the hook into the harness. `~/.claude/settings.json` is intentionally NOT symlinked — it carries machine-specific env vars that don't belong in the repo.

- `block-git-dash-c.py` — denies `git -C <cwd>`, `git --git-dir <cwd>/.git`, `git --work-tree <cwd>`, and `cd <cwd> && git ...`. All trigger unnecessary sandbox approval prompts when the path resolves to the current working directory; CLAUDE.md tells Claude not to do this, but the soft prompt was unreliable. The hook is hard enforcement: a deny with a `permissionDecisionReason` short-circuits the prompt and Claude retries without the redundant relocation. Tests live under `tests/`.
