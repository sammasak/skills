# coord:changed F1 (sammasak/skills#28): is the fleet idle with work left? Inputs (slurped): $inv (herdr:inventory),
# $work ({"OWNER/REPO": {prs (open), merged, issues}}, fetched only for an idle fleet, {} otherwise), $open (the open
# delivered handoffs by id, with repo), $prev (the previous snapshot), $workers (host/agent_id of every handoff target
# plus coordinator.workers); $labels (the authorizing labels), $skipped (why GitHub was not asked or did not answer, else
# null). Output: the idle_wake record; fired means the line prints this run.
include "evidence";
$inv[0] as $inv | $work[0] as $work | $open[0] as $open | $prev[0] as $prev | $workers[0] as $workers
# an agent is its pane (host/agent_id), not its session: /clear and a harness restart keep the pane and must not buy a
# new wake for the same work; herdr never reuses a pane id, so a new worker still changes the fingerprint. The fleet is
# the workers among the listed agents: the Coordinator's own panes (never a handoff target) do not keep it busy
| [$inv.hosts[]? | .host as $h | .agents[]? | {id:($h + "/" + .agent_id), state:(.observed_state // "unknown")}] as $all
| [$all[] | select(.id as $i | $workers | index($i))] as $agents
# idle: every host answered, at least one worker, every worker idle or done (blocked, working and unknown are not idle)
| (all($inv.hosts[]?; .reachable == true) and ($agents | length) > 0 and all($agents[]; .state == "idle" or .state == "done")) as $idle
| ($open | to_entries | map(.value + {handoff_id:.key})) as $hs
| (if $idle and $skipped == null then
     # a PR's implementer: the agent holding an open handoff for the issue the PR names, sent before the PR was opened;
     # its own grade is a review it did, not an independent one (a handoff older than openHandoffDays is not seen here,
     # so its implementer's self-grade would count: under-wakes only)
     def impl($r): . as $pr | [$hs[] | select(.repo == $r) | (.task_ref | num) as $n | select($n != null and ($pr | refs($n)) and ($pr.createdAt // "") >= (.sent_at // "")) | .host + "/" + .agent_id];
     # an open PR's head, by its review state (skills#77): unreviewed is a review to hand out (the head in the key, so a new
     # head is a new item), findings go back to the implementer, disputed is the owner's, in_review and passed are no work;
     # a merged or closed PR is never one of them. A review handoff is in review while it is open and not reported yet
     def in_review($r): . as $pr | [$hs[] | select(.review != null and .review.pr == ($r + "#" + ($pr.number | tostring)) and .review.head == ($pr.headRefOid // ""))
                                   | select(.handoff_id as $k | ($prev.closed_handoffs // {}) | has($k) | not) | .host + "/" + .agent_id];
     def head7: (.headRefOid // "") | .[0:7];
     ([$work | to_entries[] | .key as $r | .value.prs[] | select(.state == "OPEN") | . as $pr
       | {pr:($r + "#" + (.number | tostring) + "@" + head7)} + ($pr | review_state($pr | impl($r); $pr | in_review($r)))]) as $states
     | {open_prs:[$states[] | select(.state == "unreviewed") | .pr],
      pr_findings:[$states[] | select(.state == "findings") | {pr, implementer, grades}],
      pr_disputed:[$states[] | select(.state == "disputed") | .pr],
      # an approved issue is held only by an open handoff; every worker is idle here, so that is one with an open PR naming
      # the issue: a handoff whose agent settled with no open PR leaves the item to hand out again (skills#28)
      approved_issues:[$work | to_entries[] | .key as $r | .value.prs as $prs | .value.issues[] | .number as $num
                 | select(any((.labels // [])[]; (.name // "") as $l | ($labels | index($l)) != null))
                 | select(any($hs[]; .repo == $r and (.task_ref | num) == $num) and any($prs[]; .state == "OPEN" and refs($num)) | not)
                 | $r + "#" + ($num | tostring)],
      # verified = any merged PR naming the issue, opened after the send (no per-pane window as in work:status: on a shared
      # epic one agent's merged PR clears the others' handoffs, which can only under-wake, never wake wrongly)
      unverified_handoffs:[$hs[] | . as $h | (.task_ref | num) as $n
                 | (if $n == null or .repo == null then false
                    else (($work[.repo].merged // []) | any(.[]; .mergedAt != null and refs($n) and ((.createdAt // "") >= ($h.sent_at // "")))) end) as $verified
                 | select($verified | not) | .handoff_id + ":" + (.task_ref // "-")]}
     | map_values(sort_by(if type == "object" then .pr else . end))
   else null end) as $w
| (if $w == null then null else {agents:([$agents[].id] | sort), work:([($w.open_prs[] | "pr:" + .), ($w.pr_findings[] | "fix:" + .pr), ($w.pr_disputed[] | "disputed:" + .),
                                                                  ($w.approved_issues[] | "issue:" + .), ($w.unverified_handoffs[] | "handoff:" + .)] | sort)} end) as $fp
| {fleet_idle:$idle, agents:($agents | length), non_workers:(($all | length) - ($agents | length)), hosts:($inv.hosts | length), evaluated:($w != null), skipped:$skipped, work:$w, fingerprint:$fp,
   fired:($w != null and ($fp.work | length) > 0 and $fp != $prev.idle_wake.fingerprint)}
