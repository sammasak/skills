#!/usr/bin/env bash
set -euo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/rescan.md"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
line() { grep -m1 -E "^[-#*[:space:]]*$1:[*[:space:]]*" "$OUTPUT" | sed -E "s/^[-#*[:space:]]*$1:[*\`[:space:]]*//; s/[*\`[:space:]].*//" || true; }
[[ "$(line A)" == candidate-only ]] || { echo "FAIL: A: same revision, policy and scanners -> candidate-only rescan is valid (got '$(line A)')"; exit 1; }
[[ "$(line B)" == both ]] || { echo "FAIL: B: policy sha256 differs -> rescan both (got '$(line B)')"; exit 1; }
[[ "$(line C)" == both ]] || { echo "FAIL: C: scanner selection differs -> rescan both (got '$(line C)')"; exit 1; }
[[ "$(line 'C full coverage')" == no ]] || { echo "FAIL: C's kept snapshot ran grype only, so it is not grype+vulnix coverage"; exit 1; }
echo PASS
