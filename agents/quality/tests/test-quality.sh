#!/usr/bin/env bash
# quality:report and quality:gate against a fixture checkout with a fake devenv.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FAKE_LOG="$TMP/calls.log" FAKE_SDLC_DIR="$FX/sdlc"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
git init -q "$TMP/repo" && (cd "$TMP/repo" && git config user.email t@t && git config user.name t && echo a > a && printf '.devenv/\n' > .gitignore && git add a .gitignore && git commit -qm init && mkdir -p .devenv/state/sdlc && printf '%s' 'fp1' > .devenv/state/sdlc/sketch-rust-check && printf '{"wrapper":"sdlc:test-rust-test","stage":"test","guard":"rust:test","at":"2026-10-26T10:00:00Z","tail":"test result: FAILED. 1 failed","fingerprint":"fp1"}' > .devenv/state/sdlc/last-red-test-rust-test.json && printf '{"fingerprint":"fp0","grade":9}' > .devenv/state/sdlc/verdict-review.json)
printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null}],"repos":[{"name":"repo","gh":null,"checkout":"%s"}]}' "$TMP/repo" > "$TMP/fleet.json"
run() { # <task> <input>
  devenv tasks run "$1" --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.devenvCommand:string "$FX/bin/devenv" --option coordinator.timeoutSeconds:int 5 --show-output --input-json "$2" > "$TMP/run.log" 2>&1; CODE=$?
  OUT=$(grep -E "^\s*\{\"schema_version\":1" "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
}
jqr() { jq -r "$1" <<<"$OUT"; }

run quality:report "{\"checkout\":\"$TMP/repo\"}"
[ "$CODE" -eq 0 ] && ok || bad "report: exit $CODE ($(tail -3 "$TMP/run.log"))"
[ "$(jqr '.machine.order | join(",")')" = "sketch,model,test,review,perf,security" ] && ok || bad "report: order ($OUT)"
[ "$(jqr '.stages[] | select(.stage=="test") | .state')" = red ] && ok || bad "report: test red"
[ "$(jqr '.stages[] | select(.stage=="perf") | .state')" = stale ] && ok || bad "report: perf stale"
[ "$(jqr '.stages[] | select(.stage=="review") | .verdict')" = true ] && ok || bad "report: review is a verdict stage"
[ "$(jqr '.red[0].guard')" = "rust:test" ] && ok || bad "report: red record parsed"
[ "$(jqr '.verdicts[0].grade')" = 9 ] && ok || bad "report: verdict parsed"
[ "$(jqr .all_fresh)" = false ] && ok || bad "report: not all fresh"
[ "$(jqr .dirty_files)" = 0 ] && ok || bad "report: clean tree"
grep -q "devenv($TMP/repo) shell -q -- sdlc-status --context" "$FAKE_LOG" && ok || bad "report: sdlc-status run inside the checkout"
grep -q 'tasks run' "$FAKE_LOG" && bad "report: must not run any stage" || ok

# a checkout with no stamps or verdicts at all still reports (unmatched globs)
rm -f "$TMP/repo/.devenv/state/sdlc/"*; run quality:report "{\"checkout\":\"$TMP/repo\"}"
[ "$CODE" -eq 0 ] && [ "$(jqr '.red|length')" = 0 ] && [ "$(jqr '.verdicts|length')" = 0 ] && ok || bad "report: empty state dir ($(tail -2 "$TMP/run.log"))"
run quality:report '{"checkout":"/tmp/not-in-fleet"}'; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "report: non-fleet checkout refused ($(jqr .error.kind))"
FAKE_SDLC_DIR="$TMP/empty" run quality:report "{\"checkout\":\"$TMP/repo\"}"; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = no_sdlc ] && ok || bad "report: repo without sdlc machine ($(jqr .error.kind))"

: > "$FAKE_LOG"
run quality:gate "{\"checkout\":\"$TMP/repo\",\"stage\":\"test\"}"
[ "$CODE" -eq 0 ] && [ "$(jqr .green)" = true ] && [ "$(jqr .exit)" = 0 ] && ok || bad "gate green: $OUT"
grep -q "devenv($TMP/repo) tasks run sdlc:test --show-output" "$FAKE_LOG" && ok || bad "gate: argv"
FAKE_GATE_EXIT=1 run quality:gate "{\"checkout\":\"$TMP/repo\",\"stage\":\"test\"}"
[ "$CODE" -ne 0 ] && [ "$(jqr .green)" = false ] && [ "$(jqr .error.kind)" = stage_red ] && ok || bad "gate red: $OUT"
jqr .output_tail | grep -q 'fake tail line' && ok || bad "gate: output tail kept"
run quality:gate "{\"checkout\":\"$TMP/repo\",\"stage\":\"test; id\"}"; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "gate: stage validation"
run quality:gate "{\"checkout\":\"$TMP/repo\"}"; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "gate: stage required"
echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
