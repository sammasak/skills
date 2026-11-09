#!/usr/bin/env bash
# PreToolUse Bash hook, worker hosts only (skills#28): the merge review gate; the logic and its trust model
# are in check-merge.py (shlex parsing). Needs python3 and gh on PATH (the nixos-config registration sets it).
exec python3 "$(cd "$(dirname "$0")" && pwd)/check-merge.py"
