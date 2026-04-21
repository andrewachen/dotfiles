# dotfiles

Andrew's dotfiles, forked from [obra/dotfiles](https://github.com/obra/dotfiles).

## Claude Code install

### Recommended skills: install the Superpowers plugin

Most of the skills referenced by `.claude/CLAUDE.md` (test-driven-development, systematic-debugging, writing-plans, brainstorming, verification-before-completion, etc.) come from the [`obra/superpowers`](https://github.com/obra/superpowers) plugin. Install it from the official marketplace:

```
/plugin install superpowers@claude-plugins-official
```

This is the actively maintained version (v5.0.7+). Skills evolve there faster than in any fork.

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
