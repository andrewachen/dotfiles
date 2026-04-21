# dotfiles

Andrew's dotfiles, forked from [obra/dotfiles](https://github.com/obra/dotfiles).

## Claude Code install

Skills and `CLAUDE.md` live under `.claude/`. Install them into `~/.claude/` with per-category symlinks so this repo stays the source of truth:

```bash
cd "$(git rev-parse --show-toplevel)"

ln -sf "$PWD/.claude/CLAUDE.md" ~/.claude/CLAUDE.md

for s in architecture coding collaboration debugging meta testing codex-review java-style; do
  ln -sf "$PWD/.claude/skills/$s" "$HOME/.claude/skills/$s"
done
```

This coexists with any other skill dirs (plugin skills, Netflix-managed skills) already under `~/.claude/skills/`.

### Why symlinks, not a single `~/.claude/skills/` symlink?

Your existing `~/.claude/skills/` may already contain skill directories installed by other tooling (Netflix-managed, Google Workspace, etc.). A single top-level symlink would displace them. Per-top-level-category symlinks keep everything coexisting under the same parent.

### Upstream superpowers

The skills under `architecture/`, `coding/`, `collaboration/`, `debugging/`, `meta/`, and `testing/` originate in [obra/clank](https://github.com/obra/clank) and are the pre-move (2025-10) snapshot from this repo's history. The productized version of the same ideas is the [obra/superpowers](https://github.com/obra/superpowers) Claude Code plugin; consider installing that for ongoing updates and replacing these local copies if drift becomes an issue.
