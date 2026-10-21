#!/usr/bin/env python3
r"""Escape currency dollar signs in Markdown so go-grip/MathJax can't eat them.

go-grip's MathJax extension pairs any two `$` characters in one block (paragraph,
list item, table cell, heading) as `$...$` inline math, typesetting everything
between them as italic TeX and swallowing `**bold**`/`*emphasis*` markup. Run
this script on a Markdown file BEFORE serving it with grip-review.

What it does:
  - Escapes every `$` immediately followed by a digit as `\$` (currency amounts).
  - Leaves already-escaped `\$` alone (idempotent — safe to re-run).
  - Leaves code untouched (fenced ``` blocks, ~~~ blocks, inline `spans`):
    a backslash inside code would display literally.
  - Leaves real math alone: `$x^2$` has no digit after the opening `$`.

Usage:
  escape-currency-dollars.py [--check] FILE [FILE or DIR ...]

Single FILE arguments are edited in place and print "<file>: N escapes".
--check turns them into a read-only report: "<file>: N unescaped currency $".

Directory arguments are ALWAYS read-only, with or without --check: every
`*.md` under the directory (recursively, hidden dirs skipped) is scanned and
only the affected files are listed, so you can decide which ones to rewrite
individually. A bulk directory rewrite is the footgun this design avoids.
"""

import os
import re
import sys

# Fenced blocks with 3-char delimiters (``` or ~~~) and single-line inline
# code spans pass through untouched. Longer fence delimiters and multi-line
# inline spans are not recognized (multi-backtick spans are a known
# out-of-scope shape); a length-aware fence regex is the block-parser
# complexity deliberately rejected.
CODE = re.compile(r'(```|~~~).*?\1|`[^`\n]*`', re.S)
CURRENCY = re.compile(r'(?<!\\)\$(?=[0-9])')


def escape_file(path: str, write: bool = True) -> int:
    # newline='' disables newline translation in both directions, so a CRLF
    # file is rewritten with its line endings intact.
    with open(path, encoding='utf-8', newline='') as f:
        text = f.read()

    out = []
    last = 0
    count = 0
    for m in CODE.finditer(text):
        seg, k = CURRENCY.subn(r'\\$', text[last:m.start()])
        out.append(seg)
        out.append(m.group(0))
        count += k
        last = m.end()
    seg, k = CURRENCY.subn(r'\\$', text[last:])
    out.append(seg)
    count += k

    if count and write:
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(''.join(out))
    return count


def markdown_files(path: str):
    if os.path.isfile(path):
        yield path
        return
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith('.'))
        for name in sorted(filenames):
            if name.endswith('.md'):
                yield os.path.join(dirpath, name)


def main() -> int:
    args = sys.argv[1:]
    if not args or '-h' in args or '--help' in args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    check = '--check' in args
    args = [a for a in args if a != '--check']
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    status = 0
    for arg in args:
        if not os.path.exists(arg):
            print(f'{arg}: no such file or directory', file=sys.stderr)
            status = 1
            continue
        # A directory is scanned, never written: a bulk directory rewrite is
        # exactly the footgun this tool exists to avoid. Only single named
        # files are rewritten, one explicit decision at a time.
        write = not check and os.path.isfile(arg)
        scanned = 0
        failed = 0
        for path in markdown_files(arg):
            scanned += 1
            try:
                count = escape_file(path, write=write)
            except (OSError, UnicodeDecodeError, ValueError) as exc:
                print(f'{path}: {exc}', file=sys.stderr)
                failed += 1
                status = 1
                continue
            if write:
                print(f'{path}: {count} escapes')
            elif count:
                print(f'{path}: {count} unescaped currency $')
        if not write and scanned:
            ok = scanned - failed
            # The noun describes the total set, so pluralize from `scanned`.
            noun = 'file' if scanned == 1 else 'files'
            if failed:
                print(f'{ok} of {scanned} markdown {noun} scanned; see errors above', file=sys.stderr)
            else:
                print(f'{ok} markdown {noun} scanned')
    return status


if __name__ == '__main__':
    sys.exit(main())
