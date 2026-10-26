#!/usr/bin/env bash
# Fixture tests for task-modules/bin/herdr-inventory (no real herdr/ssh).
# Run: bash task-modules/tests/test-herdr-inventory.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FX="$ROOT/task-modules/fixtures"
BIN="$ROOT/task-modules/bin/herdr-inventory"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PATH="$FX/bin:$PATH"
export FAKE_LOG="$TMP/calls.log"
export COORDINATOR_STATE_DIR="$TMP/state"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
fleet() { # <file> <hosts-json>
  printf '{"schema_version":1,"hosts":%s,"repos":[]}' "$2" > "$1"
}
run() { # sets OUT and CODE
  OUT="$("$BIN" "$@" 2>"$TMP/err")"; CODE=$?
}

# 1. local host only: both fixture agents become records
fleet "$TMP/local.json" '[{"name":"acer-swift","ssh":null}]'
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run --fleet "$TMP/local.json"
[ "$CODE" -eq 0 ] && ok || bad "local: exit $CODE ($(cat "$TMP/err"))"
[ "$(jq -r '.schema_version' <<<"$OUT")" = "1" ] && ok || bad "local: schema_version"
[ "$(jq -r '.task' <<<"$OUT")" = "herdr:inventory" ] && ok || bad "local: task name"
[ "$(jq '.hosts[0].agents|length' <<<"$OUT")" = "2" ] && ok || bad "local: expected 2 agents"
[ "$(jq -r '.hosts[0].agents[0].agent_id' <<<"$OUT")" = "wF:p1" ] && ok || bad "local: agent_id"
[ "$(jq -r '.hosts[0].agents[0].observed_state' <<<"$OUT")" = "working" ] && ok || bad "local: observed_state"
[ "$(jq -r '.hosts[0].agents[0].harness' <<<"$OUT")" = "claude" ] && ok || bad "local: harness"
[ "$(jq -r '.hosts[0].agents[0].session_id' <<<"$OUT")" = "11111111-1111-4111-8111-111111111111" ] && ok || bad "local: session_id"
[ "$(jq -r '.hosts[0].agents[0].task_ref' <<<"$OUT")" = "#16" ] && ok || bad "local: task_ref from title"
[ "$(jq -r '.hosts[0].agents[1].observed_state' <<<"$OUT")" = "done" ] && ok || bad "local: second state"
[ "$(jq -r '.hosts[0].agents[1].approval_required' <<<"$OUT")" = "false" ] && ok || bad "local: done is not approval_required"
[ "$(jq -r '.hosts[0].agents[0].stale' <<<"$OUT")" = "false" ] && ok || bad "local: fresh read is not stale"
[ "$(jq -r '.partial' <<<"$OUT")" = "false" ] && ok || bad "local: partial"
grep -q '^ssh' "$FAKE_LOG" && bad "local: ssh must not be called for a local host" || ok

# 2. state_age_s grows while state_change_seq is unchanged; resets when it changes
sleep 1
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run --fleet "$TMP/local.json"
age=$(jq -r '.hosts[0].agents[0].state_age_s' <<<"$OUT")
[ "$age" -ge 1 ] 2>/dev/null && ok || bad "age: expected >=1, got $age"
jq '.result.agents[0].state_change_seq = 999' "$FX/herdr/local-two-agents.json" > "$TMP/changed.json"
FAKE_HERDR_LIST="$TMP/changed.json" run --fleet "$TMP/local.json"
[ "$(jq -r '.hosts[0].agents[0].state_age_s' <<<"$OUT")" = "0" ] && ok || bad "age: expected reset to 0"

# 3. remote host over fake ssh; blocked agent is approval_required
fleet "$TMP/remote.json" '[{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
FAKE_HERDR_LIST="$FX/herdr/remote-ok.json" run --fleet "$TMP/remote.json"
[ "$CODE" -eq 0 ] && ok || bad "remote: exit $CODE ($(cat "$TMP/err"))"
grep -q '^ssh .*lukas@lenovo.lan herdr agent list' "$FAKE_LOG" && ok || bad "remote: expected ssh <target> herdr agent list"
[ "$(jq -r '.hosts[0].agents[0].approval_required' <<<"$OUT")" = "true" ] && ok || bad "remote: blocked => approval_required"
[ "$(jq -r '.hosts[0].agents[0].host' <<<"$OUT")" = "lenovo" ] && ok || bad "remote: host field"

