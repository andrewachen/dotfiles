---
name: grip-review
description: Serve a Markdown file (plan, spec, design doc) via ~/bin/grip on a non-localhost URL so Andrew can review it from any device on his LAN. Use whenever a superpowers skill (brainstorming spec review, writing-plans plan review, executing-plans checkpoint, etc.) asks Andrew to review a `.md` file. Returns a URL; print it on its own line before asking for review.
when_to_use: Any time you are about to ask Andrew to review a markdown plan or spec file produced by a superpowers skill — the moment before you ask "please review", run this skill against the file path, then include the URL in your prompt to Andrew.
version: 1.0.0
languages: bash
---

# grip-review

## Overview

Serves a markdown file via the local `~/bin/grip` wrapper, which binds `go-grip` to Andrew's LAN-visible IP. The URL it returns is reachable from any device on his network, so reviews don't require sitting at this machine.

The skill encapsulates all process and file management in a single helper script (`serve.sh`) so one Bash allowlist entry covers everything: state-dir creation, PID-file writes, prior-grip kill, port allocation, grip launch, URL extraction. No additional prompts.

## When to invoke

At every superpowers review gate that asks Andrew to read a `.md` file:
- brainstorming's spec-review gate
- writing-plans's plan-review gate
- executing-plans's checkpoint gates
- any other "please review this markdown" moment from a superpowers skill

Do NOT invoke for arbitrary markdown files unrelated to superpowers reviews. Do NOT invoke for code review (that's a different flow).

## How to invoke

Run the helper with the absolute path to the markdown file:

```bash
/home/achen/.claude/skills/grip-review/serve.sh /absolute/path/to/file.md
```

The script prints a single URL to stdout on success (e.g. `http://<lan-ip>:6531/path/to/file.md`). Pipe that URL into your review prompt to Andrew, e.g.:

> "Plan written to `<path>`. View it at `<URL>`. Let me know what to change."

On failure the script exits non-zero and prints a diagnostic to stderr. If that happens, fall back to asking Andrew to read the file directly.

## Lifecycle

One grip per session at a time, PID + host + port + directory tracked at `~/.cache/claude-grip/$CLAUDE_CODE_SESSION_ID.pid`. A SessionEnd hook (`~/.claude/hooks/cleanup-grip.sh`) reaps the final grip at session end.

go-grip serves every `.md` under the launch directory at its relative URL path, so if a second review gate asks Andrew to read a sibling file, this skill skips relaunch and just emits a URL like `http://<lan-ip>:<port>/<sibling>.md` pointing at the already-running grip. Both URLs stay live and auto-reload still works. Only a file in a different directory triggers kill-and-relaunch.
