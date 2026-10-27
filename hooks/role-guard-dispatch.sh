#!/usr/bin/env bash
# Settings-level PreToolUse(Bash) dispatcher for the role guard (epic #16). Claude Code does not run a subagent's
# frontmatter hooks (verified 2026-10-27: an always-block frontmatter hook never fired, the subagent's command ran),
# but a settings-level hook runs for every Bash call and its input names the agent (agent_type). The set of role
# agents is the one shipped NEXT TO THIS FILE (the copy nixos-config installs from the store, the same copy whose
# adapters got linked), so a missing or stale skills checkout refuses instead of silently un-guarding a role. The
# guard logic also runs from this copy; the checkout only supplies data (ROLE.md task lists, .integrity) and the
# devenv project the tasks run in. Every other agent, and the main session, is a silent no-op.
set -uo pipefail
export LC_ALL=C   # lowercasing and the [a-z] checks must not depend on the session locale
input=$(cat)
here=$(dirname "$(readlink -f "$0")")
# agent_type is read with jq when present, else with a plain pattern so a host without jq still routes role agents
# to the guard (which then fails closed on its own missing tools); a hook that cannot run at all would fail open
if command -v jq >/dev/null 2>&1; then agent=$(jq -r '.agent_type // empty' <<<"$input" 2>/dev/null) || agent=""
else agent=$(grep -oE '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$input" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'); fi
agent="${agent##*:}"   # a plugin-installed agent may report a namespaced type (unverified); the role name is the tail
agent="${agent,,}"     # an unexpected capitalisation resolves to the guarded role rather than slipping past
[[ "$agent" =~ ^[a-z][a-z-]*$ ]] || exit 0
# the grep fallback does not decode JSON escapes (\u0063…); the harness emits plain names, and jq is the normal path
# the checkout path is untrusted until the guard validates it; it is only probed for the contract file here
checkout="${COORDINATOR_CHECKOUT:-${SKILLS_CHECKOUT:-${HOME:-/nonexistent}/claude-code-skills}}"
shipped=0; [ -f "$here/../agents/$agent/ROLE.md" ] && shipped=1
present=0; [ -f "$checkout/agents/$agent/ROLE.md" ] && present=1
# an adapter that wires a role guard but ships no contract would otherwise be silently unguarded
if [ "$shipped" -eq 0 ] && [ "$present" -eq 0 ]; then
  if [ -f "$here/../agents/$agent.md" ] && grep -qE "validate-(role|$agent)\.sh" "$here/../agents/$agent.md"; then
    echo "$agent: adapter declares a role guard but ships no agents/$agent/ROLE.md; refusing" >&2; exit 2
  fi
  exit 0
fi
[ "$present" -eq 1 ] || { echo "$agent: the skills checkout $checkout has no agents/$agent/ROLE.md (missing or stale: git pull it, or set SKILLS_CHECKOUT); refusing" >&2; exit 2; }
guard="$here/validate-role.sh"
[ -x "$guard" ] || { echo "$agent: guard missing next to the dispatcher ($guard); refusing" >&2; exit 2; }
# only exit 2 blocks in Claude Code; a crash (1) or any other code would let the call through
printf '%s' "$input" | ROLE="$agent" COORDINATOR_CHECKOUT="$checkout" "$guard"; rc=${PIPESTATUS[1]}
[ "$rc" -eq 0 ] && exit 0
[ "$rc" -eq 2 ] || echo "$agent: guard failed (rc=$rc); refusing" >&2
exit 2
