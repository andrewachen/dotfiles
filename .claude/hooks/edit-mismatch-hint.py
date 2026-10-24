#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# ABOUTME: PostToolBatch hook injecting recovery hints when an Edit failed
# ABOUTME: "String to replace not found". Verified (live CC probe, 2.1.309):
# ABOUTME: Edit's validateInput rejects before PreToolUse/PostToolUseFailure
# ABOUTME: hooks run, so those events never see the wrong-anchor loop this
# ABOUTME: targets; PostToolBatch does, with the error in tool_response.
# ABOUTME: SNAPSHOT-ONLY: the hint is computed purely from content the
# ABOUTME: session transcript (transcript_path from the hook payload —
# ABOUTME: CC's own durable read-state, the same records
# ABOUTME: extractReadFilesFromMessages rebuilds readFileState from) shows
# ABOUTME: was disclosed by a successful Read or authored by a Write. The
# ABOUTME: current file is never opened, so nothing about its present
# ABOUTME: state can leak and no unread path is ever touched. The hint
# ABOUTME: names the likeliest-match line and exact Read(offset, limit)
# ABOUTME: parameters; if the file drifted since the snapshot, the
# ABOUTME: prescribed permissioned Read shows the model the current truth.
# ABOUTME: It deliberately does NOT echo file bytes. Pure context
# ABOUTME: injection: never denies, so it can't reject an Edit.

import difflib
import json
import os
import stat
import sys
import time

HOOK_EVENT = "PostToolBatch"
NOT_FOUND_MARKER = "String to replace not found"
# The real harness emits the failure as a plain string starting with this
# tag (probed); anything else (dict responses, prose mentioning the marker)
# is not evidence of a failed Edit.
ERROR_TAG = "<tool_use_error>"

# Beyond these bounds the hint is abandoned (generic advice only): windowing
# gets expensive and long anchors signal whole-file rewrites the model should
# redo from a Read anyway.
MAX_ANCHOR_LINES = 100
MAX_FILE_LINES = 5000
MAX_CANDIDATES = 2000
# Hard compute budget per hint: cumulative characters fed to SequenceMatcher.
# Bounds the short-anchor scan against pathological long-line files within
# the line/byte caps (a slow hook stalls the whole PostToolBatch). Calibrated
# ~3.5us/char on repetitive content: 300k chars ~ 1s.
CHAR_BUDGET = 300_000
# A single comparison above this many chars is skipped outright: one
# SequenceMatcher.ratio() over multi-hundred-KB strings costs seconds on its
# own, and such windows are degenerate (whole-file-rewrite anchors).
MAX_COMPARE_CHARS = 200_000
# Anchors this short get a full pruned scan when they share no verbatim line
# with the file (a single drifted cell in a 1-3 line anchor is a realistic
# near-miss); longer fully-drifted anchors only get the verbatim-line tier.
SHORT_SCAN_LINES = 5
# Lines occurring more often than this in the file are boilerplate (blanks,
# braces, separators) and are excluded from seeding and aligned-match
# scoring: common lines flood the candidate budget before distinctive ones
# seed, and aligned matches on them are noise.
MAX_LINE_OCCURRENCES = 25
# Number of top-ranked candidates refined with the exact char-level
# comparison (the single-winner version could miss the true region when
# boilerplate lines out-score it at line level).
TOP_K = 3
# Failed Edits hinted per batch (an unbounded batch is unbounded work).
MAX_HINTS_PER_BATCH = 5
# Distinct failed Edits analyzed per batch — the cap applies to ATTEMPTS,
# not just emitted hints, so a batch of many failures can't multiply scans.
MAX_HINT_ATTEMPTS = 8
# Wall-clock deadline for the whole hook invocation: character and product
# counters bound individual comparisons, the deadline bounds the batch.
DEADLINE_SECONDS = 5.0
# A comparison above this product (win_chars * anchor_chars) is skipped:
# SequenceMatcher.ratio() is quadratic on repetitive strings, so char-count
# caps alone don't bound runtime (measured ~11s for a 10k x 10k pair with
# autojunk disabled). Products over this are also degenerate matches.
MAX_COMPARE_OPS = 10_000_000

