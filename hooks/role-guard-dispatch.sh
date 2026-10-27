#!/usr/bin/env bash
# Settings-level PreToolUse(Bash) dispatcher for the role guard (epic #16). Claude Code does not run a subagent's
# frontmatter hooks (verified 2026-10-27: an always-block frontmatter hook never fired, the subagent's command ran),
# but a settings-level hook runs for every Bash call and its input names the agent (agent_type). When that agent
# has a contract at agents/<agent_type>/ROLE.md in the skills checkout, the call goes through validate-role.sh;
# for every other agent, and for the main session, this is a silent no-op.
set -uo pipefail
input=$(cat)
# agent_type is read with jq when present, else with a plain pattern so a host without jq still routes role agents
# to the guard (which then fails closed on its own missing tools); a hook that cannot run at all would fail open
if command -v jq >/dev/null 2>&1; then agent=$(jq -r '.agent_type // empty' <<<"$input" 2>/dev/null) || agent=""
else agent=$(grep -oE '"agent_type":"[^"]*"' <<<"$input" | head -1 | sed -E 's/.*:"([^"]*)"/\1/'); fi
[[ "$agent" =~ ^[a-z][a-z-]*$ ]] || exit 0
checkout="${COORDINATOR_CHECKOUT:-${SKILLS_CHECKOUT:-$HOME/claude-code-skills}}"
[ -f "$checkout/agents/$agent/ROLE.md" ] || exit 0
guard="$checkout/hooks/validate-role.sh"
[ -x "$guard" ] || { echo "$agent: role contract found but no guard at $guard; refusing" >&2; exit 2; }
printf '%s' "$input" | ROLE="$agent" COORDINATOR_CHECKOUT="$checkout" "$guard"
