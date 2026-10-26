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
grep -q 'herdr agent prompt wA:p2 Assignment' "$FAKE_LOG" && ok || bad "send: argv ($(grep prompt "$FAKE_LOG"))"
[ "$(audit | jq -r 'select(.phase=="attempt") | .handoff_id')" = "$id" ] && ok || bad "send: audit attempt"
[ "$(audit | jq -r 'select(.phase=="outcome") | .outcome')" = delivered ] && ok || bad "send: audit outcome"
[ "$(audit | jq -r 'select(.phase=="attempt") | .session_id')" = sess-1 ] && ok || bad "send: attempt records the session"
aid=$(jqr .audit_id)

# duplicate: same handoff refused unless resend names the prior audit id
: > "$FAKE_LOG"
run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = duplicate ] && ok || bad "dup: $(jqr .error.kind)"
jqr .error.message | grep -q "$aid" && ok || bad "dup: message names prior audit id"
jqr .error.message | grep -q 'only the owner' && ok || bad "dup: message says the owner decides"
grep -q 'agent prompt' "$FAKE_LOG" && bad "dup: nothing sent" || ok
run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid\"}"
[ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "resend: $(jqr .outcome)"
[ "$(audit | grep -c '"phase":"attempt"')" = 2 ] && ok || bad "resend: second attempt audited"

# prompt timeout => unknown_delivery, exit non-zero, audited; a later resend is refused when the agent's seq advanced (probably received)
run coord:handoff "$(jq -c '.scope = "second task"' <<<"$draft")"; id2=$(jqr .handoff_id)
FAKE_HERDR_PROMPT=timeout run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = unknown_delivery ] && [ "$(jqr .error.kind)" = unknown_delivery ] && ok || bad "timeout: $(jqr .outcome)/$(jqr .error.kind)"
[ "$(audit | jq -r --arg i "$id2" 'select(.handoff_id==$i and .phase=="outcome") | .outcome')" = unknown_delivery ] && ok || bad "timeout: audited"
aid2=$(jqr .audit_id)
run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = duplicate ] && ok || bad "timeout then retry must hit duplicate guard"
FAKE_HERDR_SEQ=9 run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = probably_received ] && ok || bad "resend after seq advance must be refused ($(jqr .error.kind))"
FAKE_HERDR_SEQ=7 run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid2\"}"
[ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "resend with unchanged seq goes through ($(jqr .error.kind))"
# herdr-side blocked race: prompt rejected with agent_blocked after get said idle
run coord:handoff "$(jq -c '.scope = "third"' <<<"$draft")"; id3=$(jqr .handoff_id)
FAKE_HERDR_PROMPT=blocked run herdr:message "{\"handoff_id\":\"$id3\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = agent_blocked ] && ok || bad "race: $(jqr .outcome)"
# fail closed on unusable `agent get` output: no send, no attempt
run coord:handoff "$(jq -c '.scope = "fourth"' <<<"$draft")"; id4=$(jqr .handoff_id); : > "$FAKE_LOG"; n_before=$(audit | grep -c attempt)
FAKE_HERDR_GET_RAW='not json' run herdr:message "{\"handoff_id\":\"$id4\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_state_unknown ] && ok || bad "malformed get: $(jqr .error.kind)"
FAKE_HERDR_GET_RAW='{"result":{"agent":{"pane_id":"wA:p2"}}}' run herdr:message "{\"handoff_id\":\"$id4\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_state_unknown ] && ok || bad "wrong-shape get: $(jqr .error.kind)"
grep -q 'agent prompt' "$FAKE_LOG" && bad "unusable get: nothing may be sent" || ok
[ "$(audit | grep -c attempt)" = "$n_before" ] && ok || bad "unusable get: no attempt recorded"
# agent identity: a draft bound to a session is refused when the pane runs another session
run coord:handoff "$(jq -c '.scope = "fifth" | .session_id = "sess-1"' <<<"$draft")"; id5=$(jqr .handoff_id)
FAKE_HERDR_SESSION=sess-2 run herdr:message "{\"handoff_id\":\"$id5\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_changed ] && ok || bad "session mismatch: $(jqr .error.kind)"
run herdr:message "{\"handoff_id\":\"$id5\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$CODE" -eq 0 ] && ok || bad "session match sends ($(jqr .error.kind))"
# edited draft is refused (content-addressed id)
run coord:handoff "$(jq -c '.scope = "sixth"' <<<"$draft")"; id6=$(jqr .handoff_id)
jq '.text = "tampered"' "$TMP/state/handoffs/$id6.json" > "$TMP/t.json" && mv "$TMP/t.json" "$TMP/state/handoffs/$id6.json"
run herdr:message "{\"handoff_id\":\"$id6\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'does not match' && ok || bad "tampered draft refused ($(jqr .error.kind))"
# byte-exact delivery through the remote path: quotes, $(id), backtick, newline, unicode
weird=$(printf 'Scope with '"'"'single'"'"' and "double" quotes, $(id), `uname`, a\\backslash and ünïcödé\nsecond line')
run coord:handoff "$(jq -cn --arg s "$weird" '{host:"lenovo",agent_id:"wA:p2",task_ref:"#7",scope:$s,expected_evidence:"e",acceptance:"a"}')"; id7=$(jqr .handoff_id); [ -n "$id7" ] && ok || bad "weird draft ($OUT)"
FAKE_PROMPT_OUT="$TMP/prompt.txt" run herdr:message "{\"handoff_id\":\"$id7\",\"confirm\":\"lenovo/wA:p2\"}"
[ "$CODE" -eq 0 ] && ok || bad "weird: send ($(jqr .error.kind))"
jq -r .text "$TMP/state/handoffs/$id7.json" > "$TMP/expected.txt"; printf '%s' "$(cat "$TMP/expected.txt")" > "$TMP/expected.txt"
cmp -s "$TMP/prompt.txt" "$TMP/expected.txt" && ok || bad "weird: text not byte-identical over ssh/fish/bash ($(diff "$TMP/prompt.txt" "$TMP/expected.txt" | head -3))"
# audit corruption fails closed
printf 'not json\n' >> "$TMP/state/audit.jsonl"
run coord:handoff "$(jq -c '.scope = "eighth"' <<<"$draft")"; id8=$(jqr .handoff_id)
run herdr:message "{\"handoff_id\":\"$id8\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = audit_corrupt ] && ok || bad "corrupt audit: $(jqr .error.kind)"
sed -i '/^not json$/d' "$TMP/state/audit.jsonl"

