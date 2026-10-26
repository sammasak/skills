#!/usr/bin/env bash
set -euo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/snapshot.sh"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
bash -n "$OUTPUT" || { echo "FAIL: not valid bash"; exit 1; }
code=$(grep -vE '^\s*#' "$OUTPUT")
if grep -q -- '--json-out' <<<"$code"; then echo "FAIL: uses --json-out, which the installed binary does not support"; exit 1; fi
grep -qE -- '--json([^-]|$)' <<<"$code" || { echo "FAIL: must use --json"; exit 1; }
grep -qE 'rm -f' <<<"$code" || { echo "FAIL: must remove stale snapshots before scanning"; exit 1; }
if grep -q -- '--gate' <<<"$code"; then echo "FAIL: ran a gate that was not asked for"; exit 1; fi
grep -q 'CANDIDATE' <<<"$code" || { echo "FAIL: must scan \$CANDIDATE"; exit 1; }
echo PASS