# The session transcript is scanned from the tail only: the Read that
# precedes a failed Edit is almost always recent, and a full re-parse of a
# large transcript per batch is unbounded work. 8 MiB of tail covers it.
TAIL_BYTES = 8 * 1024 * 1024

# Context padding around the likeliest match when prescribing the Read window.
READ_PAD = 2

# Below this similarity the best window is noise, not the intended target --
# naming it would point the model at the wrong region.
HINT_THRESHOLD = 0.5

# A non-overlapping runner-up within this margin of the winner means the
# match is ambiguous (repeated blocks): abstain from a specific offset.
AMBIGUITY_MARGIN = 0.05


def display(path: str) -> str:
    """Quote the path for prose: a POSIX-legal filename can contain newlines
    and other control characters, and none of them may shape the
    additionalContext text. json escaping handles every control char."""
    return json.dumps(path)


def generic_hint(file_path: str) -> str:
    return (
        f"Edit failed on {display(file_path)}: old_string not found, and no "
        "close region could be identified. Do NOT re-emit the same anchor. "
        "Use the Read tool on the file (fully, or around the section you "
        "intend to change), then copy old_string verbatim from that Read's "
        "output (stripping the '<lineno>\\t' prefixes), preferring a small "
        "unique snippet over a long multi-line anchor."
    )


def ambiguous_hint(file_path: str) -> str:
    return (
        f"Edit failed on {display(file_path)}: old_string not found, and "
        "several near-identical regions match it — no unique location can "
        "be identified. Do NOT re-emit the same anchor. Use the Read tool "
        "on the file around the competing regions and include more "
        "surrounding context in old_string so the intended occurrence is "
        "unambiguous."
    )


def stale_anchor_hint(file_path: str, line_no: int, anchor_lines: int) -> str:
    offset = max(1, line_no - 25)
    limit = anchor_lines + 50  # the whole old anchor plus 25 lines of pad per side
    return (
        f"Edit failed on {display(file_path)}: old_string matches a prior "
        f"view of this file verbatim (line {line_no}), so it has changed "
        "since then — do not re-emit it. Read a BROAD region covering "
        f"where it used to be: "
        f"Read(file_path={display(file_path)}, offset={offset}, "
        f"limit={limit}), then copy old_string verbatim from that Read's "
        "output (stripping the '<lineno>\\t' prefixes)."
    )


def specific_hint(file_path: str, line_no: int, ratio: float, window_len: int, label: str) -> str:
    offset = max(1, line_no - READ_PAD)
    limit = window_len + 2 * READ_PAD
    return (
        f"Edit failed on {display(file_path)}: old_string not found. "
        f"Likeliest match in {label}: line {line_no} "
        f"({ratio:.0%} similar). Read that region before retrying — "
        f"do not re-emit the same anchor: "
        f"Read(file_path={display(file_path)}, offset={offset}, "
        f"limit={limit}). Copy old_string verbatim from that Read's output, "
        "stripping the '<lineno>\\t' prefixes the Read tool prepends, and "
        "prefer a smaller unique snippet over a long multi-line anchor. "
        "If the region looks different than described, the file changed "
        "since that Read — work from what the Read returns."
    )


