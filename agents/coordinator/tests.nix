# Coordinator role suites as devenv tasks.
{ config, lib, ... }:
{
  tasks = {
    "skills:test:tasks:coord-brief" = {
      description = "work:status and coord:brief end to end over fake herdr/gh";
      exec = ''
        # Drives work:status and coord:brief end to end over fake herdr/gh and a throwaway checkout.
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> <fleet> [args]
          local task="$1" fleet="$2"; shift 2
          devenv tasks run "$task" --option coordinator.fleetFile:path "$fleet" --option coordinator.ghCommand:string "${config.coordinator.fakes}/bin/gh" \
            --option coordinator.sshCommand:string "${config.coordinator.fakes}/bin/ssh" --option coordinator.herdrCommand:string "${config.coordinator.fakes}/bin/herdr" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 1 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          if [ "$task" = coord:brief ] && [ -r "$TMP/state/brief/latest.json" ] && [ "$CODE" -eq 0 ]; then OUT=$(cat "$TMP/state/brief/latest.json")
          else OUT=$(grep -E "^\s*\{\"schema_version\":1,\"task\":\"$task\"" "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); fi
          [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }

        git init -q "$TMP/skills" && (cd "$TMP/skills" && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm init && echo dirty > b)
        # fixture agents: wF:p1 working on #16 in the skills checkout (open PR 17 => unverified); wT:p1 "done" on skills #42 (merged PR 15 => verified);
        # remote blocked agent (no ref). The second agent's title says "skills #42" so the repo resolves by cwd AND by name.
        jq --arg cwd "$TMP/skills" '.result.agents[0].cwd = $cwd | .result.agents[1].cwd = $cwd | .result.agents[1].terminal_title_stripped = "skills #42 settlement tests"' "$FX/herdr/local-two-agents.json" > "$TMP/local.json"
        printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[{"name":"skills","gh":"sammasak/skills","checkout":"%s"}]}' "$TMP/skills" > "$TMP/fleet.json"

        FAKE_HERDR_LIST="$TMP/local.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run coord:brief "$TMP/fleet.json"
        [ "$CODE" -eq 0 ] && ok || bad "brief: exit $CODE ($(grep -E 'FAIL|✖|error' "$TMP/run.log" | head -3))"
        [ "$(jqr '.items|length')" = 3 ] && ok || bad "brief: 3 agents ($OUT)"
        [ "$(jqr '.items[] | select(.agent_id=="wF:p1") | .work_verdict')" = unverified ] && ok || bad "wF:p1 open PR => unverified"
        [ "$(jqr '.items[] | select(.agent_id=="wF:p1") | .herdr_state')" = working ] && ok || bad "wF:p1 herdr_state kept separately"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = verified ] && ok || bad "wT:p1 done + merged PR => verified"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .evidence_ref')" = "https://github.com/sammasak/skills/pull/15" ] && ok || bad "wT:p1 evidence_ref"
        jqr '.items[] | select(.agent_id=="wT:p1") | .reasons | join(";")' | grep -q 'uncommitted' && ok || bad "wT:p1 dirty checkout noted"
        [ "$(jqr '.items[] | select(.agent_id=="wA:p2") | .work_verdict')" = blocked ] && ok || bad "blocked agent => blocked verdict"
        [ "$(jqr '.items[] | select(.agent_id=="wA:p2") | .needs_owner')" = true ] && ok || bad "blocked agent needs owner"
        [ "$(jqr .partial)" = false ] && ok || bad "all sources fine => not partial"
        grep -q '## Needs you' "$TMP/run.log" && grep -q 'lenovo/wA:p2' "$TMP/run.log" && ok || bad "markdown brief lists the blocked agent under Needs you"
        [ "$(jqr '[.items[].sources[].task] | unique | join(",")')" = "gh:work,git:recent,herdr:inventory" ] && ok || bad "sources listed"

        # a "done" agent whose reference has no merged PR is never verified (#16: merged M0 PR would exist later, open PR 17 wins)
        jq '.result.agents[1].terminal_title_stripped = "skills #16 settlement"' "$TMP/local.json" > "$TMP/local16.json"
        FAKE_HERDR_LIST="$TMP/local16.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unverified ] && ok || bad "done without merged PR must stay unverified"
        # cross-repo guard: a herman agent (cwd not a fleet checkout, no repo name in title) with #42 must NOT be verified by skills PR 15
        jq '.result.agents[1].cwd = "/home/lukas/herman" | .result.agents[1].terminal_title_stripped = "herman #42 settlement"' "$TMP/local.json" > "$TMP/herman.json"
        FAKE_HERDR_LIST="$TMP/herman.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unknown ] && ok || bad "cross-repo #42 must be unknown, got $(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')"
        jqr '.items[] | select(.agent_id=="wT:p1") | .reasons[0]' | grep -q 'which fleet repo' && ok || bad "cross-repo reason"
        # a remote agent with the same cwd path does not inherit the local checkout's dirty state
        jq '.result.agents[0].cwd = "'"$TMP/skills"'"' "$FX/herdr/remote-ok.json" > "$TMP/remote-samecwd.json"
        FAKE_HERDR_LIST="$TMP/local.json" FAKE_REMOTE_LIST="$TMP/remote-samecwd.json" run work:status "$TMP/fleet.json"
        jqr '.items[] | select(.agent_id=="wA:p2") | .reasons | join(";")' | grep -q uncommitted && bad "remote agent must not get local checkout reasons" || ok
        # a merged PR that only NAMES #43 while issue #43 is open is unverified, not verified
        jq '.result.agents[1].terminal_title_stripped = "skills #43 part 2"' "$TMP/local.json" > "$TMP/local43.json"
        FAKE_HERDR_LIST="$TMP/local43.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unverified ] && ok || bad "title-only merged PR with open issue must be unverified"
        jqr '.items[] | select(.agent_id=="wT:p1") | .reasons[0]' | grep -q 'still open' && ok || bad "title-only reason"
        # a merged PR that names #44 while no issue #44 is open (list not truncated) => verified
        jq '.result.agents[1].terminal_title_stripped = "skills #44 done"' "$TMP/local.json" > "$TMP/local44.json"
        FAKE_HERDR_LIST="$TMP/local44.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = verified ] && ok || bad "title-only with closed issue => verified ($(jqr '.items[] | select(.agent_id=="wT:p1") | .reasons[0]'))"
        # ... but not when the open-issue list may be truncated (ghLimit 2: 2 open issues hit the limit, 1 open PR does not)
        FAKE_HERDR_LIST="$TMP/local44.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json" --option coordinator.ghLimit:int 2
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unverified ] && ok || bad "truncated issue list must not verify"
        jqr '.items[] | select(.agent_id=="wT:p1") | .reasons[0]' | grep -q truncated && ok || bad "truncation reason"
        # many MERGED PRs alone never truncate: ghLimit 3 (3 open issues? no: 2 open issues < 3, 1 open PR < 3, 5 merged PRs irrelevant) => verified
        FAKE_HERDR_LIST="$TMP/local44.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json" --option coordinator.ghLimit:int 3
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = verified ] && ok || bad "merged-list size must not count as truncation ($(jqr '.items[] | select(.agent_id=="wT:p1") | .reasons[0]'))"
        # a merged PR that "closes" #16 while issue #16 is still open and PR 17 is open => unverified (open wins; closing link does not)
        FAKE_HERDR_LIST="$TMP/local.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wF:p1") | .work_verdict')" = unverified ] && ok || bad "merged-closes-but-open PR => unverified"
        jq 'map(select(.number != 17))' "$FX/gh/sammasak__skills.prs.json" > "$TMP/prs-no17.json"; mkdir -p "$TMP/gh" && cp "$FX/gh/"*.json "$TMP/gh/" && cp "$TMP/prs-no17.json" "$TMP/gh/sammasak__skills.prs.json"
        FAKE_GH_DIR="$TMP/gh" FAKE_HERDR_LIST="$TMP/local.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wF:p1") | .work_verdict')" = unverified ] && ok || bad "merged PR closing #16 while #16 is open => unverified, got $(jqr '.items[] | select(.agent_id=="wF:p1") | .work_verdict')"
        jqr '.items[] | select(.agent_id=="wF:p1") | .reasons[0]' | grep -q 'still open' && ok || bad "closing-link-but-open reason"
        # a subdirectory of the checkout still resolves the repo (and keeps the checkout reasons)
        jq '.result.agents[1].cwd += "/sub/dir"' "$TMP/local.json" > "$TMP/localsub.json"
        FAKE_HERDR_LIST="$TMP/localsub.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = verified ] && ok || bad "subdirectory cwd resolves the checkout"
        jqr '.items[] | select(.agent_id=="wT:p1") | .reasons | join(";")' | grep -q uncommitted && ok || bad "subdirectory cwd keeps checkout reasons"
        # digits inside other numbers never match: #4 is not verified by PR 15 closing #42
        jq '.result.agents[1].terminal_title_stripped = "skills #4 thing"' "$TMP/local.json" > "$TMP/local4.json"
        FAKE_HERDR_LIST="$TMP/local4.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run work:status "$TMP/fleet.json"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unknown ] && ok || bad "#4 must not match #42"

        # gh down: brief still renders from herdr, marked partial with the failed source
        FAKE_GH_EXIT=1 FAKE_HERDR_LIST="$TMP/local.json" FAKE_REMOTE_LIST="$FX/herdr/remote-ok.json" run coord:brief "$TMP/fleet.json"
        [ "$CODE" -eq 0 ] && ok || bad "gh down: brief must still succeed (exit $CODE)"
        [ "$(jqr .partial)" = true ] && ok || bad "gh down: partial"
        jqr '.failed_sources[].source' | grep -q 'gh:work' && ok || bad "gh down: failed source named"
        [ "$(jqr '.items[] | select(.agent_id=="wT:p1") | .work_verdict')" = unknown ] && ok || bad "gh down: verdict unknown, not verified"
        grep -q 'Partial:' "$TMP/run.log" && ok || bad "gh down: markdown says Partial"
        grep -q 'Full JSON: ' "$TMP/run.log" && ok || bad "brief points at the saved JSON"

        # herdr down everywhere: no items, no host answered, brief fails honestly with the real reason
        printf '{"schema_version":1,"hosts":[{"name":"gone","ssh":"lukas@down.lan"}],"repos":[]}' > "$TMP/down.json"
        run coord:brief "$TMP/down.json"
        [ "$CODE" -ne 0 ] && ok || bad "herdr down: brief must fail"
        grep -q 'herdr:inventory:gone: unreachable' "$TMP/run.log" && ok || bad "herdr down: the real reason (unreachable) is surfaced, not 'missing'"
        # one host down, one answering with zero agents: observed, so the brief succeeds (partial)
        printf '{"schema_version":1,"hosts":[{"name":"gone","ssh":"lukas@down.lan"},{"name":"acer-swift","ssh":null}],"repos":[]}' > "$TMP/mixed.json"
        printf '{"id":"cli:agent:list","result":{"agents":[]}}' > "$TMP/empty.json"
        FAKE_HERDR_LIST="$TMP/empty.json" run coord:brief "$TMP/mixed.json"
        [ "$CODE" -eq 0 ] && [ "$(jqr .partial)" = true ] && [ "$(jqr .answered_hosts)" = 1 ] && ok || bad "mixed: brief must succeed when a host answered (exit $CODE)"

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
    "skills:test:tasks:coord-handoff" = {
      description = "coord:handoff drafts: fields, stable id, nothing sent";
      exec = ''
        # coord:handoff drafts a brief into the state dir and never contacts any host.
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
        run() {
          devenv tasks run coord:handoff --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.sshCommand:string "${config.coordinator.fakes}/bin/ssh" \
            --option coordinator.herdrCommand:string "${config.coordinator.fakes}/bin/herdr" --option coordinator.stateDir:string "$TMP/state" --show-output --input-json "$1" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        good='{"host":"lenovo","agent_id":"wA:p2","task_ref":"#42","scope":"Add rounding property tests in crates/settlement","expected_evidence":"PR against main with green dev test","acceptance":"cargo test passes; reviewer grade >= 9","owner_input":"decide whether to bump the MSRV"}'

        run "$good"
        [ "$CODE" -eq 0 ] && ok || bad "draft: exit $CODE ($(tail -3 "$TMP/run.log"))"
        id=$(jqr .handoff_id); [ "''${#id}" = 12 ] && ok || bad "draft: 12-char handoff_id ($id)"
        [ "$(jqr .approval_required)" = true ] && ok || bad "draft: approval_required"
        [ "$(jqr .session_id)" = null ] && ok || bad "draft: no session unless given"
        jqr .text | grep -q 'Owner input still needed: decide whether' && ok || bad "draft: owner input in text"
        jqr .text | grep -q 'Do not merge, deploy or delete' && ok || bad "draft: safety footer"
        [ -f "$TMP/state/handoffs/$id.json" ] && ok || bad "draft: persisted"
        [ -s "$FAKE_LOG" ] && bad "draft: no ssh/herdr call may happen" || ok

        run "$(jq -c '.session_id = "sess-1"' <<<"$good")"; [ "$(jqr .session_id)" = sess-1 ] && ok || bad "draft: session_id recorded"
        run "$(jq -c '.session_id = "x; id"' <<<"$good")"; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "draft: session_id validated"
        run "$good"
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
      '';
    };
  };
}
