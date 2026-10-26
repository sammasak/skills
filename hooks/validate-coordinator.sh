#!/usr/bin/env bash
# PreToolUse(Bash) guard scoped to the Coordinator agent (agents/coordinator.md
# frontmatter). The whole command must match one strict form:
#   devenv tasks run <task> [--input-json '<json>'] [--show-output]
# read tasks  -> permissionDecision allow (a settings deny still wins)
# act tasks   -> permissionDecision ask (the owner confirms in the prompt)
# anything else -> exit 2, blocked. The call must come from the coordinator
# checkout ($COORDINATOR_CHECKOUT, set by the launcher) so `devenv tasks run`
# resolves our devenv.nix and not another project's. Text matching is a
# guardrail; the OS boundary is nixos-config's job. If this hook is not
# installed, Claude falls through to the settings rules, which allow only the
# input-less exact forms, so a missing guard degrades to prompting, not to open.
set -uo pipefail
READ='coord:brief|coord:handoff|herdr:inventory|herdr:inspect|herdr:await|harness:session-summary|gh:work|git:recent|work:status'
ACT='herdr:message'

input=$(cat)
jq -e '(.tool_input.command // "") | explode | all(. >= 32 and . != 127)' <<<"$input" >/dev/null 2>&1 \
  || { echo "coordinator: control characters or unparseable input" >&2; exit 2; }
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || cmd=""
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || cwd=""
[ -n "$cmd" ] || { echo "coordinator: empty Bash command" >&2; exit 2; }
[ -n "$cwd" ] || { echo "coordinator: hook input carries no cwd" >&2; exit 2; }

[ -n "${COORDINATOR_CHECKOUT:-}" ] || { echo "coordinator: COORDINATOR_CHECKOUT is not set; refusing to run tasks from an unknown checkout" >&2; exit 2; }
want=$(readlink -e "$COORDINATOR_CHECKOUT" 2>/dev/null) || { echo "coordinator: COORDINATOR_CHECKOUT does not exist" >&2; exit 2; }
if [ "$(readlink -e "$cwd" 2>/dev/null)" != "$want" ]; then
  echo "coordinator: tasks may only run from $COORDINATOR_CHECKOUT (cwd: ${cwd:-unknown})" >&2; exit 2
fi

re="^devenv tasks run (${READ}|${ACT})( --input-json '([^']*)')?( --show-output)?\$"
if [[ ! "$cmd" =~ $re ]]; then
  echo "coordinator: only 'devenv tasks run <allowed task> [--input-json '<json>'] [--show-output]' is permitted" >&2; exit 2
fi
# The anchored regex leaves no room for metacharacters outside the quoted body.
task="${BASH_REMATCH[1]}"; input_arg="${BASH_REMATCH[2]:-}"; body="${BASH_REMATCH[3]:-}"
if [ -n "$input_arg" ] && ! jq -se 'length == 1 and (.[0] | type == "object")' <<<"$body" >/dev/null 2>&1; then
  echo "coordinator: --input-json must be exactly one JSON object literal" >&2; exit 2
fi

decision=allow; [[ "$task" =~ ^(${ACT})$ ]] && decision=ask
jq -cn --arg d "$decision" --arg t "$task" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:("coordinator task " + $t + " (" + $d + ")")}}'
