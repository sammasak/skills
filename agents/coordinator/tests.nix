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
    "skills:test:tasks:coord-recovery" = {
      description = "A fresh session rebuilds every handoff (target, outcome, authorization, verdict) from coord:brief + audit.jsonl alone and can await by audit id";
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
        export FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" FAKE_HERDR_MACHINES='[]' FAKE_HERDR_SESSION=sess-1 FAKE_HERDR_STATE=idle FAKE_HERDR_SEQ=5 FAKE_PROMPT_OUT="$TMP/prompt.txt"
        export FAKE_GH_LABELS='["assign:implementer"]' FAKE_GH_EVENTS='[{"event":"labeled","label":{"name":"assign:implementer"},"actor":{"login":"sammasak"},"created_at":"2026-11-03T09:00:00Z"}]'
        H=$(hostname -s 2>/dev/null || hostname)
        # session 1: draft and send one handoff to the local idle agent wF:p1
        run coord:handoff --input-json '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#28","scope":"increment 1","expected_evidence":"a PR","acceptance":"skills:test green","allowed_actions":["comment","deploy:none"]}'
        ID=$(jqr .handoff_id); [ "$CODE" -eq 0 ] && [[ "$ID" =~ ^[a-f0-9]{12}$ ]] && ok || bad "draft: $CODE $OUT"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/28\",\"label\":\"assign:implementer\"}}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "send: $CODE $OUT"
        run coord:brief; [ "$CODE" -eq 0 ] && ok || bad "brief after send: $CODE"
        # session 2: forget everything above; only the two files remain
        unset ID; B="$TMP/state/brief/latest.json"; A="$TMP/state/audit.jsonl"
        [ -s "$B" ] && [ -s "$A" ] && ok || bad "state files present"
        HID=$(jq -r '.handoffs[0].handoff_id' "$B"); AID=$(jq -r '.handoffs[0].audit_id' "$B")
        [[ "$HID" =~ ^[a-f0-9]{12}$ ]] && [[ "$AID" =~ ^[a-f0-9]{12}$ ]] && [ "$(jq -r '.handoffs|length' "$B")" = 1 ] && ok || bad "brief lists the one handoff ($(jq -c .handoffs "$B"))"
        [ "$(jq -r '.handoffs[0] | "\(.host)/\(.agent_id) \(.task_ref) \(.outcome) \(.delivered) \(.allowed_actions|join(",")) \(.authorized_by.label) \(.work_verdict)"' "$B")" = "$H/wF:p1 #28 delivered true comment,deploy:none assign:implementer unknown" ] && ok || bad "handoff fields recoverable from the brief ($(jq -c '.handoffs[0]' "$B"))"
        [ "$(jq -r '.handoffs[0].authorized_by.issue_url' "$B")" = "https://github.com/sammasak/skills/issues/28" ] && [ "$(jq -r .audit_path "$B")" = "$A" ] && ok || bad "authorizing issue and audit path in the brief"
        # the same facts are in the audit log by itself (attempt + outcome lines share the audit id)
        [ "$(jq -r --arg a "$AID" 'select(.audit_id == $a and .phase == "attempt") | .handoff_id' "$A")" = "$HID" ] && [ "$(jq -r --arg a "$AID" 'select(.audit_id == $a and .phase == "outcome") | .outcome' "$A")" = delivered ] && ok || bad "audit log alone names handoff and outcome"
        grep -q '## Handoffs (from the audit log)' "$TMP/run.log" && grep -q "$HID → $H/wF:p1 #28" "$TMP/run.log" && ok || bad "Markdown brief shows the handoff"
        # follow-up needs only the audit id: await works without the draft or any session memory
        export FAKE_HERDR_STATE_SEQ="working,idle"; rm -f "$FAKE_LOG.seq"
        run herdr:await --input-json "{\"audit_id\":\"$AID\",\"timeout_s\":5,\"start_timeout_s\":2}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .audit_id)" = "$AID" ] && [ "$(jqr .agent_id)" = "wF:p1" ] && [ "$(jqr .herdr_state)" = idle ] && ok || bad "await by audit id from the recovered state ($CODE $OUT)"
        unset FAKE_HERDR_STATE_SEQ
        # a second send of the recovered handoff is still refused as a duplicate (the gate is unchanged)
        run herdr:message --input-json "{\"handoff_id\":\"$HID\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/28\",\"label\":\"assign:implementer\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = duplicate ] && ok || bad "duplicate still refused after recovery ($OUT)"
        # an interrupted attempt (no outcome line) shows as interrupted, never as delivered
        printf '%s\n' '{"audit_id":"aaaaaaaaaaaa","handoff_id":"bbbbbbbbbbbb","phase":"attempt","host":"'"$H"'","machine":null,"agent_id":"wT:p1","at":"2026-11-03T09:10:00Z","allowed_actions":["comment"],"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/29","label":"approved"}}' >> "$A"
        run coord:brief; B="$TMP/state/brief/latest.json"
        [ "$(jq -r '.handoffs|length' "$B")" = 2 ] && [ "$(jq -r '.handoffs[] | select(.handoff_id=="bbbbbbbbbbbb") | "\(.outcome) \(.delivered) \(.task_ref)"' "$B")" = "interrupted false null" ] && ok || bad "interrupted attempt recovered honestly ($(jq -c .handoffs "$B"))"
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
