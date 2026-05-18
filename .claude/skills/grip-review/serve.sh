#!/bin/bash
# ABOUTME: Launches ~/bin/grip in the background for a markdown file, prints a non-localhost URL,
# ABOUTME: and tracks the PID in a session-scoped state file so cleanup-grip.sh can reap it.

set -u
