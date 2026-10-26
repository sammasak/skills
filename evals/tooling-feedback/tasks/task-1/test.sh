#!/usr/bin/env bash
set -euo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/routing.md"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
want=( "" "sammasak/nixos-config" "sammasak/factum" "sammasak/skills" "sammasak/devenv-platform" "sammasak/homelab-gitops" )
for i in 1 2 3 4 5; do
  got=$(grep -m1 -E "^\s*$i:" "$OUTPUT" | sed -E "s/^\s*$i:\s*//; s/[\`* ]//g" || true)
  [[ "$got" == "${want[$i]}" ]] || { echo "FAIL: case $i routed to '$got', want ${want[$i]}"; exit 1; }
done
echo PASS
