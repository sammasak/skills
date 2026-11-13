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
#    A dry run deletes nothing, so it is exempt, but only when the WHOLE raw
#    command is one plain kubectl call that fits the strict grammar below; no
#    compound command, pipe, redirect, quote, variable or newline ever fits.
#    Everything else that matches is blocked as before (fail closed).
KDEL="kubectl[[:space:]]+([^|&;]+[[:space:]]+)?delete[[:space:]]+([^|&;]*[[:space:]])?(pvc|persistentvolumeclaims?|persistentvolumes?|pv|namespaces?|ns)([[:space:]]|\$)"

# Grammar (byte-wise, LC_ALL=C, tokens split by exactly one ASCII space):
#   kubectl FLAG* delete (WORD|FLAG)+
#   WORD  bare word (kind, name); never starts with `-`
#   FLAG  `-n WORD`, or an attached-value flag from a fixed list. No other
#         token may start with `-`, so no flag can take the next token as its
#         value and no second spelling of the dry-run flag can override it.
# plus exactly one dry-run mention (--dry-run=server|client) and one `delete`.
kubectl_delete_is_dry_run() {
  local LC_ALL=C
  local w='[A-Za-z0-9][A-Za-z0-9._/-]*' v='[A-Za-z0-9._:/-]+' f re t n=0
  f="(-n $w|--(namespace|as|as-group|context|output)=$v|--dry-run=(server|client))"
  re="^kubectl( $f)* delete( ($w|$f))+\$"
  [[ "$CMD" =~ $re ]] || return 1
  [ "$(echo "$CMD" | grep -oiE 'dry[-_]?run' | wc -l)" -eq 1 ] || return 1
  [[ "$CMD" == *" --dry-run="* ]] || return 1
  for t in $CMD; do
    [ "$t" = delete ] && n=$((n + 1))
  done
  [ "$n" -eq 1 ]
}

if echo "$S" | grep -qiE "$KDEL" && ! kubectl_delete_is_dry_run; then
  block "destructive kubectl delete (pvc/pv/namespace) needs the human; Kyverno also denies it. Only a single plain dry run is allowed: kubectl [-n NS] delete KIND NAME --dry-run=server|client [--as=USER], with no pipe, redirect, quote or other flag."
fi

# 4. SOPS encrypt from /tmp loses the repo's recipient set.
if echo "$S" | grep -qE "sops[^|&;]*([[:space:]]-e([[:space:]]|\$)|[[:space:]]--encrypt([[:space:]]|\$)|[[:space:]]encrypt[[:space:]])[^|&;]*/tmp/"; then
  block "SOPS encrypt from /tmp is unsafe; write to the repo path, then sops -e --in-place."
fi

log_hook "validate-bash" "allowed" "$(( ($(date +%s%N) / 1000000) - START_MS ))" 2>/dev/null || true
exit 0
