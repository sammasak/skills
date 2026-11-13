#!/usr/bin/env bash
# PreToolUse Bash hook — fast-feedback speed bump for the four COMMON dangerous
# mistakes, NOT a security boundary. It deliberately does NOT chase exotic
# spellings, wrappers, block-device tools, remote exec, or impersonation; the
# real boundaries own all of that:
#   - git history: the pre-push ancestry guard runs INSIDE git's pre-push hook
#     and refuses every force / non-fast-forward / branch-deletion once it runs,
#     so this check is just early feedback. To skip it you skip the hook
#     entirely (`git push --no-verify`, or `-c core.hooksPath=`): the common
#     `--no-verify` spelling is denied at the permission layer (prefix-only);
#     other hook-skips stay the human's escape hatch, run by hand.
#   - cluster state: the fail-closed Kyverno policy denies PVC/PV/Namespace
#     (and the pruning Flux kinds) deletion; the operator is deliberately
#     cluster-admin, so impersonation / policy deletion are an accepted trade.
#   - everything else is UNOWNED by this hook, by design.
# Simplified 2026-10-12 from a 334-line spelling-matcher back to this: the arms
# race against adversarial spellings was itself slop. Quoted spans are replaced
# with a placeholder first so a MENTION (echo, commit message, grep pattern) is
# never blocked, while a quoted variable like "$TMP"/* does not collapse into a
# false root target.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/input.sh"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || true
read_hook_input
START_MS=$(($(date +%s%N) / 1000000))

CMD=$(hook_command)
[ -z "$CMD" ] && exit 0

block() {
  echo "BLOCKED: $1" >&2
  log_hook "validate-bash" "blocked" "$(( ($(date +%s%N) / 1000000) - START_MS ))" 2>/dev/null || true
  exit 2
}

SQ="'"
S=$(echo "$CMD" | sed -z "s/${SQ}[^${SQ}]*${SQ}/Q/g; s/\"[^\"]*\"/Q/g")

# 1. git force-push (common spelling only; the pre-push ancestry guard is the
#    real backstop and catches every other spelling).
if echo "$S" | grep -qE "git[[:space:]]+([^|&;]+[[:space:]]+)?push([[:space:]][^|&;]*)?([[:space:]]--force([^-]|\$)|[[:space:]]-[A-Za-z]*f[A-Za-z]*([[:space:]]|\$)|[[:space:]][+][^[:space:]])"; then
  block "force push is not allowed; revert with a new commit or push a branch (the pre-push guard also refuses it once it runs)."
fi

# 2. recursive rm of a filesystem root or whole home — the catastrophic accident.
if echo "$S" | grep -qE "(^|[|&;[:space:]])(sudo[[:space:]]+)?rm[[:space:]]+[^|&;]*-[A-Za-z]*r[A-Za-z]*[^|&;]*[[:space:]](/|/\*|~|\\\$HOME|/home/[A-Za-z0-9._-]+|/(etc|nix|var|usr|boot|opt|srv|root))(/\*?)?([[:space:]]|\$)"; then
  block "recursive rm of a filesystem root or whole home is not allowed."
fi

# 3. destructive kubectl delete of a stateful kind (Kyverno also denies these).
#    A dry run deletes nothing, so a segment (split on | & ; newline) that is a
#    plain dry run is dropped before the check: exactly one dry-run flag, spelled
#    --dry-run=server or --dry-run=client, and nothing in the segment that could
#    hide or override it (quotes, variables, comments, redirects, escapes, a bare
#    `--`; only a trailing 2>&1 is tolerated). Every other segment is checked as
#    before, so a real delete next to a dry run is still blocked.
KDEL="kubectl[[:space:]]+([^|&;]+[[:space:]]+)?delete[[:space:]]+([^|&;]*[[:space:]])?(pvc|persistentvolumeclaims?|persistentvolumes?|pv|namespaces?|ns)([[:space:]]|\$)"
if echo "$S" | grep -qiE "$KDEL"; then
  # Quotes become a quote character here (not Q), so a quoted span fails the
  # plain-characters test below instead of passing as a literal letter.
  # Continuation lines are joined so a delete split over two lines is still seen.
  K=$(echo "$CMD" | sed -z "s/${SQ}[^${SQ}]*${SQ}/${SQ}/g; s/\"[^\"]*\"/${SQ}/g; s/\\\\\\n/ /g" | tr '|&' ';;')
  REST=""
  while IFS= read -r line || [ -n "$line" ]; do
    while :; do
      seg="${line%%;*}"
      core=$(echo "$seg" | sed -E 's/[[:space:]]2>[[:space:]]*$//')
      if echo "$core" | grep -qiE "$KDEL" \
        && echo "$core" | grep -qE '^[A-Za-z0-9_./:=,@[:space:]-]*$' \
        && ! echo "$core" | grep -qE '(^|[[:space:]])--([[:space:]]|$)' \
        && [ "$(echo "$core" | grep -oiE 'dry-?run' | wc -l)" -eq 1 ] \
        && echo "$core" | grep -qE '[[:space:]]--dry-run=(server|client)([[:space:]]|$)'; then
        seg=""
      fi
      REST+="$seg"
      [ "$line" = "${line#*;}" ] && break
      REST+=";"
      line="${line#*;}"
    done
    REST+=$'\n'
  done <<<"$K"
  if echo "$REST" | grep -qiE "$KDEL"; then
    block "destructive kubectl delete (pvc/pv/namespace) needs the human; Kyverno also denies it. A plain --dry-run=server or --dry-run=client run of it is allowed."
  fi
fi

# 4. SOPS encrypt from /tmp loses the repo's recipient set.
if echo "$S" | grep -qE "sops[^|&;]*([[:space:]]-e([[:space:]]|\$)|[[:space:]]--encrypt([[:space:]]|\$)|[[:space:]]encrypt[[:space:]])[^|&;]*/tmp/"; then
  block "SOPS encrypt from /tmp is unsafe; write to the repo path, then sops -e --in-place."
fi

log_hook "validate-bash" "allowed" "$(( ($(date +%s%N) / 1000000) - START_MS ))" 2>/dev/null || true
exit 0
