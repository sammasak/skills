#!/usr/bin/env bash
# PreToolUse(Bash) guard scoped to the Coordinator agent (agents/coordinator.md
# frontmatter). The whole command must match one strict form:
#   devenv tasks run <task> [--input-json '<json>'] [--show-output]
# read tasks  -> permissionDecision allow (a settings deny still wins)
# act tasks   -> permissionDecision ask (the owner confirms in the prompt)
# anything else -> exit 2, blocked. Text matching is a guardrail; the OS boundary
# is nixos-config's job.
set -uo pipefail
READ='coord:brief|coord:handoff|herdr:inventory|herdr:inspect|herdr:await|harness:session-summary|gh:work|git:recent|work:status'
ACT='herdr:message'

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || cmd=""
[ -n "$cmd" ] || { echo "coordinator: empty or unparseable Bash command" >&2; exit 2; }

if [[ "$cmd" == *$'\n'* ]] || [[ "$cmd" =~ [\`\$\<\>\;\|\&] ]]; then
  echo "coordinator: shell metacharacters, substitutions, redirections and chaining are not allowed" >&2; exit 2
fi

re="^devenv tasks run (${READ}|${ACT})( --input-json '([^']*)')?( --show-output)?\$"
if [[ ! "$cmd" =~ $re ]]; then
  echo "coordinator: only 'devenv tasks run <allowed task> [--input-json '<json>'] [--show-output]' is permitted" >&2; exit 2
fi
task="${BASH_REMATCH[1]}"; body="${BASH_REMATCH[3]:-}"
if [ -n "${BASH_REMATCH[2]:-}" ] && ! jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1; then
  echo "coordinator: --input-json must be a single JSON object literal" >&2; exit 2
fi

decision=allow; [[ "$task" =~ ^(${ACT})$ ]] && decision=ask
jq -cn --arg d "$decision" --arg t "$task" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:("coordinator task " + $t + " (" + $d + ")")}}'