# await: the turn must start before it can end
: > "$FAKE_LOG"; rm -f "$FAKE_LOG.seq"
FAKE_HERDR_STATE_SEQ="idle,working,done" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
[ "$CODE" -eq 0 ] && [ "$(jqr .herdr_state)" = done ] && [ "$(jqr .turn_observed)" = true ] && [ "$(jqr .worker_done)" = true ] && [ "$(jqr .accepted)" = false ] && ok || bad "await idle→working→done: $OUT"
grep -q 'herdr agent wait wA:p2 --until working --until blocked --timeout 5000' "$FAKE_LOG" && ok || bad "await: phase-1 argv"
grep -q 'herdr agent wait wA:p2 --until idle --until done --until blocked --timeout' "$FAKE_LOG" && ok || bad "await: phase-2 argv"
rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="working,idle" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
[ "$CODE" -eq 0 ] && [ "$(jqr .herdr_state)" = idle ] && ok || bad "await already working: $OUT"
rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="idle,idle,idle" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":3,"start_timeout_s":1}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = no_turn_observed ] && [ "$(jqr .turn_observed)" = false ] && jqr .error.message | grep -q 'Do not resend' && ok || bad "await stale idle: $OUT"
# await by audit_id: host/agent/since/session come from the attempt record
last_aid=$(audit | jq -r 'select(.phase=="attempt" and .handoff_id=="'"$id5"'") | .audit_id' | tail -1)
rm -f "$FAKE_LOG.seq"; FAKE_HERDR_SEQ=12 FAKE_HERDR_STATE_SEQ="idle,idle" run herdr:await "{\"audit_id\":\"$last_aid\",\"timeout_s\":5}"
[ "$CODE" -eq 0 ] && [ "$(jqr .turn_observed)" = true ] && [ "$(jqr .audit_id)" = "$last_aid" ] && [ "$(jqr .host)" = lenovo ] && ok || bad "await by audit_id with seq advanced: $OUT"
rm -f "$FAKE_LOG.seq"; FAKE_HERDR_SESSION=sess-9 FAKE_HERDR_SEQ=12 run herdr:await "{\"audit_id\":\"$last_aid\",\"timeout_s\":5}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_changed ] && ok || bad "await: session changed since the message ($(jqr .error.kind))"
rm -f "$FAKE_LOG.seq"; FAKE_HERDR_SEQ=3 run herdr:await "{\"audit_id\":\"$last_aid\",\"timeout_s\":5}"
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_restarted ] && ok || bad "await: seq went backwards => restarted ($(jqr .error.kind))"
run herdr:await '{"audit_id":"000000000000","timeout_s":5}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: unknown audit id"
rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="blocked" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
[ "$(jqr .needs_owner)" = true ] && [ "$(jqr .worker_done)" = false ] && ok || bad "await blocked"
rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="working,working" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":1}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = timeout ] && [ "$(jqr .turn_observed)" = true ] && [ "$(jqr .reached)" = false ] && ok || bad "await timeout: $OUT"
FAKE_HERDR_MISSING=wA:p2 run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_missing ] && ok || bad "await: agent gone ($(jqr .error.kind))"
run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":99999}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: timeout bound"
run herdr:await '{"host":"lenovo","agent_id":"x; id"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: id validation"
run herdr:await '{"host":"nope","agent_id":"wA:p2"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: wrong host"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
