---
name: Codex Review
description: Run independent Codex CLI (GPT-5.4) code review in the background alongside your own self-review. Captures findings to a file and extracts only the verdict, keeping verbose exploration logs out of context.
when_to_use: When Andrew asks for a "review" or "full review" of a commit, branch, or uncommitted change. When you want an independent second opinion before declaring work done. Before pushing a PR, when project hooks don't already gate on codex.
version: 2.0.0
languages: all
---

# Codex Review

## Overview

`codex review` is the Codex CLI's review mode — an independent reviewer backed by GPT-5.4, running in a read-only sandbox. Start it in the background, self-review your own changes while it runs, then read only the final verdict.

**Core principle:** run Codex and self-review in parallel. Don't wait on Codex to start reviewing your own work.

## Workflow

Use the `codex-review-capture` wrapper (in `~/bin/`, installed from the dotfiles repo). It runs `codex review` with your args, captures the full transcript to a `/tmp/codex-review.*` file (owner-only, cleaned on reboot), and prints ONLY the verdict (content after the last `^codex$` marker) to stdout. The full transcript path is printed to stderr in case you need to dig into it.

### 1. Start the wrapper in the background

Codex only reads the working tree, so no permission prompts are needed beyond the single `Bash(codex-review-capture *)` allowlist rule.

```bash
codex-review-capture --commit HEAD
```

Run this via Bash with `run_in_background: true`. Do it **before** you start self-reviewing so both streams overlap.

### 2. Self-review while the wrapper runs

While Codex is analyzing, review your own diff for correctness, edge cases, style. Don't just wait — the point of starting Codex first is to overlap the work.

### 3. Read the verdict when the background task completes

Read the background task's stdout directly — it contains only the verdict, no exploration trace. If you need the full transcript, the path is in the task's stderr (`codex-review-capture: full transcript -> ...`).

## Review modes

Pass whatever flags you would pass to `codex review` directly. The wrapper forwards `"$@"` verbatim.

### Single commit
```bash
codex-review-capture --commit <sha>
```
Reviews exactly that one commit's diff against its parent.

### Branch diff
```bash
codex-review-capture --base <branch>
```
Reviews ALL changes on the current branch vs. the base branch, in one pass. Prefer this for multi-commit work — do NOT pass multiple `--commit` flags or invent range syntax. `--commit` takes exactly one SHA.

**Caveat:** `--base` uses `git merge-base` under the hood, which fails on shallow clones. Check first:

```bash
git rev-parse --is-shallow-repository
```

If shallow, either unshallow once (`git fetch --unshallow`, potentially large) or fall back to per-commit reviews.

### Uncommitted work
```bash
codex-review-capture --uncommitted
```
Reviews ALL uncommitted changes. Codex may fixate on whichever change it finds biggest and skim the rest.

For a targeted review of uncommitted files, commit or stash unrelated work first. A worktree with a temporary commit is ideal for reviewing a single file or plan — Codex runs in a read-only sandbox and can only see files in the git working tree, so non-tracked drafts are invisible unless committed on a scratch branch.

## What to do with findings

Treat Codex findings as a second opinion, not an oracle. Evaluate each finding against:
- Is it correct? (Codex can hallucinate.)
- Does it apply given context Codex lacked?
- Is it a style nit or a real defect?

Triage: fix real defects now; document stylistic disagreements; ignore obvious misreads.

## When project hooks enforce it

Some projects gate push on a successful `codex review`. If there's no hook, Codex review is optional but available on request. Always run it when Andrew explicitly asks for a "review" or "full review".
