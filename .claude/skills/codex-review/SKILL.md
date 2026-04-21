---
name: Codex Review
description: Run independent Codex CLI (GPT-5.4) code review in the background alongside your own self-review. Captures findings to a file and extracts only the verdict, keeping verbose exploration logs out of context.
when_to_use: When Andrew asks for a "review" or "full review" of a commit, branch, or uncommitted change. When you want an independent second opinion before declaring work done. Before pushing a PR, when project hooks don't already gate on codex.
version: 1.0.0
languages: all
---

# Codex Review

## Overview

`codex review` is the Codex CLI's review mode — an independent reviewer backed by GPT-5.4, running in a read-only sandbox. Start it in the background, self-review your own changes while it runs, then read only the final findings.

**Core principle:** run Codex and self-review in parallel. Don't wait on Codex to start reviewing your own work.

## Workflow

### 1. Start Codex in the background first

No permissions prompts are needed — Codex only reads the tree.

```bash
codex review --commit HEAD   # or --commit <sha>
```

Run this via Bash with `run_in_background: true`. Do it **before** you start self-reviewing so both streams overlap.

### 2. Self-review while Codex runs

While Codex is analyzing, review your own diff for correctness, edge cases, style. Don't just wait — the point of starting Codex first is to overlap the work.

### 3. Read findings when Codex completes

Capture the output to a file and extract only the findings block. **Do NOT** dump full Codex output into context — it contains verbose exploration logs.

**IMPORTANT:** Claude Code's Bash input filter blocks `$(...)` and backticks. Generate a unique filename yourself (e.g., `review-a1b2c3d4.txt` using a random hex string) before building the `tee` command; do not let the shell compute it via command substitution.

```bash
codex review --commit HEAD 2>&1 | tee ~/.codex-reviews/review-UNIQUE.txt
```

Then extract the findings:

```bash
grep -A200 '^codex$' ~/.codex-reviews/review-UNIQUE.txt | tail -n +2
```

The findings live after the last `^codex$` line. The earlier lines are the model's exploration trace — not useful in context.

If `tee` fails because `~/.codex-reviews/` does not exist, create it once:

```bash
mkdir -p ~/.codex-reviews
```

and retry.

## Review modes

Codex review has three modes. Pick based on what you need reviewed:

### Single commit
```bash
codex review --commit <sha>
```
Reviews exactly that one commit's diff against its parent.

### Branch diff
```bash
codex review --base <branch>
```
Reviews ALL changes on the current branch vs. the base branch, in one pass. Prefer this for multi-commit work — do NOT pass multiple `--commit` flags or invent range syntax. `--commit` takes exactly one SHA.

**Caveat:** `--base` uses `git merge-base` under the hood, which fails on shallow clones. Check first:

```bash
git rev-parse --is-shallow-repository
```

If shallow, either unshallow once (`git fetch --unshallow`, potentially large) or fall back to per-commit reviews.

### Uncommitted work
```bash
codex review --uncommitted
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
