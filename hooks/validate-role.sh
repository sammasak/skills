#!/usr/bin/env bash
# PreToolUse(Bash) guard shared by every role (epic #16). ROLE names the role
# whose contract is read from agents/$ROLE/ROLE.md inside $COORDINATOR_CHECKOUT:
# the `tasks.read`/`tasks.run` lists are allowed, `tasks.act` asks, everything
# else is blocked. The whole command must match one strict form:
#   devenv tasks run <task> [--input-json '<json object>'] [--show-output]
# and the call must come from the checkout. Text matching is a guardrail; the OS
# boundary is nixos-config's job. The adapter's hook command refuses every Bash
# call when this file is missing (fail closed).
set -uo pipefail
ROLE="${ROLE:-coordinator}"

input=$(cat)
jq -e '(.tool_input.command // "") | explode | all(. >= 32 and . != 127)' <<<"$input" >/dev/null 2>&1 \
  || { echo "$ROLE: control characters or unparseable input" >&2; exit 2; }
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || cmd=""
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || cwd=""
[ -n "$cmd" ] || { echo "$ROLE: empty Bash command" >&2; exit 2; }
[ -n "$cwd" ] || { echo "$ROLE: hook input carries no cwd" >&2; exit 2; }

[ -n "${COORDINATOR_CHECKOUT:-}" ] || { echo "$ROLE: COORDINATOR_CHECKOUT is not set; refusing to run tasks from an unknown checkout" >&2; exit 2; }
want=$(readlink -e "$COORDINATOR_CHECKOUT" 2>/dev/null) || { echo "$ROLE: COORDINATOR_CHECKOUT does not exist" >&2; exit 2; }
if [ "$(readlink -e "$cwd" 2>/dev/null)" != "$want" ]; then
  echo "$ROLE: tasks may only run from $COORDINATOR_CHECKOUT (cwd: ${cwd:-unknown})" >&2; exit 2
fi

role_md="$want/agents/$ROLE/ROLE.md"
[ -r "$role_md" ] || { echo "$ROLE: no role contract at $role_md" >&2; exit 2; }
# frontmatter lists under tasks: (read|run|act), one `- name` per line
role_list() { # <key> -> a|b|c
  awk -v key="$1" '
    /^---$/ { fm++; next } fm != 1 { next }
    /^tasks:/ { intasks=1; next }
    intasks && /^[A-Za-z]/ { intasks=0 }
    intasks && $1 ~ /^(read|run|act|inputless):$/ { cur=$1; sub(":","",cur); next }
    intasks && cur == key && $1 == "-" { print $2 }
  ' "$role_md" | paste -sd'|' -
}
READ=$(role_list read); RUN=$(role_list run); ACT=$(role_list act)
allow_re="${READ}${RUN:+|$RUN}"
[ -n "$allow_re" ] || { echo "$ROLE: role contract lists no tasks" >&2; exit 2; }

re="^devenv tasks run (${allow_re}${ACT:+|$ACT})( --input-json '([^']*)')?( --show-output)?\$"
if [[ ! "$cmd" =~ $re ]]; then
  echo "$ROLE: only 'devenv tasks run <allowed task> [--input-json '<json>'] [--show-output]' is permitted" >&2; exit 2
fi
# The anchored regex leaves no room for metacharacters outside the quoted body.
task="${BASH_REMATCH[1]}"; input_arg="${BASH_REMATCH[2]:-}"; body="${BASH_REMATCH[3]:-}"
if [ -n "$input_arg" ] && ! jq -se 'length == 1 and (.[0] | type == "object")' <<<"$body" >/dev/null 2>&1; then
  echo "$ROLE: --input-json must be exactly one JSON object literal" >&2; exit 2
fi

decision=allow; [ -n "$ACT" ] && [[ "$task" =~ ^(${ACT})$ ]] && decision=ask
jq -cn --arg d "$decision" --arg t "$task" --arg r "$ROLE" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:($r + " task " + $t + " (" + $d + ")")}}'
