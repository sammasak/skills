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
expect allow Bash "timeout 60 devenv tasks run work:status"
expect allow Read

# act-class tasks always prompt
expect ask Bash "devenv tasks run herdr:message --input-json '{}'"
expect ask Bash "devenv tasks run herdr:await --input-json '{}'"
expect ask Bash "devenv tasks run coord:brief && devenv tasks run herdr:message"

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

# the Claude adapter must not carry editing tools
if grep -qE '^\s*-\s*(Edit|Write|NotebookEdit)\s*$' <(awk '/^tools:/{f=1;next} /^[a-zA-Z]+:/{f=0} f' "$ROOT/agents/coordinator.md"); then
  FAIL=$((FAIL+1)); echo "FAIL: adapter lists an editing tool"
else PASS=$((PASS+1)); fi

# every allow rule must end in `<name>*`, never `:*` (which Claude parses as `name *`)
if jq -r '.allow[]' "$P" | grep -qE ':\*\)$'; then FAIL=$((FAIL+1)); echo "FAIL: an allow rule uses the ':*' suffix"; else PASS=$((PASS+1)); fi

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
