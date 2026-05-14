#!/usr/bin/env bash
# ABOUTME: PreToolUse hook blocking the gated tool call unless a codex sentinel
# ABOUTME: with a matching diff hash exists. Caller filters via hook `if` field.

set -euo pipefail

# JSON extraction goes through python3 (bashlex via `uv run` handles the
# push-intent parsing below). A jq fast-path for trivial field extraction
# isn't worth the dual-implementation cost when python3 has to be present
# anyway.
if ! command -v python3 >/dev/null 2>&1; then
  echo "codex-gate: requires python3 to parse hook input" >&2
  exit 1
fi
_json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], sys.argv[2]))' "$1" "${2:-}"; }
_tool_command() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("tool_input") or {}).get("command")) or "")'; }

# sha256sum is GNU-only; macOS ships shasum -a 256 instead.
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256 | cut -d' ' -f1; }
else
  echo "codex-gate: requires sha256sum or shasum" >&2
  exit 1
fi

INPUT=$(cat)
CWD=$(echo "$INPUT" | _json_get cwd)

COMMAND=$(echo "$INPUT" | _tool_command)
# Determine push/PR-create intent. Claude Code's `if: "Bash(<pattern>)"` matcher
# fails open (fires every if-filtered hook) on commands it can't segment
# (while/until/for loops, multi-line forms, complex quoting), so this hook
# receives Bash calls that aren't pushes at all. We parse the command with
# bashlex (an actual bash grammar parser, run under `uv` with an inline
# dependency) and walk the AST recursively, recognizing git/gh subcommands
# after stripping known global options.
#
# Safety stance: when the intent is ambiguous (unknown global option,
# unparseable bash, anything we can't classify) we FAIL CLOSED -- fall
# through to the sentinel check rather than guess. Over-firing the gate is
# recoverable (user runs `codex-review-capture`); a false-allow on a real
# push is not.
#
# Exit codes: 0 = confidently no push/PR-create intent (allow), 1 = intent
# found or ambiguous (fall through to sentinel check). If `uv` is missing
# we also fall through, since we have no way to parse confidently. `uv run`
# caches bashlex after the first invocation, so cold-start network access is
# a one-time cost; an offline-with-empty-cache run falls through to the gate
# (false-block on non-push commands -- recoverable via codex-review-capture).
if [[ -n "$COMMAND" ]] && command -v uv >/dev/null 2>&1; then
  # --no-project: don't try to resolve the surrounding project's pyproject.toml.
  # The bashlex parser only needs `bashlex` (via --with). When the gate fires
  # in a project whose pyproject can't be resolved (platform-conditional deps
  # absent from PyPI, etc.), the implicit project sync fails and the parser
  # never runs, falling the gate through to the sentinel check and over-gating
  # benign commands.
  if echo "$COMMAND" | uv run --no-project --with bashlex --quiet python3 -c '
import sys
import bashlex
import bashlex.errors

command = sys.stdin.read()

# Known global options for git and gh. Anything outside these whitelists
# triggers fail-closed (the segment is treated as having unclear intent and
# falls through to the sentinel check). Adding a new git/gh global option
# in a future release will manifest as a false-block, which is recoverable;
# the alternative (assume-boolean) caused false-ALLOWS on valued options.
GIT_BOOLEAN = {
    "-h", "--help", "--version", "-p", "--paginate", "-P", "--no-pager",
    "--bare", "--html-path", "--man-path", "--info-path",
    "--no-replace-objects", "--literal-pathspecs", "--glob-pathspecs",
    "--noglob-pathspecs", "--icase-pathspecs", "--no-optional-locks",
}
GIT_VALUED = {
    "-c", "-C", "--git-dir", "--work-tree", "--exec-path", "--namespace",
    "--config-env", "--super-prefix", "--list-cmds", "--attr-source",
}
GH_BOOLEAN = {"-h", "--help", "--version"}
GH_VALUED = {"-R", "--repo", "--hostname"}

