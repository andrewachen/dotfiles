---
name: python-style
description: Andrew's personal Python tooling rules — uv for package management, pyparse for syntax checks. Additive to the generic python-context skill.
when_to_use: When writing, running, or checking Python code. When installing or managing Python dependencies. When creating Python scripts or deciding how to run them.
version: 1.0.0
languages: python
---

# Python Style

## Overview

Personal tooling rules beyond what the generic python-context skill covers.

## Package management

- Prefer `uv` for Python package management: `uv run <script>` to execute, `uv add <pkg>` to install; no `requirements.txt`.

## Syntax checks

- For Python syntax checks use `pyparse FILE` (wrapper around `ast.parse`, no `.pyc` side effects); avoid `python3 -c 'import ast; ast.parse(...)'` one-liners and `python3 -m py_compile` (writes `__pycache__/` litter).
