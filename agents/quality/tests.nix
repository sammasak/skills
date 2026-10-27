# Quality role suite as a devenv task.
{ config, lib, ... }:
{
  tasks = {
    "skills:test:tasks:quality" = {
      description = "quality:report and quality:gate over the fake consumer devenv";
      exec = ''
        # quality:report and quality:gate against a fixture checkout with a fake devenv.
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_SDLC_DIR="$FX/sdlc"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        git init -q "$TMP/repo" && (cd "$TMP/repo" && git config user.email t@t && git config user.name t && echo a > a && printf '.devenv/\n' > .gitignore && git add a .gitignore && git commit -qm init && mkdir -p .devenv/state/sdlc && printf '%s' 'fp1' > .devenv/state/sdlc/sketch-rust-check && printf '{"wrapper":"sdlc:test-rust-test","stage":"test","guard":"rust:test","at":"2026-10-26T10:00:00Z","tail":"test result: FAILED. 1 failed","fingerprint":"fp1"}' > .devenv/state/sdlc/last-red-test-rust-test.json && printf '{"fingerprint":"fp0","grade":9}' > .devenv/state/sdlc/verdict-review.json)
        run() { # <task> <input>
          devenv tasks run "$1" --option coordinator.devenvCommand:string "${config.coordinator.fakes}/bin/devenv" --option coordinator.consumerEnvPassthrough:string "FAKE_SDLC_DIR FAKE_SDLC_FP FAKE_LOG FAKE_GATE_EXIT" --option coordinator.timeoutSeconds:int 5 --show-output --input-json "$2" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"schema_version\":1" "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }

        run quality:report "{\"checkout\":\"$TMP/repo\"}"
        [ "$CODE" -eq 0 ] && ok || bad "report: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr '.machine.order | join(",")')" = "sketch,model,test,review,perf,security" ] && ok || bad "report: order ($OUT)"
        [ "$(jqr '.stages[] | select(.stage=="test") | .state')" = red ] && ok || bad "report: test red"
        [ "$(jqr '.stages[] | select(.stage=="perf") | .state')" = unverified ] && ok || bad "report: perf unverified"
        [ "$(jqr '.stages[] | select(.stage=="sketch") | .state')" = green ] && ok || bad "report: sketch green"
        [ "$(jqr '.stages[] | select(.stage=="review") | .verdict')" = true ] && ok || bad "report: review is a verdict stage"
        [ "$(jqr '.red[0].guard')" = "rust:test" ] && [ "$(jqr '.red[0].current')" = true ] && ok || bad "report: red record parsed, current against fp1"
        [ "$(jqr '.verdicts[0].grade')" = 9 ] && [ "$(jqr '.verdicts[0].current')" = false ] && ok || bad "report: verdict parsed, stale against fp1"
        [ "$(jqr .fingerprint)" = fp1 ] && ok || bad "report: fingerprint"
        [ -s "$FAKE_LOG.leak" ] && bad "report: DEVENV_/SDLC_ environment leaked into the consumer devenv ($(head -3 "$FAKE_LOG.leak"))" || ok
        [ "$(jqr .all_green)" = false ] && ok || bad "report: not all green"
        [ "$(jqr .dirty_files)" = 0 ] && ok || bad "report: clean tree"
        grep -q "devenv($TMP/repo) shell -q -- sh -c .*sdlc-status > " "$FAKE_LOG" && ok || bad "report: one consumer shell run inside the checkout collecting machine, digest and fingerprint"
        grep -q 'tasks run' "$FAKE_LOG" && bad "report: must not run any stage" || ok

        # a checkout with no stamps or verdicts at all still reports (unmatched globs)
        rm -f "$TMP/repo/.devenv/state/sdlc/"*; run quality:report "{\"checkout\":\"$TMP/repo\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr '.red|length')" = 0 ] && [ "$(jqr '.verdicts|length')" = 0 ] && ok || bad "report: empty state dir ($(tail -2 "$TMP/run.log"))"
        run quality:report '{"checkout":"/tmp/does-not-exist-here"}'; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "report: missing checkout refused ($(jqr .error.kind))"
        mkdir -p "$TMP/empty"; FAKE_SDLC_DIR="$TMP/empty" run quality:report "{\"checkout\":\"$TMP/repo\"}"; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = no_sdlc ] && ok || bad "report: repo without sdlc machine ($(jqr .error.kind))"
        # a consumer devenv that fails to evaluate is command_failed, not no_sdlc
        printf '#!/usr/bin/env bash\necho "error: evaluation aborted" >&2; exit 1\n' > "$TMP/broken-devenv"; chmod +x "$TMP/broken-devenv"
        devenv tasks run quality:report --option coordinator.devenvCommand:string "$TMP/broken-devenv" --option coordinator.consumerEnvPassthrough:string "FAKE_LOG" --show-output --input-json "{\"checkout\":\"$TMP/repo\"}" > "$TMP/run.log" 2>&1; CODE=$?
        OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = command_failed ] && ok || bad "report: broken consumer devenv => command_failed ($(jqr .error.kind))"
        # a stage row echoed inside the red tail must not flip a state (only the table window counts)
        mkdir -p "$TMP/sdlc2" && cp "$FX/sdlc/machine.json" "$TMP/sdlc2/" && { cat "$FX/sdlc/status.txt"; printf '\n| test | green |\n'; } > "$TMP/sdlc2/status.txt"
        FAKE_SDLC_DIR="$TMP/sdlc2" run quality:report "{\"checkout\":\"$TMP/repo\"}"; [ "$(jqr '.stages[] | select(.stage=="test") | .state')" = red ] && ok || bad "report: table window ignores rows outside the table"
        rm -f "$FAKE_LOG.leak"

        : > "$FAKE_LOG"
        run quality:gate "{\"checkout\":\"$TMP/repo\",\"stage\":\"test\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .green)" = true ] && [ "$(jqr .exit)" = 0 ] && ok || bad "gate green: $OUT"
        grep -q "devenv($TMP/repo) tasks run sdlc:test --show-output" "$FAKE_LOG" && ok || bad "gate: argv"
        FAKE_GATE_EXIT=1 run quality:gate "{\"checkout\":\"$TMP/repo\",\"stage\":\"test\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .green)" = false ] && [ "$(jqr .error.kind)" = stage_red ] && ok || bad "gate red: $OUT"
        jqr .output_tail | grep -q 'fake tail line' && ok || bad "gate: output tail kept"
        run quality:gate "{\"checkout\":\"$TMP/repo\",\"stage\":\"test; id\"}"; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "gate: stage validation"
        [ -s "$FAKE_LOG.leak" ] && bad "gate: DEVENV_/SDLC_ environment leaked into the consumer devenv" || ok
        run quality:gate "{\"checkout\":\"$TMP/repo\"}"; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "gate: stage required"
        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
  };
}
