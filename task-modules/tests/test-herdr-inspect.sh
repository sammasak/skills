#!/usr/bin/env bash
# Drives the real herdr:inspect task (bounded terminal read) with fake ssh/herdr.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FAKE_LOG="$TMP/calls.log"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
run() { # <input-json> ; OUT, CODE
  devenv tasks run herdr:inspect --option coordinator.fleetFile:path "$TMP/fleet.json" \
    --option coordinator.sshCommand:string "$FX/bin/ssh" --option coordinator.herdrCommand:string "$FX/bin/herdr" \
    --option coordinator.timeoutSeconds:int 1 --show-output --input-json "$1" > "$TMP/run.log" 2>&1; CODE=$?
  OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
}
jqr() { jq -r "$1" <<<"$OUT"; }

# local bounded read
: > "$FAKE_LOG"
FAKE_HERDR_READ="$FX/herdr/read-visible.txt" run '{"host":"acer-swift","agent_id":"wF:p1","lines":40}'
[ "$CODE" -eq 0 ] && ok || bad "local: exit $CODE ($(tail -3 "$TMP/run.log"))"
[ "$(jqr .lines_returned)" = 4 ] && ok || bad "local: lines_returned ($OUT)"
jqr .excerpt | grep -q 'property test' && ok || bad "local: excerpt content"
[ "$(jqr .agent_id)" = "wF:p1" ] && ok || bad "local: agent_id echoed"
grep -q 'herdr agent read wF:p1 --lines 40 --source visible --format text' "$FAKE_LOG" && ok || bad "local: expected bounded read argv ($(cat "$FAKE_LOG"))"
grep -q '^ssh' "$FAKE_LOG" && bad "local: no ssh for local host" || ok

# remote read goes through ssh with the same bounded argv
: > "$FAKE_LOG"
FAKE_HERDR_READ="$FX/herdr/read-visible.txt" run '{"host":"lenovo","agent_id":"wA:p2","lines":10,"source":"recent"}'
[ "$CODE" -eq 0 ] && ok || bad "remote: exit $CODE"
grep -q "^ssh .*-- lukas@lenovo.lan bash -c '.*' _ " "$FAKE_LOG" && grep -q 'herdr agent read wA:p2 --lines 10 --source recent --format text' "$FAKE_LOG" && ok || bad "remote: argv ($(cat "$FAKE_LOG"))"

# the cap holds: 1000 requested -> 200 asked for and at most 200 returned
: > "$FAKE_LOG"
FAKE_HERDR_READ="$FX/herdr/read-long.txt" run '{"host":"acer-swift","agent_id":"wF:p1","lines":1000}'
grep -q -- '--lines 200 ' "$FAKE_LOG" && ok || bad "cap: requested lines must be capped at 200"
[ "$(jqr .lines_returned)" -le 200 ] && ok || bad "cap: lines_returned <= 200"
[ "$(jqr .truncated)" = true ] && [ "$(jqr .capped)" = true ] && ok || bad "cap: truncated+capped flags"
FAKE_HERDR_READ="$FX/herdr/read-visible.txt" run '{"host":"acer-swift","agent_id":"wF:p1","lines":500}'
[ "$(jqr .truncated)" = false ] && [ "$(jqr .capped)" = true ] && ok || bad "short pane with capped request: capped but not truncated"
run '{"host":"acer-swift","agent_id":"wF:p1","lines":99999999999}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "huge lines rejected"

# invalid input is refused before any call
for bad_input in '{"host":"acer-swift","agent_id":"wF:p1; rm -rf /"}' '{"host":"nothere","agent_id":"wF:p1"}' '{"host":"acer-swift"}' '{"host":"acer-swift","agent_id":"wF:p1","source":"detection; id"}' '{"host":"acer-swift","agent_id":"wF:p1","lines":"abc"}'; do
  : > "$FAKE_LOG"; run "$bad_input"
  [ "$CODE" -ne 0 ] && [ "$(jqr '.error.kind')" = invalid_input ] && ok || bad "invalid: $bad_input -> exit $CODE kind $(jqr '.error.kind')"
  [ -s "$FAKE_LOG" ] && bad "invalid: no herdr/ssh call may happen for $bad_input" || ok
done

# agent missing / herdr error is a structured error
FAKE_HERDR_READ="$FX/herdr/read-visible.txt" FAKE_HERDR_EXIT=1 run '{"host":"acer-swift","agent_id":"wZ:p9"}'
[ "$CODE" -ne 0 ] && [ "$(jqr '.error.kind')" = command_failed ] && ok || bad "missing agent: kind $(jqr '.error.kind')"
# timeout
run '{"host":"slow","agent_id":"wF:p1"}'; [ "$(jqr '.error.kind')" = invalid_input ] && ok || bad "unknown host slow must be invalid_input"
printf '{"schema_version":1,"hosts":[{"name":"slow","ssh":"lukas@timeout.lan"}],"repos":[]}' > "$TMP/fleet.json"
run '{"host":"slow","agent_id":"wF:p1"}'
[ "$CODE" -ne 0 ] && [ "$(jqr '.error.kind')" = timeout ] && ok || bad "timeout: kind $(jqr '.error.kind')"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