# 4. one host times out: its error is reported, the other host is still returned, exit 0, partial true
fleet "$TMP/mixed.json" '[{"name":"acer-swift","ssh":null},{"name":"slow","ssh":"lukas@timeout.lan"}]'
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run --fleet "$TMP/mixed.json" --timeout-s 1
[ "$CODE" -eq 0 ] && ok || bad "timeout: exit $CODE"
[ "$(jq -r '.hosts[1].error.kind' <<<"$OUT")" = "timeout" ] && ok || bad "timeout: error.kind ($(jq -c '.hosts[1]' <<<"$OUT"))"
[ "$(jq -r '.hosts[1].reachable' <<<"$OUT")" = "false" ] && ok || bad "timeout: reachable false"
[ "$(jq '.hosts[0].agents|length' <<<"$OUT")" = "2" ] && ok || bad "timeout: healthy host still present"
[ "$(jq -r '.partial' <<<"$OUT")" = "true" ] && ok || bad "timeout: partial true"

# 5. unreachable host falls back to its last snapshot, marked stale
fleet "$TMP/down.json" '[{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
FAKE_HERDR_LIST="$FX/herdr/remote-ok.json" run --fleet "$TMP/down.json"
fleet "$TMP/down.json" '[{"name":"lenovo","ssh":"lukas@down.lan"}]'
run --fleet "$TMP/down.json"
[ "$CODE" -eq 2 ] && ok || bad "down: all hosts failed should exit 2, got $CODE"
[ "$(jq -r '.hosts[0].error.kind' <<<"$OUT")" = "unreachable" ] && ok || bad "down: error.kind"
[ "$(jq -r '.hosts[0].agents[0].stale' <<<"$OUT")" = "true" ] && ok || bad "down: snapshot agents are stale"
[ "$(jq -r '.hosts[0].agents[0].observed_state' <<<"$OUT")" = "blocked" ] && ok || bad "down: snapshot state kept"
[ "$(jq -r '.hosts[0].agents[0].snapshot_age_s' <<<"$OUT")" -ge 0 ] 2>/dev/null && ok || bad "down: snapshot_age_s present"
sleep 1; run --fleet "$TMP/down.json" --max-age-s 0
[ "$(jq '.hosts[0].agents|length' <<<"$OUT")" = "0" ] && ok || bad "down: snapshot older than max-age is dropped"
grep -q 'discarded' <<<"$(jq -r '.hosts[0].error.message' <<<"$OUT")" && ok || bad "down: discard noted in error"

# 6. malformed herdr output is an error, not a crash
fleet "$TMP/bad.json" '[{"name":"acer-swift","ssh":null}]'
FAKE_HERDR_LIST="$FX/herdr/malformed.json" run --fleet "$TMP/bad.json"
[ "$CODE" -eq 2 ] && ok || bad "malformed: exit $CODE"
[ "$(jq -r '.hosts[0].error.kind' <<<"$OUT")" = "malformed" ] && ok || bad "malformed: error.kind"

# 7. invalid fleet entries are refused before any call
: > "$FAKE_LOG"
fleet "$TMP/inj.json" '[{"name":"evil; rm -rf /","ssh":"lukas@x"}]'
run --fleet "$TMP/inj.json"
[ "$CODE" -eq 3 ] && ok || bad "inject: exit $CODE"
[ -s "$FAKE_LOG" ] && bad "inject: no ssh/herdr call may happen" || ok
fleet "$TMP/inj2.json" '[{"name":"lenovo","ssh":"lukas@h $(id)"}]'
run --fleet "$TMP/inj2.json"
[ "$CODE" -eq 3 ] && ok || bad "inject2: exit $CODE"
run --fleet "$TMP/does-not-exist.json"
[ "$CODE" -eq 3 ] && ok || bad "missing fleet: exit $CODE"
printf '{"schema_version":2,"hosts":[]}' > "$TMP/v2.json"; run --fleet "$TMP/v2.json"
[ "$CODE" -eq 3 ] && ok || bad "wrong schema_version: exit $CODE"

# 8. a host limited to a subset still gets only that host
fleet "$TMP/two.json" '[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run --fleet "$TMP/two.json" --host lenovo
[ "$(jq '.hosts|length' <<<"$OUT")" = "1" ] && ok || bad "subset: one host"
[ "$(jq -r '.hosts[0].host' <<<"$OUT")" = "lenovo" ] && ok || bad "subset: lenovo"
run --fleet "$TMP/two.json" --host nothere
[ "$CODE" -eq 3 ] && ok || bad "subset: unknown host exit 3, got $CODE"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
