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
[[ "$ROLE" =~ ^[a-z][a-z-]*$ ]] || { echo "guard: ROLE must be a lowercase role name" >&2; exit 2; }

input=$(cat)
# the session cwd, the command and every working-directory field must be strings free of control characters
# (a newline-only workdir would read as empty and skip the directory check; a trailing newline in cwd would
# be stripped by $(...) and compare equal to the checkout)
jq -e '[.cwd, .tool_input.command, .tool_input.workdir, .tool_input.cwd, .tool_input.working_directory, .tool_input.working_dir]
       | map(select(. != null)) | all(type == "string" and (explode | all(. >= 32 and . != 127)))' <<<"$input" >/dev/null 2>&1 \
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
# a harness may run one call from another directory (Codex's per-call workdir); a planted devenv.nix in a
# subdirectory would then evaluate instead of the checkout's, so any such field must name the checkout too
# every such field present is checked; a relative one resolves against the session cwd the harness reported
while IFS= read -r wd; do
  [ -n "$wd" ] || continue
  if [ "$(cd -- "$cwd" 2>/dev/null && readlink -e -- "$wd" 2>/dev/null)" != "$want" ]; then
    echo "$ROLE: the call's working directory must be $COORDINATOR_CHECKOUT (workdir: $wd)" >&2; exit 2
  fi
done < <(jq -r '.tool_input | (.workdir, .cwd, .working_directory, .working_dir) | select(. != null) | tostring' <<<"$input" 2>/dev/null)

role_md="$want/agents/$ROLE/ROLE.md"
[ -r "$role_md" ] || { echo "$ROLE: no role contract at $role_md" >&2; exit 2; }
# An installed checkout carries .integrity (sha256 of the roots in hooks/lib/integrity-paths). A managed session
# (the launcher sets COORDINATOR_REQUIRE_INTEGRITY=1 and pins the manifest's own hash in COORDINATOR_INTEGRITY_SHA256,
# kept outside the checkout) needs both: a missing manifest, a missing pin, a rewritten manifest, a changed listed
# file, or an unlisted policy file (devenv.local.*, .claude/settings*.json, AGENTS*.md, CLAUDE.md, .mcp.json,
# .codex/*) all block every call. Without the launcher a present
# manifest is still checked. The predicate lives in lib/integrity-check.sh, shared with the nixos-config activation.
here="$(dirname "$(readlink -f "$0")")"
if { [ -n "${COORDINATOR_REQUIRE_INTEGRITY:-}" ] && [ "${COORDINATOR_REQUIRE_INTEGRITY}" != 0 ]; } || [ -n "${COORDINATOR_INTEGRITY_SHA256:-}" ]; then
  [ -f "$want/.integrity" ] || { echo "$ROLE: no .integrity manifest in $want; refusing (managed session)" >&2; exit 2; }
  [[ "${COORDINATOR_INTEGRITY_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || { echo "$ROLE: managed session without a valid integrity pin; refusing" >&2; exit 2; }
fi
if [ -f "$want/.integrity" ]; then
  msg=$("$here/lib/integrity-check.sh" "$want" "${COORDINATOR_INTEGRITY_SHA256:--}" "$ROLE" 2>&1) || { echo "$ROLE: $msg; refusing" >&2; exit 2; }
fi

role_list() { local out; out=$(awk -v key="$1" -f "$here/lib/role-list.awk" "$role_md") || return 3; paste -sd'|' - <<<"$out"; }
READ=$(role_list read) || { echo "$ROLE: role contract rejected by the guard parser" >&2; exit 2; }
RUN=$(role_list run) || { echo "$ROLE: role contract rejected by the guard parser" >&2; exit 2; }
ACT=$(role_list act) || { echo "$ROLE: role contract rejected by the guard parser" >&2; exit 2; }
allow_re="${READ}${RUN:+${READ:+|}$RUN}"
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