# Passthrough wrappers that delegate to a real command. Each wrapper has its
# own option grammar (env -i / -u, nice -n N, sudo -u user, command -p, ...),
# so rather than try to parse each one we switch to a loose adjacency search
# (`git push` or `gh ... pr create` as adjacent words) for the remainder of
# the segment once a wrapper is recognized.
PASSTHROUGH = {"env", "command", "nohup", "nice", "ionice", "chronic",
               "setsid", "stdbuf", "tsp", "sudo", "doas", "exec"}

# Shell wrappers that interpret `-c <body>` as a sub-script. We recursively
# parse the body looking for push intent.
SHELL_C_WRAPPERS = {"bash", "sh", "dash", "zsh", "ksh", "ash", "busybox"}

# `eval` concatenates its argument words with spaces and runs the result as
# shell code. Handled like SHELL_C_WRAPPERS but the body is the args joined
# together rather than the value of a -c flag.
EVAL_WRAPPERS = {"eval"}

def word_pairs(cmd_node):
    """Return [(literal_string, is_dynamic), ...] for the word parts of a
    bashlex CommandNode. A word is dynamic if it has sub-parts (parameter
    expansion, command substitution, tilde, etc.) -- the literal `.word`
    text is what bashlex captured pre-expansion; the actual runtime value
    is unknowable from the AST alone, so we treat such positions as
    ambiguous in `is_push_command`."""
    out = []
    for p in cmd_node.parts:
        if getattr(p, "kind", None) == "word":
            out.append((p.word, bool(getattr(p, "parts", None))))
    return out

def skip_options(pairs, boolean_set, valued_set):
    """Skip a leading run of known options. Return remaining pairs, or None
    if intent is ambiguous: an unknown option, a dynamic word in option
    position, or a dynamic value for a known valued option (the value might
    word-split and shift the subcommand position)."""
    i = 0
    while i < len(pairs):
        t, dyn = pairs[i]
        if dyn:
            return None  # dynamic in option position -> ambiguous
        if not t.startswith("-"):
            return pairs[i:]
        if t == "--":
            return pairs[i+1:]
        if t in boolean_set:
            i += 1
        elif t in valued_set:
            if i + 1 < len(pairs) and pairs[i+1][1]:
                return None  # dynamic value -> may word-split, ambiguous
            i += 2
        elif "=" in t and t.split("=", 1)[0] in valued_set:
            i += 1  # --name=value form is one token
        else:
            return None  # unknown option
    return []

def find_shell_c_body(pairs):
    """Look for a `-c <body>` argument pair. `-c` may be exact, or bundled
    with other short flags (`-lc`, `-ec`, `-cv`, etc.) -- bash treats any
    short-flag bundle containing `c` as taking a body in the next arg.
    Returns the body string for a literal body; None for ambiguous (dynamic
    body, dynamic option position, or `-c` with no following arg); False
    if there'"'"'s no `-c` at all."""
    for i in range(len(pairs)):
        t, dyn = pairs[i]
        if dyn:
            return None  # dynamic option position -> ambiguous
        if t == "--":
            return False  # end of options, no -c found
        if t.startswith("-") and not t.startswith("--") and "c" in t[1:]:
            if i + 1 >= len(pairs):
                return None  # -c with no body
            body_str, body_dyn = pairs[i+1]
            if body_dyn:
                return None
            return body_str
    return False

def walk_body_for_push(body):
    """Parse `body` as shell code and check whether any command inside is a
    push/PR-create. Used for shell `-c <body>` arguments and `eval` arg
    concatenations. Unparseable bodies fail closed."""
    try:
        inner_trees = bashlex.parse(body)
    except Exception:
        return True
    for tree in inner_trees:
        for inner_cmd in all_command_nodes(tree):
            if is_push_command(inner_cmd):
                return True
    return False

