#!/usr/bin/env bash
# Drives work:status and coord:brief end to end over fake herdr/gh and a throwaway checkout.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
run() { # <task> <fleet> [args]
  local task="$1" fleet="$2"; shift 2
  devenv tasks run "$task" --option coordinator.fleetFile:path "$fleet" --option coordinator.ghCommand:string "$FX/bin/gh" \
    --option coordinator.sshCommand:string "$FX/bin/ssh" --option coordinator.herdrCommand:string "$FX/bin/herdr" \
    --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 1 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
  if [ "$task" = coord:brief ] && [ -r "$TMP/state/brief/latest.json" ] && [ "$CODE" -eq 0 ]; then OUT=$(cat "$TMP/state/brief/latest.json")
  else OUT=$(grep -E "^\s*\{\"schema_version\":1,\"task\":\"$task\"" "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); fi
  [ -n "$OUT" ] || OUT='{}'
}
jqr() { jq -r "$1" <<<"$OUT"; }

git init -q "$TMP/herman" && (cd "$TMP/herman" && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm init && echo dirty > b)
# fixture agents: wF:p1 working on #16 (open PR 17 => unverified); wT:p1 "done" on #42 (merged PR 15 => verified); remote blocked agent (no ref)
jq --arg cwd "$TMP/herman" '.result.agents[1].cwd = $cwd' "$FX/herdr/local-two-agents.json" > "$TMP/local.json"
printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[{"name":"skills","gh":"sammasak/skills","checkout":"%s"}]}' "$TMP/herman" > "$TMP/fleet.json"

FAKE_HERDR_LIST="$TMP/local.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run coord:brief "$TMP/fleet.json"
[ "$CODE" -eq 0 ] && ok || bad "brief: exit $CODE ($(grep -E 'FAIL|✖|error' "$TMP/run.log" | head -3))"
[ "$(jqr '.items|length')" = 3 ] && ok || bad "brief: 3 agents ($OUT)"
[ "$(jqr '.items[] | select(.agent_id=="wF:p1") | .work_verdict')" = unverified ] && ok || bad "wF:p1 open PR => unverified"
[ "$(jqr '.items[] | select(.agent_id=="wF:p1") | .herdr_state')" = working ] && ok || bad "wF:p1 herdr_state kept separately"
[ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = verified ] && ok || bad "wT:p1 done + merged PR => verified"
[ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .evidence_ref')" = "https://github.com/sammasak/skills/pull/15" ] && ok || bad "wT:p1 evidence_ref"
jqr '.items[] | select(.agent_id=="wT:p1") | .reasons | join(";")' | grep -q 'uncommitted' && ok || bad "wT:p1 dirty checkout noted"
[ "$(jqr '.items[] | select(.agent_id=="wA:p2") | .work_verdict')" = blocked ] && ok || bad "blocked agent => blocked verdict"
[ "$(jqr '.items[] | select(.agent_id=="wA:p2") | .needs_owner')" = true ] && ok || bad "blocked agent needs owner"
[ "$(jqr .partial)" = false ] && ok || bad "all sources fine => not partial"
grep -q '## Needs you' "$TMP/run.log" && grep -q 'lenovo/wA:p2' "$TMP/run.log" && ok || bad "markdown brief lists the blocked agent under Needs you"
[ "$(jqr '[.items[].sources[].task] | unique | join(",")')" = "gh:work,git:recent,herdr:inventory" ] && ok || bad "sources listed"

# a "done" agent whose reference has no merged PR is never verified
jq '.result.agents[1].terminal_title_stripped = "herman #16 settlement"' "$TMP/local.json" > "$TMP/local16.json"
FAKE_HERDR_LIST="$TMP/local16.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
[ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unverified ] && ok || bad "done without merged PR must stay unverified"

# gh down: brief still renders from herdr, marked partial with the failed source
FAKE_GH_EXIT=1 FAKE_HERDR_LIST="$TMP/local.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run coord:brief "$TMP/fleet.json"
[ "$CODE" -eq 0 ] && ok || bad "gh down: brief must still succeed (exit $CODE)"
[ "$(jqr .partial)" = true ] && ok || bad "gh down: partial"
jqr '.failed_sources[].source' | grep -q 'gh:work' && ok || bad "gh down: failed source named"
[ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unknown ] && ok || bad "gh down: verdict unknown, not verified"
grep -q 'Partial:' "$TMP/run.log" && ok || bad "gh down: markdown says Partial"
grep -q 'Full JSON: ' "$TMP/run.log" && ok || bad "brief points at the saved JSON"

# herdr down everywhere: no items, inventory failed, work:status exits 2, brief fails honestly
printf '{"schema_version":1,"hosts":[{"name":"gone","ssh":"lukas@down.lan"}],"repos":[]}' > "$TMP/down.json"
run coord:brief "$TMP/down.json"
[ "$CODE" -ne 0 ] && ok || bad "herdr down: brief must fail"
grep -qE 'herdr:inventory.*unreachable|missing' "$TMP/run.log" && ok || bad "herdr down: reason surfaced"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
