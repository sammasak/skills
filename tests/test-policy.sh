#!/usr/bin/env bash
# Policy gate: nothing an agent reads may let it stand in for the owner on
# privileged decisions (epic #16 M0). Run: bash tests/test-policy.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0

while IFS= read -r f; do
  if grep -nEi '\bstand(s|ing)?[- ]in\b|\bstood in\b|\bstand[- ]ins\b|acting for the owner' "$f"; then
    echo "FAIL: $f contains owner stand-in language" >&2; FAIL=1
  fi
done < <(find global-context.md README.md skills agents docs -type f -not -path 'docs/plans/*' -not -path '*/.archived/*')

if ! grep -qEi 'may not approve|cannot approve|AI review is evidence' "$ROOT/global-context.md"; then
  echo "FAIL: global-context.md does not state that agents cannot approve privileged actions" >&2; FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "PASS: policy gate" || exit 1
