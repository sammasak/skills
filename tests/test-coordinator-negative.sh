#!/usr/bin/env bash
# Negative controls for the Coordinator surface (epic #16 M0): the portable
# permission rules must not be able to express code changes, pushes, merges,
# host switches, arbitrary SSH or the act-class herdr:message without a prompt.
# Run: bash tests/test-coordinator-negative.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/claude-permission-match.sh
. "$ROOT/tests/lib/claude-permission-match.sh"
P="$ROOT/agents/coordinator/permissions.json"
PASS=0; FAIL=0

expect() { # <want> <tool> <command>
  local got; got="$(permission_decision "$P" "$2" "${3:-}")"
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $2 '${3:-}' -> $got (want $1)"; fi
}

# read-class tasks are allowed without a prompt
expect allow Bash "devenv tasks run coord:brief"
expect allow Bash "devenv tasks run coord:brief --show-output"
expect allow Bash "devenv tasks run herdr:inspect --input-json '{\"host\":\"lenovo\",\"agent_id\":\"wF:p1\"}'"
expect allow Bash "devenv tasks run herdr:await --input-json '{\"host\":\"lenovo\",\"agent_id\":\"wF:p1\"}'"
expect allow Bash "timeout 60 devenv tasks run work:status"
expect allow Bash "timeout 60s devenv tasks run work:status"
expect allow Read

# act-class tasks always prompt
expect ask Bash "devenv tasks run herdr:message --input-json '{}'"
expect ask Bash "devenv tasks run coord:brief && devenv tasks run herdr:message --input-json '{}'"

# bypass attempts found in review: multi-task runs, option overrides, redirections, substitutions
expect none Bash "devenv tasks run coord:brief herdr:message"
expect none Bash "devenv tasks run coord:brief -O 'tasks.\"coord:brief\".exec:string' 'ssh lenovo id'"
expect none Bash "devenv tasks run coord:brief > ~/.ssh/authorized_keys"
expect deny Bash "devenv tasks run coord:brief \`ssh lenovo x\`"
expect deny Bash "devenv tasks run coord:brief \$(ssh h \"\$(id)\")"
expect none Bash "devenv tasks run coord:brief \$(cat ~/.ssh/id_ed25519)"
expect none Bash "devenv tasks run coord:brief &"
expect none Bash "devenv tasks run coord:brief |&"
# shellcheck disable=SC2088  # the literal tilde form is what an agent would type
expect deny Read "~/.ssh/id_ed25519"
expect deny Read "/run/secrets/claude_oauth_token"

# privileged or arbitrary operations are denied or at least never silently allowed
expect deny Bash "ssh lenovo rm -rf /"
expect deny Bash "git push origin main"
expect deny Bash "gh pr merge 16"
expect deny Bash "sudo nixos-rebuild switch --flake .#lenovo"
expect deny Bash "kubectl delete ns kanban"
expect deny Bash "rm -rf ~/skills-epic16"
expect deny Bash "devenv tasks run coord:brief; ssh lenovo true"
expect deny Bash "echo \$(ssh lenovo cat ~/.ssh/id_ed25519)"
expect deny Edit
expect deny Write
expect none Bash "cargo build --release"
expect none Bash "devenv tasks run skills:test"
expect none Bash "devenv tasks run coordinate"
expect none Bash "devenv tasks run coord:brief &&"