def classify_pairs(pairs):
    """Decide push intent for a list of (string, is_dynamic) word pairs
    treated as a command. Returns True (push intent or ambiguous-fail-
    closed) or False (confidently no push)."""
    if not pairs:
        return False
    head_str, head_dyn = pairs[0]
    if head_dyn:
        return True  # dynamic head -> ambiguous
    if head_str in PASSTHROUGH:
        # Scan rest for the next classifiable head (git/gh, another wrapper,
        # or a shell), skipping wrapper-specific options/values which we
        # don'"'"'t parse precisely. A dynamic word in the rest is ambiguous.
        for i in range(1, len(pairs)):
            t, dyn = pairs[i]
            if dyn:
                return True
            if (t in PASSTHROUGH or t in SHELL_C_WRAPPERS
                    or t == "git" or t == "gh"):
                return classify_pairs(pairs[i:])
        return False  # no classifiable head after wrapper
    if head_str in SHELL_C_WRAPPERS:
        body = find_shell_c_body(pairs[1:])
        if body is None:
            return True
        if body is False:
            return False  # no -c, just a shell invocation
        return walk_body_for_push(body)
    if head_str in EVAL_WRAPPERS:
        args = pairs[1:]
        if any(d for _, d in args):
            return True  # dynamic eval arg -> ambiguous
        body = " ".join(s for s, _ in args)
        if not body:
            return False  # `eval` with no args is a no-op
        return walk_body_for_push(body)
    if head_str == "git":
        rest = skip_options(pairs[1:], GIT_BOOLEAN, GIT_VALUED)
        if rest is None:
            return True
        if not rest:
            return False
        sub_str, sub_dyn = rest[0]
        if sub_dyn:
            return True
        if sub_str != "push":
            return False
        return not is_pure_delete_push(rest[1:])
    if head_str == "gh":
        rest = skip_options(pairs[1:], GH_BOOLEAN, GH_VALUED)
        if rest is None:
            return True
        if not rest:
            return False
        sub_str, sub_dyn = rest[0]
        if sub_dyn:
            return True
        if sub_str != "pr":
            return False
        inner = skip_options(rest[1:], GH_BOOLEAN, GH_VALUED)
        if inner is None:
            return True
        if not inner:
            return False
        inner_str, inner_dyn = inner[0]
        if inner_dyn:
            return True
        return inner_str == "create"
    return False

def is_pure_delete_push(push_args):
    """Decide whether the word pairs after `git push` describe an all-deletion
    push (no commits sent, nothing for codex to review). Returns True only
    when every refspec is a literal `:...` deletion and the line has no
    options that could affect what gets sent. False otherwise; the caller
    then falls through to the gate (fail-closed).

    Detection is positional-only:
      * Every positional after the first (the remote) starts with `:` and is
        not bare `:` (bare `:` is git matching-branches push, not a delete)
      * Single positional case: it must itself be a literal `:foo` form
        (`git push :foo` against the default remote)

    Any option after `push` forces False. Modelling push-option grammar
    (--repo, -o, --receive-pack, --exec, --tags, --mirror, --signed,
    --force-with-lease, ...) is more code than gating-on-options is worth:
    a valued option can consume a `--delete` as its value (false-allow), and
    refs-expanding options like --tags can add real refs to an otherwise
    delete-shaped command. The recovery path for the rare `git push --delete
    foo` form is a normal codex-review-capture run.

    Dynamic words anywhere also force False -- the runtime value could expand
    to an option, an extra refspec, or split into multiple words.

    Shell metacharacters in any arg also force False. bashlex does not expand
    brace expressions or globs, so `:{,foo}` arrives as a static literal but
    bash splits it into `:` and `:foo` at runtime -- the bare `:` half is a
    matching-branches push. Same hazard for `*`, `?`, `[...]`, and `\` escapes.
    Refusing any word containing `{}*?[]\` covers the class."""
    SHELL_META = "{}*?[]\\"
    positionals = []
    for word, dyn in push_args:
        if dyn:
            return False
        if word.startswith("-"):
            return False
        if any(c in word for c in SHELL_META):
            return False
        positionals.append(word)
    if not positionals:
        return False
    if len(positionals) == 1:
        return positionals[0].startswith(":") and positionals[0] != ":"
    for word in positionals[1:]:
        if not word.startswith(":") or word == ":":
            return False
    return True

def is_push_command(cmd_node):
    """Check whether a bashlex CommandNode represents a git push / gh pr
    create, handling passthrough wrappers, shell -c delegates, and dynamic
    words. Entry point that pulls the word pairs and hands off to
    `classify_pairs` for the actual logic."""
    return classify_pairs(word_pairs(cmd_node))

