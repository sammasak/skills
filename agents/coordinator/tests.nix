# Coordinator role suites as devenv tasks (herdr-native: this host plus saved machines).
{ config, lib, ... }:
{
  tasks = {
    "skills:test:tasks:coord-brief" = {
      description = "work:status and coord:brief end to end over fake herdr (with a saved machine) and fake gh";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        # this host: two agents; wT:p1 is "done" on sammasak/skills #42 (fixture: merged PR 15 closes #42 => verified);
        # a saved machine with one blocked agent (needs the owner)
        jq '.result.agents[1].terminal_title_stripped = "sammasak/skills #42 settlement tests"' "$FX/herdr/local-two-agents.json" > "$TMP/local.json"
        export FAKE_HERDR_LIST="$TMP/local.json" FAKE_HERDR_MACHINES='[{"id":"e236150c763f9ca38a989be19feb0934","label":"acer-swift","target":"acer-swift","enabled":true}]' FAKE_HERDR_LIST_acer_swift="$FX/herdr/remote-ok.json"
        runb() { run coord:brief "$@"; [ -r "$TMP/state/brief/latest.json" ] && [ "$CODE" -eq 0 ] && OUT=$(cat "$TMP/state/brief/latest.json"); }
        runb
        [ "$CODE" -eq 0 ] && ok || bad "brief: exit $CODE ($(grep -E 'FAIL|✖|error|jq:' "$TMP/run.log" | head -3))"
        [ "$(jqr '.items|length')" = 3 ] && [ "$(jqr .answered_hosts)" = 2 ] && [ "$(jqr .machines_configured)" = 1 ] && ok || bad "brief: 3 agents over 2 hosts ($OUT)"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = verified ] && [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .evidence_ref')" != null ] && ok || bad "done + merged PR closing #42 in the named repo => verified"
        [ "$(jqr '.items[] | select(.agent_id=="wF:p1") | .work_verdict')" = unknown ] && jqr '.items[] | select(.agent_id=="wF:p1") | .reasons[0]' | grep -q 'no OWNER/REPO' && ok || bad "#16 without a repo in the title => unknown with the reason"
        [ "$(jqr '.items[] | select(.agent_id=="wA:p2") | .work_verdict')" = blocked ] && [ "$(jqr '.items[] | select(.agent_id=="wA:p2") | .needs_owner')" = true ] && [ "$(jqr '.items[] | select(.agent_id=="wA:p2") | .machine')" = acer-swift ] && ok || bad "blocked remote agent needs the owner"
        grep -q '## Needs you' "$TMP/run.log" && grep -q 'acer-swift/wA:p2' "$TMP/run.log" && grep -q 'Hosts: this one + 1 saved herdr machine' "$TMP/run.log" && ok || bad "Markdown brief names the blocked agent and the machines"
        # herdr_state and work_verdict are distinct keys; the done agent's herdr_state stays done
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .herdr_state')" = done ] && ok || bad "herdr_state kept apart from work_verdict"
        # gh failing: the brief still succeeds, verdicts become unknown with the reason
        FAKE_GH_EXIT=1 runb
        [ "$CODE" -eq 0 ] && [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unknown ] && ok || bad "gh down: brief succeeds with unknown verdicts ($CODE)"
        # everything down (this host too): the brief fails honestly
        export FAKE_HERDR_EXIT=1 FAKE_HERDR_MACHINES='[]'
        run coord:brief
        [ "$CODE" -ne 0 ] && grep -q 'herdr:inventory' "$TMP/run.log" && ok || bad "herdr down everywhere: brief must fail"
        unset FAKE_HERDR_EXIT
        summary
      '';
    };
    "skills:test:tasks:coord-handoff" = {
      description = "coord:handoff drafts: fields, allowed_actions, stable id, 4000-character cap, machine or local, nothing sent";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        run coord:handoff --input-json '{"machine":"acer-swift","agent_id":"wA:p2","session_id":"sess-1","task_ref":"#7","scope":"fix typo","expected_evidence":"commit","acceptance":"typo gone","allowed_actions":["comment","deploy:none"],"owner_input":"none"}'
        [ "$CODE" -eq 0 ] && ok || bad "handoff: exit $CODE ($(tail -2 "$TMP/run.log"))"
        ID=$(jqr .handoff_id); [[ "$ID" =~ ^[a-f0-9]{12}$ ]] && ok || bad "handoff id"
        [ "$(jqr .host)" = acer-swift ] && [ "$(jqr .machine)" = acer-swift ] && [ "$(jqr .approval_required)" = true ] && ok || bad "handoff fields"
        [ "$(jqr '.allowed_actions | join(",")')" = "comment,deploy:none" ] && ok || bad "allowed_actions recorded on the draft"
        jqr .text | grep -q 'Assignment #7 for acer-swift/wA:p2' && jqr .text | grep -q '^Allowed actions: comment, deploy:none\. Reading, committing and opening a PR are always implied; anything else, deleting included, is not allowed\.$' && jqr .text | grep -q '^Reply in this pane when done, naming the evidence above\.$' && ok || bad "handoff text"
        ! jqr .text | grep -q 'Do not merge' && ! jqr .text | grep -q 'naming the commit or PR' && ok || bad "fixed footer gone"
        [ -f "$TMP/state/handoffs/$ID.json" ] && ok || bad "draft saved"
        [ ! -s "$FAKE_LOG" ] && ok || bad "handoff must not call herdr"
        run coord:handoff --input-json '{"machine":"acer-swift","agent_id":"wA:p2","session_id":"sess-1","task_ref":"#7","scope":"fix typo","expected_evidence":"commit","acceptance":"typo gone","allowed_actions":["comment","deploy:none"],"owner_input":"none"}'
        [ "$(jqr .handoff_id)" = "$ID" ] && ok || bad "same content => same id"
        run coord:handoff --input-json '{"machine":"acer-swift","agent_id":"wA:p2","session_id":"sess-1","task_ref":"#7","scope":"fix typo","expected_evidence":"commit","acceptance":"typo gone","allowed_actions":["merge","deploy:none"],"owner_input":"none"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .handoff_id)" != "$ID" ] && ok || bad "different allowed_actions => different id"
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#7","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["deploy:msi","comment","label","deploy:acer-swift","close","merge"]}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .machine)" = null ] && [ "$(jqr .host)" = "$(hostname -s 2>/dev/null || hostname)" ] && ok || bad "local handoff: host is this host, machine null"
        ID_LOCAL=$(jqr .handoff_id)
        jqr .text | grep -q '^Allowed actions: merge, close, label, comment, deploy:acer-swift, deploy:msi\. ' && [ "$(jqr '.allowed_actions | join(",")')" = "merge,close,label,comment,deploy:acer-swift,deploy:msi" ] && ok || bad "actions rendered and recorded in canonical order"
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#7","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["merge","close","label","comment","deploy:acer-swift","deploy:msi"]}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .handoff_id)" = "$ID_LOCAL" ] && ok || bad "same actions in another order => same id"
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"7","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "task_ref must be #N"
        run coord:handoff --input-json '{"machine":"a b","agent_id":"wF:p1","task_ref":"#7","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "unsafe machine label rejected"
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#7","scope":"s","expected_evidence":"e","allowed_actions":["comment"]}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "missing field rejected"
        # allowed_actions: required, a non-empty list of distinct known entries; deploy:none excludes deploy:<host>
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#7","scope":"s","expected_evidence":"e","acceptance":"a"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q allowed_actions && ok || bad "missing allowed_actions rejected"
        LONGHOST=$(printf 'h%.0s' $(seq 1 64))
        for bad_actions in '[]' '"merge"' '["merge","deploy"]' '["delete"]' '["merge","merge"]' '["deploy:none","deploy:acer-swift"]' '["deploy:a b"]' \
            '["deploy:none\n","deploy:acer-swift"]' '["merge","merge\n"]' '["comment\n"]' '["deploy:NONE"]' '["merge","close","label","comment","deploy:a","deploy:b","deploy:c","deploy:d","deploy:e"]' "[\"deploy:$LONGHOST\"]"; do
          run coord:handoff --input-json "{\"agent_id\":\"wF:p1\",\"task_ref\":\"#7\",\"scope\":\"s\",\"expected_evidence\":\"e\",\"acceptance\":\"a\",\"allowed_actions\":$bad_actions}"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "allowed_actions $bad_actions rejected"
        done
        # per-field cap raised to 4000 characters
        LONG=$(printf 'x%.0s' $(seq 1 4000)); TOOLONG="''${LONG}x"
        run coord:handoff --input-json "{\"agent_id\":\"wF:p1\",\"task_ref\":\"#7\",\"scope\":\"$LONG\",\"expected_evidence\":\"e\",\"acceptance\":\"a\",\"allowed_actions\":[\"comment\"]}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .text | grep -c "$LONG")" = 1 ] && ok || bad "4000-character field accepted ($CODE)"
        run coord:handoff --input-json "{\"agent_id\":\"wF:p1\",\"task_ref\":\"#7\",\"scope\":\"$TOOLONG\",\"expected_evidence\":\"e\",\"acceptance\":\"a\",\"allowed_actions\":[\"comment\"]}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 4000 && ok || bad "4001-character field rejected"
        summary
      '';
    };
  };
}