# the agent-scoped PreToolUse hook: strict grammar, allow for read tasks, ask for act tasks, block otherwise
HOOK="$ROOT/hooks/validate-coordinator.sh"
hook() { # <want: allow|ask|block> <command>
  local out code dec
  out=$(jq -cn --arg c "$2" '{session_id:"t",tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK" 2>/dev/null); code=$?
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
  if [ "$1" = block ]; then [ "$code" -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): '$2' -> exit $code dec=$dec (want block)"; }
  else [ "$code" -eq 0 ] && [ "$dec" = "$1" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): '$2' -> exit $code dec=$dec (want $1)"; }; fi
}
hook allow "devenv tasks run coord:brief"
hook allow "devenv tasks run coord:brief --show-output"
hook allow "devenv tasks run herdr:inspect --input-json '{\"host\":\"lenovo\",\"agent_id\":\"wF:p1\",\"lines\":40}'"
hook allow "devenv tasks run herdr:inventory --input-json '{\"host\":\"lenovo\"}' --show-output"
hook ask   "devenv tasks run herdr:message --input-json '{\"handoff_id\":\"abc\"}'"
hook block "devenv tasks run coord:brief herdr:message"
hook block "devenv tasks run coord:brief -O 'tasks.\"coord:brief\".exec:string' 'ssh lenovo id'"
hook block "devenv tasks run coord:brief > ~/.ssh/authorized_keys"
hook block "devenv tasks run coord:brief \`ssh lenovo x\`"
hook block "devenv tasks run coord:brief \$(id)"
hook block "devenv tasks run coord:brief; ssh lenovo true"
hook block "devenv tasks run coord:brief && ls"
hook block "devenv tasks run skills:test"
hook block "devenv tasks run coord:brief --input-json 'not json'"
hook block "devenv tasks run coord:brief --input-json '[1]'"
hook block "devenv tasks run coord:brief --input-json '{\"a\":\"x'\"'\"'y\"}'"
hook block "devenv --from path:/tmp/evil tasks run coord:brief"
hook block "timeout 60 devenv tasks run coord:brief"
hook block "ssh lenovo herdr agent list"
hook block "cat ~/.ssh/id_ed25519"
hook block $'devenv tasks run coord:brief\nssh lenovo id'
hook block ""

# the Claude adapter must not carry editing tools
if grep -qE '^\s*-\s*(Edit|Write|NotebookEdit)\s*$' <(awk '/^tools:/{f=1;next} /^[a-zA-Z]+:/{f=0} f' "$ROOT/agents/coordinator.md"); then
  FAIL=$((FAIL+1)); echo "FAIL: adapter lists an editing tool"
else PASS=$((PASS+1)); fi

# allow rules: never the `:*` suffix (Claude parses it as `name *`), and a wildcard only after --input-json
if jq -r '.allow[]' "$P" | grep -qE ':\*\)$'; then FAIL=$((FAIL+1)); echo "FAIL: an allow rule uses the ':*' suffix"; else PASS=$((PASS+1)); fi
if jq -r '.allow[]' "$P" | grep -E '\*' | grep -qvE -- "--input-json \*\)$"; then FAIL=$((FAIL+1)); echo "FAIL: an allow rule has a wildcard outside --input-json"; else PASS=$((PASS+1)); fi
# the hook's task lists equal the role contract
rtasks=$(yq --front-matter=extract -o=json '.' "$ROOT/agents/coordinator/ROLE.md" 2>/dev/null)
if [ -n "$rtasks" ]; then
  want_read=$(jq -r '.tasks.read|sort|join("|")' <<<"$rtasks"); want_act=$(jq -r '.tasks.act|sort|join("|")' <<<"$rtasks")
  have_read=$(grep -oE "^READ='[^']*'" "$HOOK" | sed -E "s/^READ='(.*)'$/\1/" | tr '|' '\n' | sort | paste -sd'|')
  have_act=$(grep -oE "^ACT='[^']*'" "$HOOK" | sed -E "s/^ACT='(.*)'$/\1/" | tr '|' '\n' | sort | paste -sd'|')
  [ "$want_read" = "$have_read" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: hook READ list ($have_read) != ROLE.md tasks.read ($want_read)"; }
  [ "$want_act" = "$have_act" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: hook ACT list ($have_act) != ROLE.md tasks.act ($want_act)"; }
else echo "note: yq missing, hook/ROLE list comparison skipped"; fi

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
