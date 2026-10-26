#!/usr/bin/env bash
# coord:handoff drafts a brief into the state dir and never contacts any host.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FAKE_LOG="$TMP/calls.log"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
run() {
  devenv tasks run coord:handoff --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.sshCommand:string "$FX/bin/ssh" \
    --option coordinator.herdrCommand:string "$FX/bin/herdr" --option coordinator.stateDir:string "$TMP/state" --show-output --input-json "$1" > "$TMP/run.log" 2>&1; CODE=$?
  OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
}
jqr() { jq -r "$1" <<<"$OUT"; }
good='{"host":"lenovo","agent_id":"wA:p2","task_ref":"#42","scope":"Add rounding property tests in crates/settlement","expected_evidence":"PR against main with green dev test","acceptance":"cargo test passes; reviewer grade >= 9","owner_input":"decide whether to bump the MSRV"}'

run "$good"
[ "$CODE" -eq 0 ] && ok || bad "draft: exit $CODE ($(tail -3 "$TMP/run.log"))"
id=$(jqr .handoff_id); [ "${#id}" = 12 ] && ok || bad "draft: 12-char handoff_id ($id)"
[ "$(jqr .approval_required)" = true ] && ok || bad "draft: approval_required"
[ "$(jqr .sent)" = false ] && ok || bad "draft: not sent"
jqr .text | grep -q 'Owner input still needed: decide whether' && ok || bad "draft: owner input in text"
jqr .text | grep -q 'Do not merge, deploy or delete' && ok || bad "draft: safety footer"
[ -f "$TMP/state/handoffs/$id.json" ] && ok || bad "draft: persisted"
[ -s "$FAKE_LOG" ] && bad "draft: no ssh/herdr call may happen" || ok

# identical input => identical id, file not rewritten
first=$(stat -c %Y "$TMP/state/handoffs/$id.json"); sleep 1; run "$good"
[ "$(jqr .handoff_id)" = "$id" ] && ok || bad "stable id"
[ "$(stat -c %Y "$TMP/state/handoffs/$id.json")" = "$first" ] && ok || bad "existing draft untouched"
# changed scope => different id
run "$(jq -c '.scope = "something else"' <<<"$good")"; [ "$(jqr .handoff_id)" != "$id" ] && ok || bad "different scope => different id"

for bad_in in "$(jq -c 'del(.acceptance)' <<<"$good")" "$(jq -c '.task_ref = "42"' <<<"$good")" "$(jq -c '.host = "nope"' <<<"$good")" "$(jq -c '.agent_id = "wA:p2; id"' <<<"$good")" "$(jq -c --arg s "$(head -c 2100 /dev/zero | tr '\0' x)" '.scope = $s' <<<"$good")"; do
  run "$bad_in"; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "invalid: $(cut -c1-60 <<<"$bad_in") -> $CODE $(jqr .error.kind)"
done
echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
