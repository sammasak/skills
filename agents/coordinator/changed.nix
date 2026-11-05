# coord:changed is the zero-LLM wake-up check (sammasak/skills#28, slice C2): a pure jq diff of what the read tasks
# already observe (herdr agent state with its state_change_seq, gh:repos counts, the audit log's open handoffs)
# against the previous snapshot. It prints nothing when nothing is actionable, so a timer can run it every minute
# and start a Coordinator session only when it prints; the snapshot moves on every run, so a change is reported once,
# and a handoff is closed by its first settled/gone/replaced report (the audit log has no close record of its own).
{ lib, config, ... }:
let
  cfg = config.coordinator;
in
{
  imports = [ ../../task-modules/common.nix ];

  # The wake budget: a timer may start a model session only when this task prints, so the task itself spaces its
  # printing runs (min gap) and caps them per hour; a deferred run prints nothing, leaves the snapshot where it is and
  # keeps its lines under wake.pending (never .changes), so they come out together once the budget allows.
  options.coordinator.wakeMinGapSeconds = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 300;
    description = "Minimum seconds between two printing (wake) runs of coord:changed; 0 disables the gap.";
  };
  options.coordinator.wakeMaxPerHour = lib.mkOption {
    type = lib.types.ints.positive;
    default = 6;
    description = "Maximum printing (wake) runs of coord:changed in any sliding hour.";
  };
  # The interactive Coordinator and the timer race (skills#28, 06:19Z): a wake session started while the owner's session
  # was dispatching, and both drafted for the same workers. While a Coordinator pane works, or worked within this many
  # seconds, a printing run is deferred like the budget defers it (reason interactive_coordinator). 0 turns it off.
  options.coordinator.interactiveQuietSeconds = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 0;
    description = "Defer a printing (wake) run of coord:changed while a Coordinator pane is working or worked within this many seconds; 0 disables it.";
  };
  options.coordinator.openHandoffDays = lib.mkOption {
    type = lib.types.ints.positive;
    default = 7;
    description = "A delivered handoff older than this no longer counts as open for coord:changed.";
  };

  # The fleet whose idleness wakes the Coordinator (F1) is its workers: the panes a handoff was sent to (audit.jsonl
  # attempt lines, as host/agent_id) plus these. The Coordinator's own panes and the wake session never receive a
  # handoff, so they never count: an interactive Coordinator working all day kept the fleet from ever being idle.
  options.coordinator.workers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Agents counted as workers for the idle-fleet wake besides handoff targets, as host/agent_id.";
  };

  config.tasks."coord:changed" = {
    description = "Zero-LLM change check for a timer (and the idle-fleet-with-work wake, once per fleet+work fingerprint), with a wake budget (min gap, per-hour cap; deferred runs print nothing and keep the snapshot): diffs herdr agent state (state_change_seq), gh:repos counts (upstream in the same DAG) and the audit log's open handoffs against the last snapshot; prints nothing and exits 0 when nothing is actionable, else one compact line per actionable change. The plain form reads without consuming; consume=true (the timer's form) moves the snapshot and spends the wake budget.";
    after = [ "herdr:inventory@completed" "gh:repos@completed" ];
    input = { consume = false; peek = false; };
    exec = ''
      ${cfg.prelude}
      ctx='{"task":"coord:changed"}'
      # the plain form reads without consuming (an owner session's call must never take a change away from the timer);
      # only consume:true, the timer's form, moves the snapshot and spends the wake budget. peek:true is the older
      # spelling of the plain form and still accepted.
      consume=$(input .consume); case "$consume" in true|false|"") ;; *) fail 3 invalid_input "consume must be true or false" "$ctx" ;; esac; [ "$consume" = true ] || consume=false
      peek=$(input .peek); case "$peek" in true|false|"") ;; *) fail 3 invalid_input "peek must be true or false" "$ctx" ;; esac
      [ "$peek" = true ] && [ "$consume" = true ] && fail 3 invalid_input "peek:true and consume:true contradict each other" "$ctx"
      inv=$(upstream "herdr:inventory")
      [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" "$ctx"
      dir="${cfg.stateDir}/changed"; mkdir -p "$dir" || fail 2 state_unwritable "cannot create $dir" "$ctx"
      snap="$dir/snapshot.json"; at=$(now_iso)
      # large values travel through files (one argv string is capped at 128 KiB); one run at a time per state dir
      tmpd=$(mktemp -d "$dir/.run.XXXXXX") || fail 2 state_unwritable "cannot create a temp dir in $dir" "$ctx"
      trap 'rm -rf "$tmpd"' EXIT
      exec 8>"$dir/.lock"; flock -w 10 8 || fail 2 busy "another coord:changed run holds $dir/.lock" "$ctx"
      # under the lock no other run is alive, so any other .run.* dir is the leftover of a killed run
      for stale in "$dir"/.run.*; do [ -d "$stale" ] && [ "$stale" != "$tmpd" ] && rm -rf "$stale"; done
      [ "$(jq -r '.answered_hosts // 0' <<<"$inv")" -gt 0 ] || fail 2 nothing_observed "no herdr host answered (not even this one); the snapshot is left as it was" "$ctx"
      printf '%s\n' "$inv" > "$tmpd/inv.json"

      # repos: the gh:repos record that ran upstream in this DAG (absent only when the task is driven outside it); a record
      # carrying an error counts as absent for this run and the previous counts are carried forward in the snapshot
      repos=$(upstream "gh:repos"); repos_src=upstream
      [ "$repos" != null ] || repos_src=absent
      if [ "$repos" != null ] && ! jq -e '.error == null and (.repos | type) == "array"' <<<"$repos" >/dev/null 2>&1; then repos=null; repos_src=error; fi
      printf '%s\n' "$repos" > "$tmpd/repos.json"

      # open handoffs: the last attempt per handoff_id whose outcome line says delivered (coord:brief's reading of the log),
      # not older than openHandoffDays; which of them are already closed by a report is the snapshot's business below
      audit="${cfg.stateDir}/audit.jsonl"; audit_state=absent; printf '{}\n' > "$tmpd/open.json"
      if [ -s "$audit" ]; then
        if jq -sc --argjson cut "$(( $(now_epoch) - ${toString cfg.openHandoffDays} * 86400 ))" '
            map(select(type == "object")) as $all | (INDEX($all[] | select(.phase == "outcome"); .audit_id)) as $byid
            | [$all[] | select(.phase == "attempt" and (.handoff_id | type) == "string" and (.host | type) == "string" and (.agent_id | type) == "string")]
            | group_by(.handoff_id) | map(last)
            | map(. as $a | ($byid[$a.audit_id | tostring] // null) as $o | select(($o.outcome // "") == "delivered")
                  | select(((.at // "") | try fromdateiso8601 catch 0) >= $cut)
                  | {key:.handoff_id, value:{host:.host, agent_id:.agent_id, task_ref:(.task_ref // null), sent_at:(.at // null),
                                              repo:(((.authorized_by.issue_url // "") | [capture("^https://github\\.com/(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/[0-9]+").r] | first) // null)}})
            | from_entries' "$audit" > "$tmpd/open.json" 2>/dev/null; then audit_state=ok; else printf '{}\n' > "$tmpd/open.json"; audit_state=unreadable; fi
      fi

      # the Coordinator's own panes (config, the running pane, past senders) are never workers, and a handoff that reached one
      # (a mistake this check now refuses) is not an open handoff: it must not keep the fleet busy or count as work (skills#28)
      coordinator_panes "$audit" > "$tmpd/panes.json"
      jq -c --slurpfile P "$tmpd/panes.json" 'with_entries(select((.value.host + "/" + .value.agent_id) as $p | ($P[0] | index($p)) == null))' "$tmpd/open.json" > "$tmpd/open.tmp" && mv "$tmpd/open.tmp" "$tmpd/open.json"
      # workers: every pane a handoff was attempted or parked to (any age, any outcome) plus coordinator.workers, minus the Coordinator's
      # panes; the inventory decides which of them exist right now
      printf '%s\n' ${lib.escapeShellArg (builtins.toJSON cfg.workers)} > "$tmpd/workers.json"
      if [ -s "$audit" ]; then
        jq -sc --slurpfile W "$tmpd/workers.json" '[.[] | select(type == "object" and (.phase == "attempt" or .phase == "parked") and (.host | type) == "string" and (.agent_id | type) == "string") | .host + "/" + .agent_id] + $W[0] | unique' "$audit" > "$tmpd/workers.tmp" 2>/dev/null \
          && mv "$tmpd/workers.tmp" "$tmpd/workers.json"
      fi
      jq -c --slurpfile P "$tmpd/panes.json" '. - $P[0]' "$tmpd/workers.json" > "$tmpd/workers.tmp" && mv "$tmpd/workers.tmp" "$tmpd/workers.json"
      jq -c --slurpfile W "$tmpd/workers.json" '[.hosts[]? | select(.reachable == true) | .host as $h | .agents[]? | select(.observed_state == "idle" or .observed_state == "done")
          | $h + "/" + .agent_id | select(. as $i | $W[0] | index($i))] | sort' "$tmpd/inv.json" > "$tmpd/free.json"
      coord_working=$(jq -r --slurpfile P "$tmpd/panes.json" '[.hosts[]? | select(.reachable == true) | .host as $h | .agents[]? | select(.observed_state == "working")
          | $h + "/" + .agent_id | select(. as $i | $P[0] | index($i))] | length > 0' "$tmpd/inv.json")
      [ "$coord_working" != true ] || printf '{"last_working_epoch":%s}\n' "$(now_epoch)" > "$dir/interactive.json"

      # the previous snapshot: absent means baseline; unreadable means the baseline is rebuilt and the owner is told
      baseline=false; reset=false; printf '{}\n' > "$tmpd/prev.json"
      if [ -e "$snap" ]; then
        if ! jq -c 'select(type == "object" and .schema_version == 1)' "$snap" > "$tmpd/prev.json" 2>/dev/null || [ ! -s "$tmpd/prev.json" ]; then
          printf '{}\n' > "$tmpd/prev.json"; baseline=true; reset=true
        fi
      else baseline=true; fi
      # parked sends (herdr:message refused agent_busy, skills#28 06:19Z): still parked while no attempt of that handoff followed
      # the refusal, no handoff for the same item was delivered after it, and no earlier delivered one for the item is still
      # open (open_handoffs minus the closed ones: a worker busy on the very item must not buy a second assignment, a
      # settled one leaves a follow-up to retry); not older than openHandoffDays
      printf '[]\n' > "$tmpd/parked.json"
      if [ "$audit_state" = ok ]; then
        jq -sc --argjson cut "$(( $(now_epoch) - ${toString cfg.openHandoffDays} * 86400 ))" --slurpfile O "$tmpd/open.json" --slurpfile P "$tmpd/prev.json" '
            def repo: ((.authorized_by.issue_url // "") | [capture("^https://github\\.com/(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/[0-9]+").r] | first) // null;
            map(select(type == "object")) as $all | (INDEX($all[] | select(.phase == "outcome"); .audit_id)) as $byid
            | [$all[] | select(.phase == "attempt") | . + {repo:repo, delivered:(($byid[.audit_id | tostring].outcome // "") == "delivered")}] as $att
            | [$all[] | select(.phase == "parked" and (.handoff_id | type) == "string" and (.host | type) == "string" and (.agent_id | type) == "string" and (.at | type) == "string")
               | select((.at | try fromdateiso8601 catch 0) >= $cut) | . + {repo:repo} | . as $k
               | ([$O[0] | keys[]] - [($P[0].closed_handoffs // {}) | keys[]]) as $live
               | select(any($att[]; (.handoff_id == $k.handoff_id and .at >= $k.at)
                                       or (.delivered and .repo == $k.repo and .task_ref == $k.task_ref
                                           and (.at >= $k.at or (.handoff_id as $i | $live | index($i)) != null))) | not)
               | {audit_id, handoff_id, host, agent_id, task_ref, repo, at}]' "$audit" > "$tmpd/parked.json" 2>/dev/null || printf '[]\n' > "$tmpd/parked.json"
      fi

      # the current snapshot: hosts keyed by machine label (this host under its own name), agents of an unreachable host and
      # repos without a source carried forward from the previous snapshot, so an outage hides nothing
      jq -cn --arg at "$at" --arg as "$audit_state" --slurpfile I "$tmpd/inv.json" --slurpfile R "$tmpd/repos.json" --slurpfile O "$tmpd/open.json" --slurpfile P "$tmpd/prev.json" '
        $I[0] as $inv | $R[0] as $repos | $O[0] as $open | $P[0] as $p
        | {schema_version:1, observed_at:$at,
           hosts:($inv.hosts | map((if .machine == null then "~" + .host else .machine end) as $k
                   | {key:$k, value:{host:.host, machine:.machine, reachable:.reachable, error_kind:(.error.kind // null),
                        agents:(if .reachable == true then (.agents | map({key:.agent_id, value:{state:.observed_state, seq:.state_change_seq, session_id, harness, task_ref}}) | from_entries)
                                else ($p.hosts[$k].agents // {}) end)}}) | from_entries),
           repos:(if $repos == null then ($p.repos // null) else ($repos.repos | map({key:.repo, value:{open_prs:(.open_prs // 0), approved_issues:(.approved_issues // 0), active:(.active // false)}}) | from_entries) end),
           open_handoffs:$open, closed_handoffs:(($p.closed_handoffs // {}) | with_entries(select(.key as $k | $open | has($k)))),
           audit_ok:($as != "unreadable"), idle_wake:($p.idle_wake // null)}' > "$tmpd/cur.json" || fail 2 malformed "herdr:inventory record has an unexpected shape" "$ctx"

      # F1 (sammasak/skills#28): an idle fleet with work left wakes the Coordinator once per distinct fleet+work fingerprint.
      # The fleet test costs nothing (the inventory); GitHub is asked only when every worker is idle/done: the open PRs (with
      # comments and reviews, for grades) and open issues of each active repo (newest push first, at most portfolioActive)
      # and of each open-handoff repo, plus the merged PRs of the handoff repos (verification). A gh failure, the issue
      # search's included (repos outside the page would go unchecked), skips the condition for this run and is recorded
      # under idle_wake.skipped, never guessed around
      fleet=$(jq -c --slurpfile W "$tmpd/workers.json" '[.hosts[]? | select(.reachable == true) | .host as $h | .agents[]? | select(($h + "/" + .agent_id) as $id | $W[0] | index($id))] as $a
                | all(.hosts[]?; .reachable == true) and ($a | length) > 0 and all($a[]; .observed_state == "idle" or .observed_state == "done")' "$tmpd/inv.json")
      skipped=null; : > "$tmpd/work.jsonl"
      if [ "$fleet" = true ]; then
        if [ "$repos_src" != upstream ]; then skipped=$(jq -cn --arg s "$repos_src" '"gh:repos unavailable (\($s)); the active repos are unknown"')
        elif [ "$(jq -r '.search.error != null' <<<"$repos")" = true ]; then skipped=$(jq -c '"gh:repos issue search failed (\(.search.error.kind): \(.search.error.message)); repos outside the page are unknown"' <<<"$repos")
        else
          gh_list() { timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} "$@" 2>/dev/null; }
          while IFS= read -r repo; do
            [ -n "$repo" ] || continue; rc=0; printf '[]\n' > "$tmpd/m.json"
            gh_list pr list -R "$repo" --state open --limit ${toString cfg.ghLimit} --json number,title,body,state,createdAt,url,headRefName,headRefOid,closingIssuesReferences,comments,reviews > "$tmpd/p.json" \
              || { rc=$?; skipped=$(jq -cn --arg r "$repo" --arg c "$rc" '"gh pr list -R \($r) --state open exited \($c)"'); break; }
            gh_list issue list -R "$repo" --state open --limit ${toString cfg.ghLimit} --json number,url,labels > "$tmpd/i.json" \
              || { rc=$?; skipped=$(jq -cn --arg r "$repo" --arg c "$rc" '"gh issue list -R \($r) exited \($c)"'); break; }
            if jq -e --arg r "$repo" 'any(.[]; .repo == $r)' "$tmpd/open.json" >/dev/null; then
              gh_list pr list -R "$repo" --state merged --limit ${toString cfg.ghLimit} --json number,title,body,mergedAt,createdAt,headRefName,closingIssuesReferences > "$tmpd/m.json" \
                || { rc=$?; skipped=$(jq -cn --arg r "$repo" --arg c "$rc" '"gh pr list -R \($r) --state merged exited \($c)"'); break; }
            fi
            jq -cn --arg r "$repo" --slurpfile p "$tmpd/p.json" --slurpfile i "$tmpd/i.json" --slurpfile m "$tmpd/m.json" \
              'if ($p[0] | type) == "array" and ($i[0] | type) == "array" and ($m[0] | type) == "array" then {repo:$r, prs:$p[0], issues:$i[0], merged:$m[0]} else error end' >> "$tmpd/work.jsonl" 2>/dev/null \
              || { skipped=$(jq -cn --arg r "$repo" '"gh returned unexpected JSON for \($r)"'); break; }
          done < <(jq -rn --slurpfile R "$tmpd/repos.json" --slurpfile O "$tmpd/open.json" --argjson cap ${toString cfg.portfolioActive} \
                     '([$R[0].repos[] | select(.active) | .repo] | .[:$cap]) + [$O[0][] | .repo // empty] | unique[]')
        fi
      fi
      jq -sc 'INDEX(.repo)' "$tmpd/work.jsonl" > "$tmpd/work.json"
      jq -nc -L ${./.} --argjson labels ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} --argjson skipped "$skipped" \
        --slurpfile inv "$tmpd/inv.json" --slurpfile work "$tmpd/work.json" --slurpfile open "$tmpd/open.json" --slurpfile prev "$tmpd/prev.json" --slurpfile workers "$tmpd/workers.json" \
        -f ${./.}/idle.jq > "$tmpd/idle.json" || fail 2 malformed "idle-fleet check failed" "$ctx"

      jq -c --argjson baseline "$baseline" --argjson reset "$reset" --arg snap "$snap" --arg audit "$audit" --slurpfile P "$tmpd/prev.json" --slurpfile W "$tmpd/idle.json" \
        --slurpfile K "$tmpd/parked.json" --slurpfile F "$tmpd/free.json" '
        $P[0] as $p | $W[0] as $w | . as $c | $K[0] as $parked | $F[0] as $free
        | def safe: tostring | gsub("[^A-Za-z0-9_:.@/#-]"; "?") | .[0:80];
          def ref(a): ((a.task_ref // "-") | safe);
          def n(x): (x | safe);
          def refs3(a): ((a[:3] | map(n(.)) | join(", ")) + (if (a | length) > 3 then ", +" + n((a | length) - 3) + " more" else "" end));
          # handoffs still open and not yet reported, the most recently sent one per agent
          ($c.open_handoffs | to_entries | map(select(.key as $k | ($c.closed_handoffs | has($k)) | not)) | sort_by(.value.sent_at // "")
             | map({key:(.value.host + "/" + .value.agent_id), value:(.value + {handoff_id:.key})}) | from_entries) as $byagent
        | def agent_lines($h; $a; $ac; $ap; $quiet):
            ($byagent[$h + "/" + $a] // null) as $ho
            | if $ac.state == "blocked" and ($ap == null or $ap.state != "blocked") then
                {kind:"blocked", host:$h, agent_id:$a, handoff_id:($ho.handoff_id // null), line:("blocked " + n($h) + "/" + n($a) + " " + ref(if $ho != null then $ho else $ac end) + " " + n($ac.harness // "?") + " seq " + n($ac.seq) + (if $ho != null then " handoff " + n($ho.handoff_id) else "" end) + " needs the owner")}
              elif $ap == null then
                (if $quiet then empty else {kind:"new", host:$h, agent_id:$a, handoff_id:null, line:("new " + n($h) + "/" + n($a) + " " + ref($ac) + " " + n($ac.harness // "?") + " " + n($ac.state // "unknown") + " seq " + n($ac.seq))} end)
              elif $ho != null and $ap.session_id != null and $ac.session_id != null and $ap.session_id != $ac.session_id then
                {kind:"replaced", host:$h, agent_id:$a, handoff_id:$ho.handoff_id, line:("replaced " + n($h) + "/" + n($a) + " " + ref($ho) + " handoff " + n($ho.handoff_id) + " is now a different session (" + n($ap.session_id) + " → " + n($ac.session_id) + ")")}
              elif $ho != null and (["idle","done"] | index($ac.state)) != null and ($ap.seq != $ac.seq or ($ac.seq == null and $ap.state == "working")) then
                {kind:"settled", host:$h, agent_id:$a, handoff_id:$ho.handoff_id, line:("settled " + n($h) + "/" + n($a) + " " + ref($ho) + " handoff " + n($ho.handoff_id) + " " + n($ac.state) + " seq " + n($ap.seq) + "→" + n($ac.seq))}
              else empty end;
        [
          (if $reset then {kind:"snapshot", line:("snapshot " + $snap + " was unreadable; baseline rebuilt")} else empty end),
          ($c.hosts | to_entries[] | .key as $k | .value as $hc | $hc.host as $h | ($p.hosts[$k] // null) as $hp
            | if $hc.reachable == false then
                (if $hp != null and $hp.reachable == true then {kind:"host", host:$h, line:("host " + n($h) + " unreachable (" + n($hc.error_kind // "error") + ")")} else empty end)
              else
                (if ($baseline | not) and ($hp == null or $hp.reachable == false) then
                   {kind:"host", host:$h, line:("host " + n($h) + (if $hp == null then " now listed (" else " reachable again (" end) + n($hc.agents | length) + " agents)")}
                 else empty end),
                ($hc.agents | to_entries[] | .key as $a | agent_lines($h; $a; .value; ($hp.agents[$a] // null); ($baseline or $hp == null))),
                (($hp.agents // {}) | to_entries[] | .key as $a
                  | select(($hc.agents[$a] // null) == null) | ($byagent[$h + "/" + $a] // null) as $ho | select($ho != null)
                  | {kind:"gone", host:$h, agent_id:$a, handoff_id:$ho.handoff_id, line:("gone " + n($h) + "/" + n($a) + " " + ref($ho) + " handoff " + n($ho.handoff_id) + " no longer listed")})
              end),
          (($p.hosts // {}) | to_entries[] | select(($c.hosts[.key] // null) == null) | .value as $hp
            | {kind:"host", host:$hp.host, line:("host " + n($hp.host) + " no longer listed (" + n($hp.agents | length) + " agents" + ([$hp.agents | keys[] | $byagent[$hp.host + "/" + .] // empty | .handoff_id] | if length == 0 then "" else ", open handoffs " + (map(n(.)) | join(" ")) end) + ")")}),
          (if $c.repos != null and ($p.repos // null) != null then
             ($c.repos | to_entries[] | .key as $r | .value as $rc | ($p.repos[$r] // null) as $rp
               | if $rp == null then (if $rc.active then {kind:"repo", repo:$r, line:("repo " + n($r) + " active: open_prs " + n($rc.open_prs) + " approved_issues " + n($rc.approved_issues))} else empty end)
                 elif $rp.open_prs != $rc.open_prs or $rp.approved_issues != $rc.approved_issues then
                   {kind:"repo", repo:$r, line:("repo " + n($r) + " open_prs " + n($rp.open_prs) + "→" + n($rc.open_prs) + " approved_issues " + n($rp.approved_issues) + "→" + n($rc.approved_issues))}
                 else empty end)
           else empty end),
          (if ($c.audit_ok | not) and ($p.audit_ok != false) then {kind:"audit", line:("audit " + $audit + " unreadable (not JSON lines); herdr:message refuses to send until the owner inspects it")} else empty end),
          # one retry line per item whose busy-refused sends are not reported yet, once a worker is free to take it
          (if ($free | length) > 0 then
             ($parked | map(select(.audit_id as $id | ($p.retried // {}) | has($id) | not)) | group_by([.repo, .task_ref])[]
               | {kind:"retry", repo:.[0].repo, task_ref:.[0].task_ref, audit_ids:map(.audit_id),
                  line:("retry " + n(.[0].repo // "no-repo") + ref(.[0]) + " " + n(length) + " send(s) refused agent_busy ("
                    + (map(n(.handoff_id) + "→" + n(.host) + "/" + n(.agent_id)) | join(", ")) + "); free worker(s): " + refs3($free))})
           else empty end),
          (if $w.fired then {kind:"idle", line:("idle " + n($w.agents) + " worker(s) idle/done on " + n($w.hosts) + " host(s); work left: "
             + ([(if ($w.work.open_prs | length) > 0 then n($w.work.open_prs | length) + " open PR(s) without a 9/10 review (" + refs3($w.work.open_prs) + ")" else empty end),
                 (if ($w.work.approved_issues | length) > 0 then n($w.work.approved_issues | length) + " approved issue(s) without a handoff (" + refs3($w.work.approved_issues) + ")" else empty end),
                 (if ($w.work.unverified_handoffs | length) > 0 then n($w.work.unverified_handoffs | length) + " unverified handoff(s) (" + refs3($w.work.unverified_handoffs) + ")" else empty end)] | join(", ")))}
           else empty end)
        ]' "$tmpd/cur.json" > "$tmpd/changes.json" || fail 2 malformed "snapshot diff failed" "$ctx"

      # a reported handoff is closed from now on; a fired idle line is not repeated until the fleet or the work changes
      jq -c --arg at "$at" --slurpfile C "$tmpd/changes.json" --slurpfile W "$tmpd/idle.json" --slurpfile P "$tmpd/prev.json" --slurpfile K "$tmpd/parked.json" '
        .closed_handoffs += ([$C[0][] | select(.kind == "settled" or .kind == "gone" or .kind == "replaced") | {key:.handoff_id, value:{kind, at:$at}}] | from_entries)
        # a reported parked send stays reported while it is still parked; a resolved one drops out
        | .retried = ((($P[0].retried // {}) + ([$C[0][] | select(.kind == "retry") | .audit_ids[] | {key:., value:$at}] | from_entries))
                      | with_entries(select(.key as $k | any($K[0][]; .audit_id == $k))))
        | if $W[0].fired then .idle_wake = {fingerprint:$W[0].fingerprint, at:$at} else . end' "$tmpd/cur.json" > "$tmpd/next.json" || fail 2 malformed "snapshot update failed" "$ctx"
      jq -cn --arg at "$at" --argjson b "$baseline" --argjson r "$reset" --argjson ck "$consume" --arg rs "$repos_src" --arg as "$audit_state" --arg s "$snap" \
         --slurpfile C "$tmpd/changes.json" --slurpfile I "$tmpd/inv.json" --slurpfile N "$tmpd/next.json" --slurpfile W "$tmpd/idle.json" --slurpfile P "$tmpd/panes.json" --slurpfile K "$tmpd/parked.json" '
        {schema_version:1, task:"coord:changed", observed_at:$at, baseline:$b, snapshot_reset:$r, consume:$ck, snapshot:$s, coordinator_panes:$P[0],
         sources:{herdr:{answered_hosts:($I[0].answered_hosts // 0), hosts_total:($I[0].hosts_total // 0)}, repos:$rs, audit:$as},
         open_handoffs:(($N[0].open_handoffs | length) - ($N[0].closed_handoffs | length)), parked:$K[0], idle_wake:$W[0], changes:$C[0]}' > "$tmpd/rec.json" || fail 2 malformed "record build failed" "$ctx"
      # the wake budget (wakes.json: epoch seconds of past printing runs, pruned to the window): a printing run within the
      # min gap of the last one, or beyond the hourly cap, is deferred: nothing printed, snapshot untouched, so its changes
      # stay pending and surface together on the first allowed run. A non-consuming read never spends or checks the budget.
      wakes="$dir/wakes.json"; now=$(now_epoch); gap=${toString cfg.wakeMinGapSeconds}; cap=${toString cfg.wakeMaxPerHour}
      window=$(( gap > 3600 ? gap : 3600 ))
      recent=$(jq -c --argjson now "$now" --argjson w "$window" '[.[]? | numbers | select(. > $now - $w)]' "$wakes" 2>/dev/null) || recent='[]'
      nchanges=$(jq 'length' "$tmpd/changes.json"); deferred=false; reason=null; next_at=null
      if [ "$consume" = true ] && [ "$nchanges" -gt 0 ]; then
        last=$(jq -r 'max // 0' <<<"$recent"); hour=$(jq -r --argjson now "$now" '[.[] | select(. > $now - 3600)] | length' <<<"$recent")
        quiet=${toString cfg.interactiveQuietSeconds}; iw_last=$(jq -r '.last_working_epoch // 0' "$dir/interactive.json" 2>/dev/null) || iw_last=0; [[ "$iw_last" =~ ^[0-9]+$ ]] || iw_last=0
        if [ "$quiet" -gt 0 ] && { [ "$coord_working" = true ] || [ $((now - iw_last)) -lt "$quiet" ]; }; then
          base=$iw_last; [ "$coord_working" != true ] || base=$now
          deferred=true; reason='"interactive_coordinator"'; next_at=$((base + quiet))
        elif [ "$gap" -gt 0 ] && [ $((now - last)) -lt "$gap" ]; then deferred=true; reason='"min_gap"'; next_at=$((last + gap))
        elif [ "$hour" -ge "$cap" ]; then deferred=true; reason='"per_hour_cap"'; next_at=$(( $(jq -r --argjson now "$now" '[.[] | select(. > $now - 3600)] | min' <<<"$recent") + 3600 )); fi
      fi
      wake=$(jq -cn --argjson d "$deferred" --argjson r "$reason" --argjson n "$next_at" --argjson h "$(jq -r --argjson now "$now" '[.[] | select(. > $now - 3600)] | length' <<<"$recent")" --argjson g "$gap" --argjson c "$cap" \
        '{deferred:$d, reason:$r, next_allowed_at:(if $n == null then null else ($n | todate) end), wakes_last_hour:$h, min_gap_seconds:$g, max_per_hour:$c}')
      # a deferred run is silent on stdout by contract (a line there starts a session), so it says why on stderr
      [ "$deferred" != true ] || echo "coord:changed: wake deferred ($(jq -r . <<<"$reason")) until $(jq -r .next_allowed_at <<<"$wake"); $nchanges change(s) pending" >&2
      # .changes is what was printed, nothing else: a deferred run keeps its lines under wake.pending, so a timer that
      # reads .changes instead of stdout starts no session either
      jq -c --argjson w "$wake" 'if $w.deferred then . + {wake:($w + {pending:.changes}), changes:[]} else . + {wake:$w} end' "$tmpd/rec.json" > "$tmpd/rec2.json" && mv "$tmpd/rec2.json" "$tmpd/rec.json" || fail 2 malformed "record build failed" "$ctx"
      # record and lines first, the snapshot last: a failure here repeats a change on the next run rather than losing it
      if [ "$consume" = true ]; then cp "$tmpd/rec.json" "$tmpd/latest.json" && mv "$tmpd/latest.json" "$dir/latest.json" || fail 2 state_unwritable "cannot write $dir/latest.json" "$ctx"; fi
      cat "$tmpd/rec.json" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
      if [ "$deferred" = true ]; then exit 0; fi
      # stdout is the contract for the timer: empty when nothing is actionable, one line per change otherwise
      jq -r '.changes[].line' "$tmpd/rec.json"
      # the wake is spent after the lines are out: a crash in between repeats the wake rather than swallowing it
      if [ "$consume" = true ] && [ "$nchanges" -gt 0 ]; then
        jq -cn --argjson r "$recent" --argjson now "$now" '$r + [$now]' > "$tmpd/wakes.json" && mv "$tmpd/wakes.json" "$wakes" || fail 2 state_unwritable "cannot write $wakes" "$ctx"
      fi
      if [ "$consume" = true ]; then mv "$tmpd/next.json" "$snap" || fail 2 state_unwritable "cannot write $snap" "$ctx"; fi
    '';
  };
}