def best_window(file_lines: list[str], old_lines: list[str], deadline: float) -> tuple[float, int, int, bool] | None:
    """(char_ratio, 0-based start, distinctive-count, close-second) of the
    likeliest full-size window, or None when no candidate reaches
    HINT_THRESHOLD; close-second marks a non-overlapping runner-up within
    AMBIGUITY_MARGIN. Two candidate tiers:
    1. windows containing a verbatim anchor line (the observed near-miss class
       keeps 82-90% of lines verbatim) — seeded rarity-first from a
       line->index map so boilerplate lines can't flood the budget, ranked by
       aligned-position matches over informative lines, and the top TOP_K
       candidates get the exact char-level comparison;
    2. for short anchors (<= SHORT_SCAN_LINES) with no verbatim line at all,
       a pruned, budget-bounded char-level scan of every window.
    Scoring every window of a large file char-level is prohibitively slow
    (measured 11.6s at 5000x50); line-level ranking of the same worst case
    measures 0.42s."""
    n = len(old_lines)
    m = len(file_lines)
    if m == 0:
        return None
    if m < n:
        r = _char_score(file_lines, 0, old_lines, autojunk=False)
        return None if r is None else (r[0], r[1], False)
    # line -> indices, restricted to lines the anchor contains
    wanted = set(old_lines)
    positions: dict[str, list[int]] = {}
    for i, line in enumerate(file_lines):
        if line in wanted:
            positions.setdefault(line, []).append(i)
    starts: set[int] = set()
    short_scan = False
    if positions:
        # seed rarity-first: distinctive anchor lines claim the budget before
        # boilerplate ones can; overly-common lines seed nothing at all
        informative = {
            ln for ln in old_lines if len(positions.get(ln, ())) <= MAX_LINE_OCCURRENCES
        }
        for ln in sorted(informative, key=lambda l: len(positions.get(l, ()))):
            for idx in positions.get(ln, ()):
                for k in range(n):
                    s = idx - k
                    if 0 <= s <= m - n:
                        starts.add(s)
            if len(starts) > MAX_CANDIDATES:
                break
        if len(starts) > MAX_CANDIDATES:
            # deterministic subsample keeps the scan bounded on pathological
            # files
            ordered = sorted(starts)
            step = len(ordered) / MAX_CANDIDATES
            starts = {ordered[int(i * step)] for i in range(MAX_CANDIDATES)}
    elif n <= SHORT_SCAN_LINES:
        starts = set(range(m - n + 1))
        short_scan = True
    if not starts and n <= SHORT_SCAN_LINES:
        # seeding yielded nothing usable (every shared line is boilerplate):
        # a near-exact short window is still findable by the bounded scan
        starts = set(range(m - n + 1))
        short_scan = True
    if not starts:
        return None
    if short_scan:
        scores: list[tuple[float, int, int]] = []
        spent = 0
        old_chars = len("\n".join(old_lines))
        unique_lines = {ln for ln in old_lines if len(positions.get(ln, ())) == 1}
        for s in sorted(starts):
            if spent > CHAR_BUDGET or time.monotonic() > deadline:
                break
            spent += old_chars + sum(len(x) for x in file_lines[s : s + n])
            r = _char_score(file_lines, s, old_lines, autojunk=True)
            if r is not None:
                distinctive = sum(
                    1 for j in range(n) if old_lines[j] in unique_lines and file_lines[s + j] == old_lines[j]
                )
                scores.append((r[0], r[1], distinctive))
        return _best_with_margin(scores, n)
    # seeded path: rank by aligned-position matches over informative lines
    # (which file line sits at which anchor offset — discriminates the true
    # window from off-by-one neighbors that merely share lines), with
    # line-level SequenceMatcher ratio as tiebreak (handles reordered rows),
    # then refine the top TOP_K with exact char-level comparisons
    n_range = range(n)
    ranked: list[tuple[tuple[int, float], int]] = []
    for s in sorted(starts):
        aligned = sum(1 for j in n_range if old_lines[j] in informative and file_lines[s + j] == old_lines[j])
        lr = difflib.SequenceMatcher(None, file_lines[s : s + n], old_lines).ratio()
        ranked.append(((aligned, lr), s))
    ranked.sort(key=lambda t: t[0], reverse=True)
    scores = []
    unique_lines = {ln for ln in old_lines if len(positions.get(ln, ())) == 1}
    for _key, s in _diverse_shortlist(ranked, TOP_K, n):
        if time.monotonic() > deadline:
            break
        r = _char_score(file_lines, s, old_lines, autojunk=False)
        if r is not None:
            distinctive = sum(1 for j in n_range if old_lines[j] in unique_lines and file_lines[s + j] == old_lines[j])
            scores.append((r[0], r[1], distinctive))
    return _best_with_margin(scores, n)


def _diverse_shortlist(ranked: list, top_k: int, n: int) -> list:
    """The top-ranked candidates plus, when every one of them overlaps the
    best window, the best-ranked candidate a full window away — otherwise
    the margin check never sees a distant near-twin (repeated blocks rank
    below the winner's overlapping neighbors)."""
    short = list(ranked[:top_k])
    if short:
        best_s = short[0][1]
        for item in ranked[top_k:]:
            if abs(item[1] - best_s) >= n:
                short.append(item)
                break
    return short