def all_command_nodes(node):
    """Yield every CommandNode reachable from `node`, descending into list/
    pipeline parts, compound bodies, command substitutions, AND redirect
    targets (where process/command substitutions can hide: `cat < <(git
    push)`, `: > $(git push)`).

    Heredoc bodies are not descended -- a known-and-accepted gap is
    unquoted heredocs that contain command substitution (`cat <<EOF\n$(git
    push)\nEOF` is a real push that this walker misses). The use case is
    exotic enough that we eat the false-allow rather than re-parsing
    heredoc body text."""
    kind = getattr(node, "kind", None)
    if kind == "command":
        yield node
    for attr in ("parts", "list"):
        for child in getattr(node, attr, None) or []:
            yield from all_command_nodes(child)
    for attr in ("command", "output", "input"):
        target = getattr(node, attr, None)
        if target is not None and target is not node:
            yield from all_command_nodes(target)

try:
    trees = bashlex.parse(command)
except bashlex.errors.ParsingError:
    sys.exit(1)
except Exception:
    sys.exit(1)

for tree in trees:
    for cmd in all_command_nodes(tree):
        if is_push_command(cmd):
            sys.exit(1)

sys.exit(0)
'; then
    exit 0
  fi
fi

cd "$CWD"

# Allow through if not in a git repo (hooks are repo-scoped, but be safe)
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  exit 0
fi

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

# Hash-keyed sentinel scan. Each file at
# /tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-${HASH} records one
# successful codex review: filename suffix is the sha256 of `git diff $BASE`
# captured at review time; contents are the BASE commit (one line). The gate
# iterates each, reads its BASE, recomputes the diff hash against the current
# tree, and admits the push on the first file whose recomputed hash matches
# its filename. Sentinels are NOT consumed on match: a single review covers
# the whole ship sequence (`git push` followed by `gh pr create`, or repeated
# pushes of the same diff). The sentinel becomes invalid the moment the diff
# changes -- the new hash won't match any existing filename. Stale sentinels
# from past pushes linger in /tmp until reboot or manual cleanup; harmless.
#
# BASE_SHA depends on the codex review mode the wrapper observed:
#   --commit X     -> BASE_SHA = X^,                  HASH = sha256(git diff X^ X)
#   --base B       -> BASE_SHA = merge-base(B, HEAD), HASH = sha256(git diff BASE HEAD)
#   --uncommitted  -> BASE_SHA = HEAD,                HASH = sha256(git diff HEAD)
#
# Files whose BASE is unreachable (rebased away) or whose contents are empty
# are skipped silently -- they're stale. We track whether any *valid* (BASE
# reachable, contents present) review existed so we can distinguish "no
# reviews on file" from "reviews exist but don't match the current tree" in
# the error message.
matched=""
any_valid_review=false
shopt -s nullglob
# Quote the literal prefix so REPO_NAME values containing spaces or glob
# metacharacters (`[`, `?`, `*`) aren't word-split or pre-expanded out of the
# glob pattern. The trailing `*` stays unquoted to remain a wildcard.
for f in "/tmp/codex-gate-reviewed-${UID}-${REPO_NAME}-"*; do
  hash_from_name="${f##*-}"
  base=$(< "$f")
  [[ -z "$base" ]] && continue
  git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 || continue
  any_valid_review=true
  current_hash=$(git diff "$base" 2>/dev/null | _sha256)
  if [[ "$current_hash" == "$hash_from_name" ]]; then
    matched="$f"
    break
  fi
done
shopt -u nullglob

if [[ -n "$matched" ]]; then
  exit 0
fi

if $any_valid_review; then
  echo "BLOCKED: Code changed since last codex review." >&2
  echo "None of the reviews on file produce a diff matching the current tree." >&2
  echo "Either you added work beyond what was reviewed, or you modified the" >&2
  echo "reviewed changes. Run codex-review-capture again, then retry." >&2
  exit 2
fi

echo "BLOCKED: No codex review found." >&2
echo "Run: codex-review-capture --base <branch>  (or --commit HEAD, --uncommitted)" >&2
echo "Then retry the push." >&2
exit 2
