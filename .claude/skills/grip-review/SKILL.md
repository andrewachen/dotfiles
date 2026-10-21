---
name: grip-review
description: Serve a Markdown file (plan, spec, design doc) via ~/bin/grip on a non-localhost URL so Andrew can review it from any device on his LAN. Use whenever a superpowers skill (brainstorming spec review, writing-plans plan review, executing-plans checkpoint, etc.) asks Andrew to review a `.md` file. Returns a URL; print it on its own line before asking for review.
when_to_use: Any time you are about to ask Andrew to review a markdown plan or spec file produced by a superpowers skill — the moment before you ask "please review", run this skill against the file path, then include the URL in your prompt to Andrew.
version: 1.1.0
languages: bash
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/escape-currency-dollars.py *)
---

# grip-review

## Overview

Serves a markdown file via the local `~/bin/grip` wrapper, which binds `go-grip` to Andrew's LAN-visible IP. The URL it returns is reachable from any device on his network, so reviews don't require sitting at this machine.

The skill encapsulates all process and file management in a single helper script (`serve.sh`) so one Bash allowlist entry covers everything: state-dir creation, PID-file tracking, dead-grip pruning, live-grip reuse, port allocation, grip launch, URL construction. No additional prompts.

## When to invoke

At every superpowers review gate that asks Andrew to read a `.md` file:
- brainstorming's spec-review gate
- writing-plans's plan-review gate
- executing-plans's checkpoint gates
- any other "please review this markdown" moment from a superpowers skill

Do NOT invoke for arbitrary markdown files unrelated to superpowers reviews. Do NOT invoke for code review (that's a different flow).

## How to invoke

**REQUIRED first step — escape currency dollars.** go-grip's MathJax extension pairs any two `$` characters in one block (paragraph, list item, table cell, heading) as `$...$` inline math. Currency amounts like `$1,200 ... $3,400` therefore render as a long italic TeX span and swallow any `**bold**`/`*emphasis*` between them. Before serving, run the bundled escaper on the file (allowlisted via this skill's `allowed-tools`, so it runs without a permission prompt):

```bash
python3 ${CLAUDE_SKILL_DIR}/escape-currency-dollars.py /absolute/path/to/file.md
```

It edits the file in place, escaping every `$` followed by a digit as `\$`, and prints `<file>: N escapes`. Fenced code blocks, indented code blocks, and single-line inline code spans pass through untouched (a backslash there would display literally); multi-line and multi-backtick code spans are not recognized, and real math like `$x^2$` is deliberately left alone (no digit follows the opening `$`). The script is idempotent — re-running it is always safe. If the file is version-controlled, the escapes are part of the document now; commit them along with the doc.

**Check the rest of the served tree; escape only what is in scope.** go-grip serves every markdown under the entry file's directory (for `docs/superpowers/specs|plans` files, the common `docs/superpowers/` ancestor), and Andrew can click through to any sibling — each one renders live with the same math bug. But do NOT bulk-rewrite the directory: unrelated files must not be modified without cause. Instead, scan the served root with the read-only mode:

```bash
python3 ${CLAUDE_SKILL_DIR}/escape-currency-dollars.py --check <served-root-dir>
```

It lists every affected file and its count without writing anything (directory arguments are always read-only; only single named files are rewritten). Then use judgment with a deterministic scope: escape the entry file (always) plus any sibling directly linked from it or explicitly named by Andrew for this review. Run the escaper on those individually and leave the rest untouched; mention affected-but-out-of-scope files to Andrew instead of silently rewriting them.

Run the helper with the absolute path to the markdown file:

```bash
/home/achen/.claude/skills/grip-review/serve.sh /absolute/path/to/file.md
```

The script prints a single URL to stdout on success (e.g. `http://<lan-ip>:6831/path/to/file.md`). Pipe that URL into your review prompt to Andrew, e.g.:

> "Plan written to `<path>`. View it at `<URL>`. Let me know what to change."

On failure the script exits non-zero and prints a diagnostic to stderr. If that happens, fall back to asking Andrew to read the file directly.

**Run the helper for EVERY file you want reviewed.** Never reuse a URL the helper printed for a different file, and never hand-build a URL from a host/port you saw earlier — even if you believe a grip is "already serving that directory." The script decides whether to reuse a live grip or launch a new one; that decision is its job, not yours. Re-run it and use exactly the URL it prints.

## Lifecycle

go-grip roots an HTTP file server at the directory of the path it's given and serves that whole subtree (every `.md` rendered, live from disk). This skill exploits that to keep multiple docs live at once.

A session can hold several grips — one per directory tree being served — tracked one line per grip (`PID STARTTIME HOST PORT ROOT`) at `~/.cache/claude-grip/$CLAUDE_CODE_SESSION_ID.pid`. Each `serve.sh` run reuses a live grip only when its root exactly matches the root the file would get, and otherwise launches a new grip on a fresh port. **It never kills a running grip to serve a different directory**, so a spec served earlier stays live while you serve its plan. A SessionEnd hook (`~/.claude/hooks/cleanup-grip.sh`) reaps every grip at session end.

The superpowers workflow writes specs to `docs/superpowers/specs/` and plans to `docs/superpowers/plans/` — different directories under a shared ancestor. For files in either, the skill roots a single grip at the common `docs/superpowers/` ancestor, so the spec is served at `…/specs/<file>.md` and the plan at `…/plans/<file>.md` by the **same** daemon. Andrew can keep both open at the same time; both auto-reload. Any other markdown is served from its own directory.