def _best_with_margin(scores: list[tuple[float, int, int]], n: int) -> tuple[float, int, int, bool] | None:
    """Best window (ratio, start, distinctive-count) plus whether a
    NON-overlapping runner-up scores within AMBIGUITY_MARGIN. The caller
    decides ambiguity: a distinctive winner (a file-unique anchor line
    aligned at its position) is positively identified, but only within
    the evidence this snapshot provides — the caller gates that exemption
    on snapshot completeness."""
    if not scores:
        return None
    best_r, best_s, best_d = max(scores, key=lambda t: t[0])
    second_r = max((r for r, s, _d in scores if abs(s - best_s) >= n), default=None)
    return best_r, best_s, best_d, second_r is not None and best_r - second_r < AMBIGUITY_MARGIN


def _char_score(
    file_lines: list[str], start: int, old_lines: list[str], autojunk: bool
) -> tuple[float, int] | None:
    """Char-level SequenceMatcher ratio for one window, with the standard
    cheap-prefilter pruning so implausible windows never pay for the full
    quadratic ratio(). autojunk=False for refinement paths: the default
    junk-heuristic treats frequent characters as junk once the text exceeds
    ~200 chars, collapsing table-like content (measured 0.26 vs 0.92 on the
    exact near-miss class this hook targets). Kept on for the short-scan
    loop, where disabling it triples scan time. Windows too large for one
    comparison to stay cheap are skipped (None)."""
    win = "\n".join(file_lines[start : start + len(old_lines)])
    old = "\n".join(old_lines)
    if len(win) + len(old) > MAX_COMPARE_CHARS:
        return None
    if len(win) * len(old) > MAX_COMPARE_OPS:
        # SequenceMatcher.ratio() is quadratic on repetitive strings; the
        # product, not the char count, is what bounds runtime
        return None
    sm = difflib.SequenceMatcher(None, win, old, autojunk=autojunk)
    if sm.real_quick_ratio() < HINT_THRESHOLD:
        return None
    if sm.quick_ratio() < HINT_THRESHOLD:
        return None
    return sm.ratio(), start


def key_path(p: str, cwd: str) -> str:
    """Lexical path identity — no filesystem resolution. Snapshot-only must
    not touch the FS (realpath can block on automounts/NFS and makes
    output depend on a symlink's current target); matching is consistent
    because Read and Edit spellings are compared under the same rule.
    Alias spellings (symlink vs real path) therefore don't cross-match —
    that degrades to generic advice, the safe direction. `~username` is
    never expanded (NSS/LDAP lookups can block); only `~`/`~/` expand via
    $HOME, and a relative path without a payload cwd stays unmatched."""
    if not p:
        return ""
    if p.startswith("~"):
        if p == "~" or p.startswith("~/"):
            home = os.environ.get("HOME")
            if not home:
                return ""
            p = home + p[1:]
        else:
            return ""
    if not os.path.isabs(p):
        # relative paths resolve against a cwd that may have changed since
        # the Read — refuse rather than risk cross-binding another file
        return ""
    if any(part == ".." for part in p.split("/")):
        # lexically collapsing .. can change meaning across symlinked
        # components — refuse rather than mis-bind
        return ""
    return os.path.normpath(p)


def _norm(s: str) -> str:
    """Normalize for snapshot comparison: strip leading BOM characters,
    unify CRLF to LF. Bare CRs are left alone (Read numbers lines by
    \\n only)."""
    return s.lstrip("\ufeff").replace("\r\n", "\n")


def _strip_line_numbers(content: object) -> tuple[str, int] | None:
    """Reconstruct file content from a Read tool_result's line-numbered
    text dump ("1\\tfirst line\\n2\\t..."). Returns (content, first line
    number) — the dump's own numbering supplies the absolute start line.
    A known single-line <system-reminder> wrapper prepended by CC is
    skipped. None when the text isn't a complete numbered dump (unknown
    shapes authorize nothing)."""
    if isinstance(content, list):
        content = "\n".join(
            b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"
        )
    if not isinstance(content, str) or not content:
        return None
    lines = content.split("\n")
    if lines and lines[0].startswith("<system-reminder>") and lines[0].endswith("</system-reminder>"):
        lines = lines[1:]
        if not lines:
            return None
    out: list[str] = []
    start_line = 0
    for line in lines:
        tab = line.find("\t")
        if tab <= 0 or not line[:tab].isdigit():
            return None
        if not out:
            start_line = int(line[:tab])
        out.append(line[tab + 1 :])
    return "\n".join(out), start_line


