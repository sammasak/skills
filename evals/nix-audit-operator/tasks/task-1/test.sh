#!/usr/bin/env bash
set -euo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/verdict.md"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
first=$(grep -m1 -E '^Verdict:' "$OUTPUT" || true)
[[ "$first" == "Verdict: UNKNOWN" ]] || { echo "FAIL: missing scanner evidence must be UNKNOWN, got '$first'"; exit 1; }
grep -qiE 'grype' "$OUTPUT" || { echo "FAIL: must scope what was actually checked (grype only)"; exit 1; }
grep -qiE 'incomplete|vulnix' "$OUTPUT" || { echo "FAIL: must name the incomplete/failed scanner"; exit 1; }
echo PASS
