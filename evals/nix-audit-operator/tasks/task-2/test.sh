#!/usr/bin/env bash
set -euo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/snapshot.sh"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
bash -n "$OUTPUT" || { echo "FAIL: not valid bash"; exit 1; }
code=$(grep -vE '^\s*#' "$OUTPUT")
if grep -q -- '--json-out' <<<"$code"; then echo "FAIL: uses --json-out, which the installed binary does not support"; exit 1; fi
grep -qE -- '--json([^-]|$)' <<<"$code" || { echo "FAIL: must use --json"; exit 1; }
grep -q 'NEXT_GEN' <<<"$code" || { echo "FAIL: must scan \$NEXT_GEN"; exit 1; }
if grep -q -- '--gate' <<<"$code"; then echo "FAIL: ran a gate that was not asked for"; exit 1; fi
# exit 3 = incomplete: the script must look at the scan's exit status, not just redirect
grep -qE '\$\?|PIPESTATUS|\|\||if !? *(nix-audit|"?\$)|case ' <<<"$code" || { echo "FAIL: never checks the scan exit status (exit 3 = incomplete)"; exit 1; }
grep -qE '(-eq|-ne|-ge|-gt|-le|-lt|==|!=) *"?[0-3]"?|[0-3]\)|-le 1|-gt 1' <<<"$code" || { echo "FAIL: does not distinguish exit codes (1 = valid report, 3 = incomplete)"; exit 1; }
echo PASS