def read_snapshots(transcript_path: str, cwd: str, deadline: float) -> dict[str, list[tuple[str, int, bool]]]:
    """Every content disclosure per path in this session's transcript, as
    recorded by CC in toolUseResult (the same records CC's own
    extractReadFilesFromMessages uses to rebuild readFileState on resume):
    successful Reads (structured or numbered-dump form) and Writes, as
    (content, start_line) pairs, newest last. Empty when the transcript
    shows nothing (fails closed: the caller emits generic advice and
    touches nothing). Only the bounded tail is scanned; malformed lines,
    errored results (is_error), and sidechain records are skipped. JSON
    encoding makes every control character unframeable, so a legal POSIX
    filename can't synthesize a second record. Called once per batch —
    the tail parse is the batch's dominant cost, not per-Edit work."""
    if not transcript_path:
        return {}
    try:
        # O_NONBLOCK: a swapped-in FIFO must not block the open waiting for
        # a writer — the regular-file check rejects it right after
        fd = os.open(transcript_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return {}
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return {}
        if st.st_size > TAIL_BYTES:
            os.lseek(fd, st.st_size - TAIL_BYTES, os.SEEK_SET)
        raw = os.read(fd, TAIL_BYTES).decode("utf-8", errors="replace")
    except OSError:
        return {}
    finally:
        os.close(fd)
    lines = raw.split("\n")
    if st.st_size > TAIL_BYTES:
        lines = lines[1:]  # first line after a seek may be partial
    # Pass 1: parse and index by uuid. Rewound/forked conversations keep
    # abandoned branches in the JSONL; only the ancestry of the LAST record
    # is the model's live conversation state, so disclosures off that chain
    # authorize nothing. Records without a uuid (unknown shapes) are skipped
    # — fail closed.
    recs: list[dict] = []
    uuid_idx: dict[str, int] = {}
    for i, line in enumerate(lines):
        if not (i % 4096) and time.monotonic() > deadline:
            return {}  # deadline hit mid-scan: fail closed, advise generically
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(rec, dict):
            recs.append(rec)
            if isinstance(rec.get("uuid"), str):
                uuid_idx[rec["uuid"]] = len(recs) - 1
    if not uuid_idx:
        # No uuids at all: no proof the transcript was never rewound,
        # concatenated, or produced with hidden branches — fail closed.
        return {}
    active: set[str] = set()
    cur = recs[max(uuid_idx.values())].get("uuid")
    while isinstance(cur, str) and cur in uuid_idx and cur not in active:
        active.add(cur)
        cur = recs[uuid_idx[cur]].get("parentUuid")
    pending: dict[str, tuple[str, str | None]] = {}  # tool_use id -> (input path, Write input content)
    # path key -> disclosures in the tail as (content, start_line, complete);
    # start_line converts snapshot-relative line numbers to absolute ones
    snapshots: dict[str, list[tuple[str, int, bool]]] = {}
    for rec in recs:
        if rec.get("uuid") not in active:
            continue  # abandoned branch, or a uuid-less record in a branched transcript
        if rec.get("isSidechain"):
            continue  # subagent records must not authorize the main session
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        blocks = msg.get("content")
        if not isinstance(blocks, list):
            continue
        for item in blocks:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "tool_use" and item.get("name") in ("Read", "Write"):
                inp = item.get("input")
                tid = item.get("id")
                if isinstance(inp, dict) and isinstance(tid, str) and isinstance(inp.get("file_path"), str):
                    in_key = key_path(inp["file_path"], cwd)
                    if not in_key:
                        continue  # rejected spelling: never record under ""
                    # For Writes, keep the MODEL-AUTHORED input content: a
                    # post-write hook may transform the result, so only the
                    # input is guaranteed to be what the model has seen.
                    wcontent = inp.get("content") if item.get("name") == "Write" else None
                    pending[tid] = (in_key, wcontent if isinstance(wcontent, str) else None)
            elif item.get("type") == "tool_result":
                tid = item.get("tool_use_id")
                if not isinstance(tid, str) or tid not in pending:
                    continue
                in_path, wcontent = pending.pop(tid)
                if item.get("is_error"):
                    continue  # errored call: no disclosure happened
                content = fp = None
                start_line = 1
                complete = False
                tur = rec.get("toolUseResult")
                if wcontent is not None:
                    # Write: the authored input IS the disclosure once the
                    # result confirms success ("create" new file, "update"
                    # overwrite). Cross-bind the result's filePath when the
                    # shape carries one.
                    rfp = tur.get("filePath") if isinstance(tur, dict) else None
                    if not isinstance(rfp, str) or key_path(rfp, cwd) == in_path:
                        content, fp, complete = wcontent, in_path, True
                else:
                    # Read disclosure proof: ONLY the visible tool_result
                    # numbered dump — exactly the bytes the model saw. The
                    # structured toolUseResult is CC's internal copy and
                    # may retain bytes the rendering truncated, so it is
                    # not treated as disclosure (codex design High).
                    stripped = _strip_line_numbers(item.get("content"))
                    if stripped is not None:
                        # The tool_use_id association supplies the binding,
                        # but result-side path metadata still REJECTS: if a
                        # redirect moved the Read elsewhere, the dump does
                        # not describe the requested file.
                        rfp = tur.get("file", {}).get("filePath") if isinstance(tur, dict) else None
                        if isinstance(rfp, str) and rfp and key_path(rfp, cwd) != in_path:
                            continue
                        content, start_line = stripped
                        fp = in_path  # cross-bound by construction
                if isinstance(content, str) and isinstance(fp, str) and fp:
                    if key_path(fp, cwd) == in_path:
                        snapshots.setdefault(in_path, []).append((content, start_line, complete))
    return snapshots


def build_hint(file_path: str, old_string: str, snapshots: dict[str, list[tuple[str, int, bool]]], cwd: str, deadline: float) -> str | None:
    """Recovery hint for one failed Edit, or None when we can't help.
    Snapshot-only: the hint is computed purely from content the session's
    transcript shows was disclosed by a successful Read (or authored by a
    Write) — the current file is never opened and its path is never
    resolved against the filesystem, so nothing about its present state
    can leak and a hostile path can't stall the batch. Stale snapshots
    are labeled as such; the prescribed permissioned Read is what shows
    the model the current truth."""
    if time.monotonic() > deadline:
        return generic_hint(file_path)
    candidates = snapshots.get(key_path(file_path, cwd)) or []
    if not candidates:
        # The session transcript shows no successful disclosure of this
        # path: emitting line or similarity metadata derived from any
        # content at all would make the hint a content oracle for files
        # outside the Read permission boundary. Generic advice only —
        # no file access at all.
        return generic_hint(file_path)
    # The anchor cap applies BEFORE stale classification (codex Medium):
    # oversized anchors get generic advice in every branch.
    if old_string.count("\n") + 1 > MAX_ANCHOR_LINES:
        return generic_hint(file_path)
    # A verbatim anchor in any retained view that CC just rejected is the
    # stale-anchor case (newest such view first): a broad re-Read around
    # that location, sized to cover the WHOLE old anchor, instead of a
    # narrow "exact" offset (one coherent freshness model). More than one
    # occurrence in that view means no identifiable one — abstain.
    for content, start_line, _complete in reversed(candidates[-3:]):
        norm = _norm(content)
        if old_string in norm:
            if norm.count(old_string) > 1:
                return ambiguous_hint(file_path)
            idx = norm.find(old_string)
            line_no = start_line + norm.count("\n", 0, idx)
            return stale_anchor_hint(file_path, line_no, old_string.count("\n") + 1)
    for i, (content, start_line, complete) in enumerate(reversed(candidates[-3:])):
        # newest first: the most recent view of the file is the likeliest
        # basis for the model's intended edit; older snapshots are labeled
        # as earlier views, never as the last one
        label = "your last view of this file" if i == 0 else "an earlier view of this file"
        hint = _hint_from_snapshot(file_path, old_string, content, start_line, complete, label, deadline)
        if hint is not None:
            return hint
    return generic_hint(file_path)


def _hint_from_snapshot(
    file_path: str, old_string: str, content: str, start_line: int, complete: bool, label: str, deadline: float
) -> str | None:
    """Match the failed anchor against ONE disclosed snapshot, or None."""
    content = _norm(content)
    if old_string in content:
        # This older snapshot verbatim contains the anchor but a NEWER one
        # does not: the anchor predates the latest view. Approximate-match
        # the newer snapshots instead.
        return None
    if content == "":
        return None  # empty snapshot: nothing to anchor; appends are Write's job
    if content.count("\n") > MAX_FILE_LINES:
        # count before split: a newline-storm snapshot would otherwise
        # materialize millions of list entries before the cap check
        return None
    lines = content.split("\n")
    old_lines = old_string.split("\n")
    if len(old_lines) > MAX_ANCHOR_LINES or len(lines) < len(old_lines):
        # a snapshot shorter than the anchor cannot contain the window
        return None
    best = best_window(lines, old_lines, deadline)
    if best is None or best[0] < HINT_THRESHOLD:
        return None
    ratio, start, distinctive, close_second = best
    # Uniqueness is only provable within a COMPLETE snapshot: a range-
    # limited Read may hide an identical region outside its range, so its
    # "unique" line identifies nothing globally (codex design High #2).
    if close_second and not (complete and distinctive > 0):
        return ambiguous_hint(file_path)
    # start_line converts snapshot-relative numbering to absolute file
    # coordinates. The Read window is NOT clamped to the snapshot's end:
    # if the file grew since the disclosure, the target may sit past the
    # old EOF, and an unclamped Read stops at EOF harmlessly.
    return specific_hint(file_path, start_line + start, ratio, len(old_lines), label)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    hints: list[str] = []
    seen_hints: set[str] = set()
    attempted: set[tuple[str, str]] = set()
    deadline = time.monotonic() + DEADLINE_SECONDS
    snapshots: dict[str, list[tuple[str, int, bool]]] | None = None  # parsed once per batch
    for call in data.get("tool_calls") or []:
        if len(attempted) >= MAX_HINT_ATTEMPTS or time.monotonic() > deadline:
            break
        try:
            if not isinstance(call, dict) or call.get("tool_name") != "Edit":
                continue
            resp = call.get("tool_response")
            # only the real string error form counts, with the not-found
            # marker DIRECTLY after the tag: an ambiguity rejection whose
            # echoed anchor contains the marker text ("Found 2 matches …
            # String: String to replace not found") must not classify as
            # not-found, and a dict response serializing the marker inside
            # a successful edit's content must not match either
            if not isinstance(resp, str) or not resp.startswith(ERROR_TAG):
                continue
            if not resp[len(ERROR_TAG) :].lstrip().startswith(NOT_FOUND_MARKER):
                continue
            inp = call.get("tool_input") or {}
            if not isinstance(inp, dict):
                continue
            file_path = inp.get("file_path") or ""
            old_string = inp.get("old_string")
            if not file_path or not old_string:
                continue
            # dedupe identical failures: the second scan would be free but
            # pointless; count the attempt so distinct failures stay capped
            key = (file_path, old_string)
            if key in attempted:
                continue
            attempted.add(key)
            if snapshots is None:
                snapshots = read_snapshots(data.get("transcript_path") or "", data.get("cwd") or "", deadline)
            hint = build_hint(file_path, old_string, snapshots, data.get("cwd") or "", deadline)
        except Exception:
            # one malformed call or unreadable file must not suppress the
            # other hints in the batch
            continue
        if hint and len(hints) < MAX_HINTS_PER_BATCH and hint not in seen_hints:
            hints.append(hint)
            seen_hints.add(hint)

    if hints:
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": HOOK_EVENT,
                    "additionalContext": "\n\n".join(hints),
                }
            },
            sys.stdout,
        )
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail-open: this is a quality-of-life hook, not a security boundary.
        # A crash must not disturb the batch.
        sys.exit(0)
