#!/usr/bin/env bash
# herdr:message (act) and herdr:await with a fake herdr: confirmation, blocked refusal, audit, duplicates, timeouts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FAKE_LOG="$TMP/calls.log"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
run() { # <task> <input-json> [args]
  local task="$1" in="$2"; shift 2
  devenv tasks run "$task" --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.sshCommand:string "$FX/bin/ssh" \
    --option coordinator.herdrCommand:string "$FX/bin/herdr" --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 1 \
    --option coordinator.messageTimeoutSeconds:int 1 --show-output --input-json "$in" "$@" > "$TMP/run.log" 2>&1; CODE=$?
  OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
}
jqr() { jq -r "$1" <<<"$OUT"; }
audit() { cat "$TMP/state/audit.jsonl" 2>/dev/null; }

draft='{"host":"lenovo","agent_id":"wA:p2","task_ref":"#42","scope":"Add rounding tests","expected_evidence":"PR","acceptance":"green tests"}'
run coord:handoff "$draft"; id=$(jqr .handoff_id); [ "${#id}" = 12 ] && ok || bad "setup: draft ($OUT)"

# refusals before anything is sent
: > "$FAKE_LOG"
run herdr:message '{"handoff_id":"zzzz"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "bad id: $(jqr .error.kind)"
run herdr:message "{\"handoff_id\":\"$id\"}"; [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "no confirm: $(jqr .error.kind)"
run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"acer-swift/wA:p2\"}"; [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "wrong host confirm: $(jqr .error.kind)"
run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wF:p1\"}"; [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "wrong agent confirm: $(jqr .error.kind)"
grep -q 'agent prompt' "$FAKE_LOG" && bad "refusals: nothing may be sent" || ok
[ -s "$TMP/state/audit.jsonl" ] && bad "refusals: no audit attempt" || ok

# blocked target is refused, no prompt, no audit attempt
FAKE_HERDR_STATE=blocked run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_blocked ] && ok || bad "blocked: $(jqr .error.kind)"
grep -q 'agent prompt' "$FAKE_LOG" && bad "blocked: prompt must not be sent" || ok
[ "$(audit | grep -c attempt)" = 0 ] && ok || bad "blocked: no audit attempt"

# happy path over ssh: attempt + outcome audited, draft marked sent, receipt true, accepted false
: > "$FAKE_LOG"
FAKE_HERDR_STATE=idle run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -eq 0 ] && ok || bad "send: exit $CODE ($(tail -3 "$TMP/run.log"))"
[ "$(jqr .outcome)" = delivered ] && [ "$(jqr .receipt)" = true ] && [ "$(jqr .accepted)" = false ] && ok || bad "send: fields ($OUT)"
grep -q '^ssh .*lukas@lenovo.lan herdr agent prompt wA:p2 Assignment #42' "$FAKE_LOG" && ok || bad "send: argv ($(grep prompt "$FAKE_LOG"))"
[ "$(audit | jq -r 'select(.phase=="attempt") | .handoff_id')" = "$id" ] && ok || bad "send: audit attempt"
[ "$(audit | jq -r 'select(.phase=="outcome") | .outcome')" = delivered ] && ok || bad "send: audit outcome"
[ "$(jq -r .sent "$TMP/state/handoffs/$id.json")" = true ] && ok || bad "send: draft marked sent"
aid=$(jqr .audit_id)

# duplicate: same handoff refused unless resend names the prior audit id
: > "$FAKE_LOG"
run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = duplicate ] && ok || bad "dup: $(jqr .error.kind)"
jqr .error.message | grep -q "$aid" && ok || bad "dup: message names prior audit id"
grep -q 'agent prompt' "$FAKE_LOG" && bad "dup: nothing sent" || ok
run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid\"}"
[ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "resend: $(jqr .outcome)"
[ "$(audit | grep -c '"phase":"attempt"')" = 2 ] && ok || bad "resend: second attempt audited"

# prompt timeout => unknown_delivery, exit non-zero, audited, draft still counts as sent-attempted (duplicate guard applies)
run coord:handoff "$(jq -c '.scope = "second task"' <<<"$draft")"; id2=$(jqr .handoff_id)
FAKE_HERDR_PROMPT=timeout run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = unknown_delivery ] && [ "$(jqr .error.kind)" = timeout ] && ok || bad "timeout: $(jqr .outcome)/$(jqr .error.kind)"
[ "$(audit | jq -r --arg i "$id2" 'select(.handoff_id==$i and .phase=="outcome") | .outcome')" = unknown_delivery ] && ok || bad "timeout: audited"
run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = duplicate ] && ok || bad "timeout then retry must hit duplicate guard"
# herdr-side blocked race: prompt rejected with agent_blocked after get said idle
run coord:handoff "$(jq -c '.scope = "third"' <<<"$draft")"; id3=$(jqr .handoff_id)
FAKE_HERDR_PROMPT=blocked run herdr:message "{\"handoff_id\":\"$id3\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = agent_blocked ] && ok || bad "race: $(jqr .outcome)"

# await
FAKE_HERDR_STATE=done run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
[ "$CODE" -eq 0 ] && [ "$(jqr .herdr_state)" = done ] && [ "$(jqr .worker_done)" = true ] && [ "$(jqr .accepted)" = false ] && ok || bad "await done: $OUT"
grep -q 'herdr agent wait wA:p2 --until idle --until done --until blocked --timeout 5000' "$FAKE_LOG" && ok || bad "await: argv"
FAKE_HERDR_STATE=blocked run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
[ "$(jqr .needs_owner)" = true ] && [ "$(jqr .worker_done)" = false ] && ok || bad "await blocked"
FAKE_HERDR_WAIT=timeout run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":1}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = timeout ] && [ "$(jqr .reached)" = false ] && ok || bad "await timeout: $OUT"
run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":99999}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: timeout bound"
run herdr:await '{"host":"lenovo","agent_id":"x; id"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: id validation"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
