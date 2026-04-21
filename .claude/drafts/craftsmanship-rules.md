# Craftsmanship rules — parked

Candidate rules kept out of active config. Not loaded as a skill; not in
CLAUDE.md. Promote any of these (to a `craftsmanship` skill or to the
Personal preferences block of `.claude/CLAUDE.md`) if an air-pocket shows
up during coding sessions.

These five were the highest-value rules from obra's 2025-10 `coding/` and
`architecture/` skill set that superpowers dropped and CLAUDE.md doesn't
already cover.

## 1. Single-purpose variables

Don't reuse a variable name for semantically different values over its
lifetime. If the meaning changes, introduce a new name.

```python
# Bad — `result` holds two different things
result = fetch_user(id)
result = result.profile.display_name

# Good
user = fetch_user(id)
display_name = user.profile.display_name
```

## 2. Localize variable declarations

Declare variables close to their first use, not at the top of the scope.
Short lifetimes make code easier to follow and easier to extract.

## 3. Keep routines focused

If a function grows a third branch, a fourth parameter, or a second
unrelated responsibility, consider splitting it before adding more. Small
single-purpose routines compose better than one growing megafunction.

## 4. Explore alternatives before committing

When there's more than one reasonable approach, state the main options in
one or two sentences each and pick deliberately rather than defaulting to
the first idea. For code: different data structures, different boundary
cuts, different coupling shapes.

## 5. Refactor safely

When refactoring, keep tests passing between every micro-step. Commit each
green state. If a step can't be done while keeping tests green, it's
probably two steps masquerading as one.

## When to promote

Symptoms suggesting one of these should become active:
- Reviewing code and noticing the same anti-pattern repeatedly
- Refactor sessions that balloon scope or break tests for long stretches
- Functions growing past ~50 lines without pushback
- Andrew flags "the model keeps doing X" where X matches one of the rules

## Source

Distilled from the 2025-10 snapshot of obra/clank's `coding/` and
`architecture/` skill directories, filtered to rules that (a) CLAUDE.md
doesn't already cover, (b) superpowers doesn't cover elsewhere, and
(c) change model behavior meaningfully rather than restating defaults.
