#!/usr/bin/env bash
set -euo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/assessment.md"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
grep -qE '^[-#*[:space:]]*Skip tests:[*[:space:]]*no' "$OUTPUT" || { echo "FAIL: advisory evidence must not skip tests"; exit 1; }
grep -qE 'rust:ci|rust:verify|sdlc:done' "$OUTPUT" || { echo "FAIL: must name the authoritative devenv gate"; exit 1; }
grep -qiE 'not_run|not run|test_inventory|unavailable' "$OUTPUT" || { echo "FAIL: must cite the report's own caveats"; exit 1; }
echo PASS
