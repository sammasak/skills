#!/usr/bin/env bash
# Drives the real harness:session-summary task against fixture session stores.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures/harness"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null}],"repos":[]}' > "$TMP/fleet.json"
run() {
  devenv tasks run harness:session-summary --option coordinator.fleetFile:path "$TMP/fleet.json" \
    --option coordinator.claudeProjectsDir:string "$FX/claude" --option coordinator.piSessionsDir:string "$FX/pi" \
    --show-output --input-json "$1" > "$TMP/run.log" 2>&1; CODE=$?
  OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
}
jqr() { jq -r "$1" <<<"$OUT"; }

run '{"host":"acer-swift","harness":"claude","session_id":"aaaaaaaa-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}'
[ "$CODE" -eq 0 ] && ok || bad "claude: exit $CODE ($(tail -3 "$TMP/run.log"))"
[ "$(jqr .event_count)" = 7 ] && ok || bad "claude: event_count ($OUT)"
[ "$(jqr .last_event_at)" = "2026-10-26T14:04:01.000Z" ] && ok || bad "claude: last_event_at"
[ "$(jqr .last_role)" = assistant ] && ok || bad "claude: last_role"
[ "$(jqr .awaiting_input)" = true ] && ok || bad "claude: question at the end => awaiting_input"
jqr .last_user_prompt_excerpt | grep -q 'settlement rounding tests' && ok || bad "claude: user prompt excerpt"
jqr .last_assistant_excerpt | grep -q 'property test' && ok || bad "claude: assistant excerpt"
[ "$(jqr '.last_tools | join(",")')" = "Read,Bash" ] && ok || bad "claude: last_tools ($(jqr .last_tools))"
[ "$(jqr .task_ref)" = "#42" ] && ok || bad "claude: task_ref from prompt"
[ "$(jqr '.last_assistant_excerpt | length')" -le 400 ] && ok || bad "claude: excerpt bounded"

run '{"host":"acer-swift","harness":"pi","session_id":"pi-sess-1","cwd":"/home/lukas/karta"}'
[ "$CODE" -eq 0 ] && ok || bad "pi: exit $CODE ($(tail -3 "$TMP/run.log"))"
[ "$(jqr .event_count)" = 3 ] && ok || bad "pi: event_count ($OUT)"
[ "$(jqr .awaiting_input)" = false ] && ok || bad "pi: statement at the end => not awaiting"
jqr .last_assistant_excerpt | grep -q 'clippy is clean' && ok || bad "pi: assistant excerpt"

run '{"host":"acer-swift","harness":"claude","session_id":"aaaaaaaa-1111-4111-8111-111111111111","cwd":"/home/lukas/nowhere"}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_found ] && ok || bad "missing: kind $(jqr .error.kind)"
run '{"host":"acer-swift","harness":"codex","session_id":"thr_1","cwd":"/home/lukas/herman"}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = unsupported ] && ok || bad "codex: unsupported until a store exists ($(jqr .error.kind))"
run '{"host":"acer-swift","harness":"claude","session_id":"../../etc/passwd","cwd":"/home/lukas/herman"}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "traversal: kind $(jqr .error.kind)"
run '{"host":"acer-swift","harness":"claude","session_id":"x","cwd":"/home/lukas/herman; id"}'
[ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "cwd injection: kind $(jqr .error.kind)"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
