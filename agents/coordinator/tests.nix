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
        # the portfolio: three repos from gh:repos; skills (approved issue 43) and nixos-config (open PRs) are active, quiet is not
        mkdir -p "$TMP/gh"; cp "$FX"/gh/* "$TMP/gh/"; jq '(.[] | select(.number == 43) | .labels) += [{"name":"approved"}]' "$FX/gh/sammasak__skills.issues.json" > "$TMP/gh/sammasak__skills.issues.json"
        export FAKE_GH_DIR="$TMP/gh" FAKE_GH_REPOS='[{"name":"skills","pushedAt":"2026-11-03T10:18:03Z","isArchived":false,"isPrivate":false,"pullRequests":{"totalCount":1},"issues":{"totalCount":2},"approved":{"totalCount":1}},{"name":"nixos-config","pushedAt":"2026-11-03T11:19:56Z","isArchived":false,"isPrivate":false,"pullRequests":{"totalCount":2},"issues":{"totalCount":12},"approved":{"totalCount":0}},{"name":"quiet","pushedAt":"2026-10-01T00:00:00Z","isArchived":false,"isPrivate":true,"pullRequests":{"totalCount":0},"issues":{"totalCount":3},"approved":{"totalCount":0}}]'
        : > "$FAKE_LOG"
        runb
        [ "$CODE" -eq 0 ] && [ "$(jqr '.portfolio | "\(.owner) \(.repos_total) \(.repos_listed) \(.truncated) \(.error)"')" = "sammasak 3 3 false null" ] && ok || bad "portfolio: counts from gh:repos ($(jqr .portfolio))"
        [ "$(jqr '[.portfolio.active[].repo] | join(",")')" = "sammasak/nixos-config,sammasak/skills" ] && [ "$(jqr '.portfolio.skipped_active|length')" = 0 ] && ok || bad "portfolio: active repos only, newest push first ($(jqr '.portfolio.active'))"
        [ "$(jqr '.portfolio.active[] | select(.repo=="sammasak/skills") | .approved | map(.number) | join(",")')" = 43 ] && [ "$(jqr '.portfolio.active[] | select(.repo=="sammasak/skills") | .open_pr_list | length')" = 1 ] && ok || bad "portfolio: approved issues and open PRs listed per active repo"
        grep -q 'issue list -R sammasak/skills' "$FAKE_LOG" && grep -q 'issue list -R sammasak/nixos-config' "$FAKE_LOG" && ! grep -q 'sammasak/quiet' "$FAKE_LOG" && ok || bad "portfolio: gh:work only for active repos ($(grep -c 'sammasak/quiet' "$FAKE_LOG"))"
        grep -q '## Portfolio (sammasak: 3 of 3 repos' "$TMP/run.log" && grep -q 'sammasak/skills: 1 open PR(s), 1 approved issue(s) → #43' "$TMP/run.log" && ok || bad "portfolio: Markdown section"
        # gh:repos failing: the brief still succeeds, names the failed source, and the rest is intact
        FAKE_GH_API_EXIT=1 runb
        [ "$CODE" -eq 0 ] && [ "$(jqr '.portfolio.error.kind')" = gh_error ] && [ "$(jqr .partial)" = true ] && [ "$(jqr '[.failed_sources[] | select(.source=="gh:repos")] | length')" = 1 ] && grep -q 'unavailable: gh_error' "$TMP/run.log" && ok || bad "portfolio: gh failure is a failed source, not a missing section ($(jqr '{partial,failed_sources}'))"
        : > "$FAKE_LOG"; runb
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
    "skills:test:tasks:coord-evidence" = {
      description = "Discovery of running Claude and Codex agents (harness, session) through to a draft and the agent_changed refusal; verified only from a merged PR, never from herdr done/idle or a worker saying done";
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
        H=$(hostname -s 2>/dev/null || hostname); LOCAL="$FX/herdr/local-two-agents.json"
        export FAKE_HERDR_MACHINES='[{"id":"e236150c763f9ca38a989be19feb0934","label":"acer-swift","target":"acer-swift","enabled":true}]'
        export FAKE_HERDR_LIST="$LOCAL" FAKE_HERDR_LIST_acer_swift="$FX/herdr/remote-ok.json" FAKE_PROMPT_OUT="$TMP/prompt.txt"
        export FAKE_GH_LABELS='["approved"]' FAKE_GH_EVENTS='[{"event":"labeled","label":{"name":"approved"},"actor":{"login":"sammasak"},"created_at":"2026-11-03T09:00:00Z"}]'
        AUTH='"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/28","label":"approved"}'

        # (a) discovery: running agents of both harnesses on this host and on the saved machine, each with its session
        run herdr:inventory
        [ "$CODE" -eq 0 ] && [ "$(jqr .answered_hosts)" = 2 ] && ok || bad "inventory: $CODE $OUT"
        [ "$(jqr '.hosts[] | select(.machine==null) | .agents[] | select(.agent_id=="wF:p1") | "\(.harness) \(.session_id) \(.observed_state)"')" = "claude 11111111-1111-4111-8111-111111111111 working" ] && ok || bad "local claude agent discovered with its session ($OUT)"
        [ "$(jqr '.hosts[] | select(.machine==null) | .agents[] | select(.agent_id=="wT:p1") | "\(.harness) \(.session_id) \(.observed_state)"')" = "codex thr_2222 done" ] && ok || bad "local codex agent discovered with its session ($OUT)"
        [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[] | select(.agent_id=="wA:p2") | "\(.harness) \(.session_id) \(.observed_state) \(.approval_required)"')" = "claude 33333333-3333-4333-8333-333333333333 blocked true" ] && ok || bad "remote claude agent discovered through --machine with its session ($OUT)"
        [ "$(jqr '[.hosts[].agents[] | select(.session_id == null)] | length')" = 0 ] && ok || bad "every discovered agent carries a session_id"
        RSESS=$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0].session_id'); CSESS=$(jqr '.hosts[] | select(.machine==null) | .agents[] | select(.agent_id=="wT:p1") | .session_id')
        # the brief carries harness and session for the same three agents
        run coord:brief; B="$TMP/state/brief/latest.json"
        [ "$CODE" -eq 0 ] && [ "$(jq -r '[.items[] | "\(.host)/\(.agent_id) \(.harness) \(.session_id)"] | sort | join(";")' "$B")" = "$(printf '%s;%s;%s' "$H/wF:p1 claude 11111111-1111-4111-8111-111111111111" "$H/wT:p1 codex thr_2222" "acer-swift/wA:p2 claude 33333333-3333-4333-8333-333333333333" | tr ';' '\n' | sort | paste -sd';')" ] && ok || bad "brief items carry harness and session_id ($(jq -c '[.items[] | {host,agent_id,harness,session_id}]' "$B"))"
        # session carried from the inventory record into the draft, for a remote claude agent and a local codex agent
        run coord:handoff --input-json "{\"machine\":\"acer-swift\",\"agent_id\":\"wA:p2\",\"session_id\":\"$RSESS\",\"task_ref\":\"#28\",\"scope\":\"s\",\"expected_evidence\":\"e\",\"acceptance\":\"a\",\"allowed_actions\":[\"comment\"]}"
        IDR=$(jqr .handoff_id); [ "$CODE" -eq 0 ] && [ "$(jqr .session_id)" = "$RSESS" ] && [ "$(jqr .machine)" = acer-swift ] && ok || bad "remote draft carries the inventory session ($OUT)"
        run coord:handoff --input-json "{\"agent_id\":\"wT:p1\",\"session_id\":\"$CSESS\",\"task_ref\":\"#28\",\"scope\":\"s\",\"expected_evidence\":\"e\",\"acceptance\":\"a\",\"allowed_actions\":[\"comment\"]}"
        IDC=$(jqr .handoff_id); [ "$CODE" -eq 0 ] && [ "$(jqr .session_id)" = "thr_2222" ] && [ "$(jqr .machine)" = null ] && ok || bad "codex draft carries the inventory session ($OUT)"
        # the send refuses agent_changed when the pane now runs another session, and nothing is prompted
        export FAKE_HERDR_STATE=idle FAKE_HERDR_SEQ=9 FAKE_HERDR_SESSION="44444444-4444-4444-8444-444444444444"; : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$IDR\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_changed ] && jqr .error.message | grep -q "$RSESS" && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "agent_changed refused, nothing sent ($CODE $OUT)"
        [ ! -s "$TMP/state/audit.jsonl" ] || [ "$(grep -c '"phase":"attempt"' "$TMP/state/audit.jsonl")" = 0 ] && ok || bad "agent_changed leaves no attempt in the audit log"
        # the same draft is delivered once the pane runs the drafted session again; the codex agent is a first-class target too
        export FAKE_HERDR_SESSION="$RSESS"; : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$IDR\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jqr .session_id)" = "$RSESS" ] && grep -q '^herdr(machine=acer-swift) agent prompt wA:p2' "$FAKE_LOG" && ok || bad "matching session delivered ($CODE $OUT)"
        export FAKE_HERDR_SESSION="thr_2222"; : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$IDC\",\"confirm\":\"$H/wT:p1\",$AUTH}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jqr .session_id)" = thr_2222 ] && grep -q '^herdr agent prompt wT:p1' "$FAKE_LOG" && ok || bad "codex agent delivered on its session ($CODE $OUT)"
        unset FAKE_HERDR_SESSION

        # (b) completion vs verification: four done/idle agents whose titles (what a worker "says") all claim completion
        #   wF:p1 "#16 done": open PR 17 + merged PR 13 for #16          -> unverified (open PR)
        #   wT:p1 "#43 DONE": merged PR 12 names #43, issue 43 still open -> unverified (issue open)
        #   wX:p3 "#99 finished": nothing on GitHub                       -> unknown
        #   wY:p4 "#42": merged PR 15 closes #42, issue closed            -> verified, evidence_ref = that PR
        jq '.result.agents as $a | .result.agents = [
              ($a[0] | .agent_status = "done" | .terminal_title_stripped = "sammasak/skills #16 done, all green"),
              ($a[1] | .agent_status = "done" | .terminal_title_stripped = "sammasak/skills #43 DONE and verified by me"),
              ($a[0] | .pane_id = "wX:p3" | .agent_status = "idle" | .terminal_title_stripped = "sammasak/skills #99 finished"),
              ($a[1] | .pane_id = "wY:p4" | .agent_status = "done" | .terminal_title_stripped = "sammasak/skills #42 settlement tests")]' "$LOCAL" > "$TMP/claims.json"
        export FAKE_HERDR_LIST="$TMP/claims.json" FAKE_HERDR_MACHINES='[]'; : > "$FAKE_LOG"
        run coord:brief; B="$TMP/state/brief/latest.json"
        v() { jq -r --arg a "$1" '.items[] | select(.agent_id==$a) | "\(.herdr_state) \(.work_verdict) \(.evidence_ref)"' "$B"; }
        [ "$CODE" -eq 0 ] && [ "$(jq -r '.items|length' "$B")" = 4 ] && ok || bad "brief over four claiming agents: $CODE"
        [ "$(v wF:p1)" = "done unverified null" ] && jq -r '.items[] | select(.agent_id=="wF:p1") | .reasons[0]' "$B" | grep -q 'open PR' && ok || bad "open PR: done agent is unverified, no evidence_ref ($(v wF:p1))"
        [ "$(v wT:p1)" = "done unverified null" ] && jq -r '.items[] | select(.agent_id=="wT:p1") | .reasons[0]' "$B" | grep -q 'still open' && ok || bad "merged PR but open issue: unverified ($(v wT:p1))"
        [ "$(v wX:p3)" = "idle unknown null" ] && ok || bad "nothing on GitHub: unknown ($(v wX:p3))"
        [ "$(v wY:p4)" = "done verified https://github.com/sammasak/skills/pull/15" ] && ok || bad "merged PR closing the issue: verified with that PR as evidence_ref ($(v wY:p4))"
        # three agents share herdr_state=done and still get three different verdicts: the fields are independent
        [ "$(jq -r '[.items[] | select(.herdr_state=="done") | .work_verdict] | sort | unique | join(",")' "$B")" = "unverified,verified" ] && [ "$(jq -r '[.items[] | has("herdr_state") and has("work_verdict")] | all' "$B")" = true ] && ok || bad "herdr_state and work_verdict are separate fields"
        # evidence_ref is set only on verified items, and only ever to a merged PR URL
        [ "$(jq -r '[.items[] | select(.work_verdict != "verified") | .evidence_ref] | all(. == null)' "$B")" = true ] && [ "$(jq -r '[.items[] | select(.work_verdict == "verified") | .evidence_ref] | all(test("^https://github.com/.+/pull/[0-9]+$"))' "$B")" = true ] && ok || bad "evidence_ref only from merged PRs"
        # what the worker says in its pane is never consulted: no agent read during status/brief, only list + gh
        ! grep -q 'agent read' "$FAKE_LOG" && grep -q '^gh pr list -R sammasak/skills --state all --search 16' "$FAKE_LOG" && ok || bad "verdicts come from gh, never from pane text ($(grep -c . "$FAKE_LOG") calls)"
        # none of the completion claims needs the owner; nothing is "done" in the Markdown either
        [ "$(jq -r '[.items[] | .needs_owner] | any' "$B")" = false ] && grep -q 'wF:p1 claude #16 | herdr=done | work=unverified' "$TMP/run.log" && ok || bad "Markdown keeps herdr=done beside work=unverified"
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
        # session 2: forget everything above and lose the drafts too; only the two files remain
        unset ID; rm -rf "$TMP/state/handoffs"; run coord:brief; [ "$CODE" -eq 0 ] && ok || bad "brief without drafts: $CODE"
        B="$TMP/state/brief/latest.json"; A="$TMP/state/audit.jsonl"
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
        # a second send of the recovered handoff is refused: without its draft as invalid_input (no draft), with it as duplicate;
        # either way nothing is prompted (the gate is unchanged)
        : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$HID\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/28\",\"label\":\"assign:implementer\"}}"
        [ "$CODE" -ne 0 ] && [[ "$(jqr .error.kind)" =~ ^(duplicate|invalid_input)$ ]] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "resend refused after recovery ($OUT)"
        # an interrupted attempt (no outcome line) shows as interrupted, never as delivered
        printf '%s\n' '{"audit_id":"aaaaaaaaaaaa","handoff_id":"bbbbbbbbbbbb","phase":"attempt","host":"'"$H"'","machine":null,"agent_id":"wT:p1","at":"2026-11-03T09:10:00Z","allowed_actions":["comment"],"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/29","label":"approved"}}' >> "$A"
        run coord:brief; B="$TMP/state/brief/latest.json"
        [ "$(jq -r '.handoffs|length' "$B")" = 2 ] && [ "$(jq -r '.handoffs[] | select(.handoff_id=="bbbbbbbbbbbb") | "\(.outcome) \(.delivered) \(.task_ref)"' "$B")" = "interrupted false null" ] && [ "$(jq -r .handoffs_error "$B")" = null ] && ok || bad "interrupted attempt recovered honestly ($(jq -c .handoffs "$B"))"
        # a malformed audit line is surfaced as a failed source, never as "no handoffs"
        printf '%s\n' 'this is not json' >> "$A"
        run coord:brief; B="$TMP/state/brief/latest.json"
        [ "$CODE" -eq 0 ] && [ "$(jq -r '.handoffs_error.kind' "$B")" = audit_corrupt ] && [ "$(jq -r .partial "$B")" = true ] && [ "$(jq -r '[.failed_sources[] | select(.source=="coordinator:audit")] | length' "$B")" = 1 ] && [ "$(jq -r '.handoffs|length' "$B")" = 0 ] && grep -q 'unreadable: audit_corrupt' "$TMP/run.log" && ok || bad "corrupt audit surfaced in the brief ($(jq -c '{handoffs_error,partial,failed_sources}' "$B"))"
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
