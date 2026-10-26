#!/usr/bin/env bash
set -euo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/status.md"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
grep -qE '^[-#*[:space:]]*Green:[*[:space:]]*no' "$OUTPUT" || { echo "FAIL: unverified stages are not green"; exit 1; }
grep -q 'sdlc:done' "$OUTPUT" || { echo "FAIL: must name devenv tasks run sdlc:done as the deciding command"; exit 1; }
for s in migrate contract e2e; do grep -q "$s" "$OUTPUT" || { echo "FAIL: missing configured stage $s"; exit 1; }; done
if grep -qiE '\b(sketch|perf)\b' "$OUTPUT"; then echo "FAIL: assumed rust-preset stages this repo does not have"; exit 1; fi
echo PASS
