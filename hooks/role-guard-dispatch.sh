#!/usr/bin/env bash
# The one shell file the roles keep: Claude Code hooks must be a command, and this runs on EVERY Bash call of
# every agent, so the no-op path must not start devenv. Settings-level PreToolUse(Bash): a subagent's own
# frontmatter hooks never run (verified 2026-10-27), but this hook does and its input names the agent
# (agent_type; ROLE_GUARD_AGENT covers the main-session `claude --agent <role>` case). For a role shipped next to
# this file (agents/<role>/ROLE.md) the decision is made by `devenv tasks run guard:check` in the skills checkout;
# everything else is a silent no-op. Only exit 2 blocks in Claude Code, so every failure path exits 2.
set -uo pipefail
export LC_ALL=C
input=$(cat)
here=$(dirname "$(readlink -f "$0")")
if command -v jq >/dev/null 2>&1; then agent=$(jq -r '.agent_type // empty' <<<"$input" 2>/dev/null) || agent=""
else agent=$(grep -oE '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$input" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'); fi
[ -n "$agent" ] || agent="${ROLE_GUARD_AGENT:-}"
agent="${agent##*:}"; agent="${agent,,}"
[[ "$agent" =~ ^[a-z][a-z-]*$ ]] || exit 0
checkout="${COORDINATOR_CHECKOUT:-${SKILLS_CHECKOUT:-${HOME:-/nonexistent}/claude-code-skills}}"
shipped=0; [ -f "$here/../agents/$agent/ROLE.md" ] && shipped=1
present=0; [ -f "$checkout/agents/$agent/ROLE.md" ] && present=1
if [ "$shipped" -eq 0 ] && [ "$present" -eq 0 ]; then
  if [ -f "$here/../agents/$agent.md" ] && grep -qE "role-guard-dispatch\.sh|validate-(role|$agent)\.sh" "$here/../agents/$agent.md"; then
    echo "$agent: adapter declares a role guard but ships no agents/$agent/ROLE.md; refusing" >&2; exit 2
  fi
  exit 0
fi
[ "$present" -eq 1 ] || { echo "$agent: the skills checkout $checkout has no agents/$agent/ROLE.md (missing or stale: git pull it, or set SKILLS_CHECKOUT); refusing" >&2; exit 2; }
[ -f "$checkout/devenv.nix" ] || { echo "$agent: $checkout has no devenv.nix; refusing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "$agent: jq is required to run the role guard; refusing" >&2; exit 2; }
df=$(mktemp) || { echo "$agent: cannot create a decision file; refusing" >&2; exit 2; }
errf=$(mktemp) || { rm -f "$df"; echo "$agent: cannot create a temp file; refusing" >&2; exit 2; }
trap 'rm -f "$df" "$errf"' EXIT
payload=$(jq -cn --arg r "$agent" --argjson h "$input" --arg f "$df" '{role:$r, hook:$h, decision_file:$f}' 2>/dev/null) || { echo "$agent: hook input is not JSON; refusing" >&2; exit 2; }
( cd "$checkout" && COORDINATOR_CHECKOUT="$checkout" devenv tasks run guard:check --input-json "$payload" ) >/dev/null 2>"$errf"; rc=$?
dec=$(jq -r '.decision // empty' "$df" 2>/dev/null); reason=$(jq -r '.reason // ""' "$df" 2>/dev/null)
case "$dec" in
  allow|ask) jq -cn --arg d "$dec" --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:$d, permissionDecisionReason:$r}}'; exit 0 ;;
  block) echo "$reason" >&2; exit 2 ;;   # the guard already names the role
  *) echo "$agent: guard did not decide (devenv rc=$rc): $(tail -c 400 "$errf" | tr '\n' ' ')" >&2; exit 2 ;;
esac
