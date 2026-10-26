#!/usr/bin/env bash
# Drives the real harness:session-summary task against fixture session stores.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures/harness"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
export FAKE_LOG="$TMP/calls.log"
run() {
  devenv tasks run harness:session-summary --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.sshCommand:string "$ROOT/task-modules/fixtures/bin/ssh" \
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

# remote host: same summary over the fake ssh (which joins argv into one shell string like real ssh)
: > "$FAKE_LOG"
run '{"host":"lenovo","harness":"claude","session_id":"aaaaaaaa-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}'
[ "$CODE" -eq 0 ] && [ "$(jqr .event_count)" = 7 ] && ok || bad "remote claude: exit $CODE count $(jqr .event_count) ($(tail -2 "$TMP/run.log"))"
grep -q "^ssh .*lukas@lenovo.lan bash -c '.*' _ " "$FAKE_LOG" && ok || bad "remote: ssh bash -c argv"
# a half-written trailing line is skipped and counted, not fatal
cp "$FX/claude/-home-lukas-herman/aaaaaaaa-1111-4111-8111-111111111111.jsonl" "$TMP/partial.jsonl"; printf '{"type":"assistant","timestamp":"2026-10-26T14:0' >> "$TMP/partial.jsonl"
mkdir -p "$TMP/claude/-home-lukas-herman" && cp "$TMP/partial.jsonl" "$TMP/claude/-home-lukas-herman/bbbbbbbb-1111-4111-8111-111111111111.jsonl"
devenv tasks run harness:session-summary --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.claudeProjectsDir:string "$TMP/claude" --show-output --input-json '{"host":"acer-swift","harness":"claude","session_id":"bbbbbbbb-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}' > "$TMP/run.log" 2>&1; CODE=$?
OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//')
[ "$CODE" -eq 0 ] && [ "$(jqr .skipped_lines)" = 1 ] && [ "$(jqr .event_count)" = 7 ] && ok || bad "partial line: exit $CODE skipped $(jqr .skipped_lines) ($OUT)"
# a user turn after the question clears awaiting_input
jq -c '.' "$FX/claude/-home-lukas-herman/aaaaaaaa-1111-4111-8111-111111111111.jsonl" > "$TMP/claude/-home-lukas-herman/cccccccc-1111-4111-8111-111111111111.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2026-10-26T14:05:00.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ignored</system-reminder>"},{"type":"text","text":"yes, add it (#42)"}]}}' >> "$TMP/claude/-home-lukas-herman/cccccccc-1111-4111-8111-111111111111.jsonl"
devenv tasks run harness:session-summary --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.claudeProjectsDir:string "$TMP/claude" --show-output --input-json '{"host":"acer-swift","harness":"claude","session_id":"cccccccc-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}' > "$TMP/run.log" 2>&1; CODE=$?
OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//')
[ "$(jqr .awaiting_input)" = false ] && [ "$(jqr .last_role)" = user ] && ok || bad "answered question: awaiting $(jqr .awaiting_input) role $(jqr .last_role)"
[ "$(jqr .last_user_prompt_excerpt)" = "yes, add it (#42)" ] && ok || bad "system-reminder text skipped ($(jqr .last_user_prompt_excerpt))"

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
