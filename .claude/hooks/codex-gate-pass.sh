#!/usr/bin/env bash
# ABOUTME: No-op PostToolUse hook kept for legacy settings compatibility. The
# ABOUTME: wrapper now promotes its hash-keyed sentinel directly; this is dead.

# codex-review-capture used to leave a staged file behind and rely on this
# hook to read its stderr, find the `staged=...` marker, and `mv` the file to
# a session_id-keyed sentinel that the gate would later consume. With the
# hash-keyed sentinel design (filename encodes sha256 of the reviewed diff),
# the wrapper writes its own final sentinel and this hook has nothing to do.
# Kept as a no-op so existing settings.json entries don't fail loudly.
exit 0
