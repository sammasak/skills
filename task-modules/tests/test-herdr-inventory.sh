#!/usr/bin/env bash
# Drives the real herdr:list:<host> / herdr:inventory tasks with fixture fleets and
# fake ssh/herdr injected through devenv options. Run from the repo root inside
# the devenv: bash task-modules/tests/test-herdr-inventory.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FAKE_LOG="$TMP/calls.log"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
fleet() { printf '{"schema_version":1,"hosts":%s,"repos":[]}' "$2" > "$1"; }
# run <fleet-file> [extra devenv args...]: OUT = herdr:inventory output, CODE = devenv exit
run() {
  local f="$1"; shift
  local log="$TMP/run.log"
  devenv tasks run herdr:inventory --option coordinator.fleetFile:path "$f" \
    --option coordinator.sshCommand:string "$FX/bin/ssh" --option coordinator.herdrCommand:string "$FX/bin/herdr" \
    --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 1 --show-output "$@" > "$log" 2>&1; CODE=$?
  OUT=$(grep -E '^\s*\{"schema_version":1' "$log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
}
jqr() { jq -r "$1" <<<"$OUT"; }

# 1. local host only: both fixture agents become records
fleet "$TMP/local.json" '[{"name":"acer-swift","ssh":null}]'
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/local.json"
[ "$CODE" -eq 0 ] && ok || bad "local: exit $CODE"
[ "$(jqr .schema_version)" = 1 ] && ok || bad "local: schema_version"
[ "$(jqr '.hosts[0].agents|length')" = 2 ] && ok || bad "local: 2 agents ($OUT)"
[ "$(jqr '.hosts[0].agents[0].agent_id')" = "wF:p1" ] && ok || bad "local: agent_id"
[ "$(jqr '.hosts[0].agents[0].observed_state')" = working ] && ok || bad "local: observed_state"
[ "$(jqr '.hosts[0].agents[0].harness')" = claude ] && ok || bad "local: harness"
[ "$(jqr '.hosts[0].agents[0].session_id')" = "11111111-1111-4111-8111-111111111111" ] && ok || bad "local: session_id"
[ "$(jqr '.hosts[0].agents[0].task_ref')" = "#16" ] && ok || bad "local: task_ref"
[ "$(jqr '.hosts[0].agents[1].observed_state')" = "done" ] && ok || bad "local: second state"
[ "$(jqr '.hosts[0].agents[1].approval_required')" = false ] && ok || bad "local: done is not approval_required"
[ "$(jqr '.hosts[0].agents[0].stale')" = false ] && ok || bad "local: fresh read not stale"
[ "$(jqr .partial)" = false ] && ok || bad "local: partial"
grep -q '^ssh' "$FAKE_LOG" && bad "local: ssh must not be called for a local host" || ok

# 2. state_age_s grows while state_change_seq is unchanged; resets when it changes
sleep 1
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/local.json"
age=$(jqr '.hosts[0].agents[0].state_age_s'); [ "$age" -ge 1 ] 2>/dev/null && ok || bad "age: expected >=1, got $age"
jq '.result.agents[0].state_change_seq = 999' "$FX/herdr/local-two-agents.json" > "$TMP/changed.json"
FAKE_HERDR_LIST="$TMP/changed.json" run "$TMP/local.json"
[ "$(jqr '.hosts[0].agents[0].state_age_s')" = 0 ] && ok || bad "age: expected reset to 0"

# 3. remote host over fake ssh; blocked agent is approval_required
fleet "$TMP/remote.json" '[{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
FAKE_HERDR_LIST="$FX/herdr/remote-ok.json" run "$TMP/remote.json"
[ "$CODE" -eq 0 ] && ok || bad "remote: exit $CODE"
grep -q '^ssh .*-- lukas@lenovo.lan herdr agent list' "$FAKE_LOG" && ok || bad "remote: expected ssh <target> herdr agent list"
[ "$(jqr '.hosts[0].agents[0].approval_required')" = true ] && ok || bad "remote: blocked => approval_required"
[ "$(jqr '.hosts[0].agents[0].host')" = lenovo ] && ok || bad "remote: host field"

# 4. one host times out: its error is reported, the other host still returned, exit 0, partial true
fleet "$TMP/mixed.json" '[{"name":"acer-swift","ssh":null},{"name":"slow","ssh":"lukas@timeout.lan"}]'
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/mixed.json"
[ "$CODE" -eq 0 ] && ok || bad "timeout: exit $CODE"
[ "$(jqr '.hosts[1].error.kind')" = timeout ] && ok || bad "timeout: error.kind ($(jqr '.hosts[1]'))"
[ "$(jqr '.hosts[1].reachable')" = false ] && ok || bad "timeout: reachable false"
[ "$(jqr '.hosts[0].agents|length')" = 2 ] && ok || bad "timeout: healthy host still present"
[ "$(jqr .partial)" = true ] && ok || bad "timeout: partial true"

# 5. unreachable host falls back to its last snapshot, marked stale; too old => dropped
fleet "$TMP/down.json" '[{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
FAKE_HERDR_LIST="$FX/herdr/remote-ok.json" run "$TMP/down.json"
fleet "$TMP/down.json" '[{"name":"lenovo","ssh":"lukas@down.lan"}]'
run "$TMP/down.json"
[ "$CODE" -eq 0 ] && [ "$(jqr .answered_hosts)" = 0 ] && ok || bad "down: inventory still emits its record (exit $CODE, answered $(jqr .answered_hosts))"
[ "$(jqr '.hosts[0].error.kind')" = unreachable ] && ok || bad "down: error.kind"
[ "$(jqr '.hosts[0].agents[0].stale')" = true ] && ok || bad "down: snapshot agents are stale"
[ "$(jqr '.hosts[0].agents[0].observed_state')" = blocked ] && ok || bad "down: snapshot state kept"
[ "$(jqr '.hosts[0].agents[0].snapshot_age_s')" -ge 0 ] 2>/dev/null && ok || bad "down: snapshot_age_s present"
sleep 1; run "$TMP/down.json" --option coordinator.maxAgeSeconds:int 0
[ "$(jqr '.hosts[0].agents|length')" = 0 ] && ok || bad "down: snapshot older than max age is dropped"
jqr '.hosts[0].error.message' | grep -q discarded && ok || bad "down: discard noted in error"

# 6. malformed herdr output is an error, not a crash
fleet "$TMP/bad.json" '[{"name":"acer-swift","ssh":null}]'
FAKE_HERDR_LIST="$FX/herdr/malformed.json" run "$TMP/bad.json"
[ "$CODE" -eq 0 ] && [ "$(jqr .partial)" = true ] && ok || bad "malformed: partial record, exit 0"
[ "$(jqr '.hosts[0].error.kind')" = malformed ] && ok || bad "malformed: error.kind"

# 7. invalid fleet entries are refused at evaluation, before any call
: > "$FAKE_LOG"
fleet "$TMP/inj.json" '[{"name":"evil; rm -rf /","ssh":"lukas@x"}]'
run "$TMP/inj.json"
[ "$CODE" -ne 0 ] && ok || bad "inject: must fail evaluation"
grep -q 'does not match' "$TMP/run.log" && ok || bad "inject: assertion message expected"
[ -s "$FAKE_LOG" ] && bad "inject: no ssh/herdr call may happen" || ok
fleet "$TMP/inj2.json" '[{"name":"lenovo","ssh":"lukas@h $(id)"}]'
run "$TMP/inj2.json"; [ "$CODE" -ne 0 ] && ok || bad "inject2: must fail evaluation"
printf '{"schema_version":2,"hosts":[]}' > "$TMP/v2.json"; run "$TMP/v2.json"
[ "$CODE" -ne 0 ] && ok || bad "wrong schema_version: must fail"
grep -q 'schema_version must be 1' "$TMP/run.log" && ok || bad "wrong schema_version: message"

# 7b. renumbered pane / new session does not inherit the old age; null fields do not crash
fleet "$TMP/ren.json" '[{"name":"acer-swift","ssh":null}]'
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/ren.json"; sleep 1
jq '.result.agents[0].pane_id = "wF:p9"' "$FX/herdr/local-two-agents.json" > "$TMP/ren2.json"
FAKE_HERDR_LIST="$TMP/ren2.json" run "$TMP/ren.json"
[ "$(jqr '.hosts[0].agents[0].state_age_s')" = 0 ] && ok || bad "renumbered pane starts at age 0"
FAKE_HERDR_LIST="$FX/herdr/odd-agents.json" run "$TMP/ren.json"
[ "$CODE" -eq 0 ] && [ "$(jqr '.hosts[0].agents|length')" = 3 ] && ok || bad "odd records: 3 usable agents ($(jqr '.hosts[0]'))"
[ "$(jqr '.hosts[0].agents[] | select(.agent_id=="wX:p1") | .observed_state')" = idle ] && ok || bad "odd: idle agent"
[ "$(jqr '.hosts[0].agents[] | select(.agent_id=="wX:p3") | .observed_state')" = unknown ] && ok || bad "odd: missing status => unknown"
[ "$(jqr '.hosts[0].agents[] | select(.agent_id=="wX:p3") | .session_id')" = null ] && ok || bad "odd: string agent_session => null session"

# 8. the graph contains exactly the fleet's hosts
fleet "$TMP/two.json" '[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
listed=$(devenv tasks list --option coordinator.fleetFile:path "$TMP/two.json" 2>/dev/null | grep -oE 'herdr:list:[a-z-]+' | sort -u | paste -sd,)
[ "$listed" = "herdr:list:acer-swift,herdr:list:lenovo" ] && ok || bad "graph: expected two list tasks, got '$listed'"
listed=$(devenv tasks list --option coordinator.fleetFile:path "$FX/fleet-empty.json" 2>/dev/null | grep -cE 'herdr:list:')
[ "$listed" = 0 ] && ok || bad "graph: empty fleet has no list tasks"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
