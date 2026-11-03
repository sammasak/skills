# coord:changed F1 (sammasak/skills#28): is the fleet idle with work left? Inputs (slurped): $inv (herdr:inventory),
# $work ({"OWNER/REPO": {prs (open), merged, issues}}, fetched only for an idle fleet, {} otherwise), $open (the open
# delivered handoffs by id, with repo), $prev (the previous snapshot); $labels (the authorizing labels), $skipped (why
# GitHub was not asked or did not answer, else null). Output: the idle_wake record; fired means the line prints this run.
include "evidence";
$inv[0] as $inv | $work[0] as $work | $open[0] as $open | $prev[0] as $prev
| [$inv.hosts[]? | .host as $h | .agents[]? | {id:($h + "/" + .agent_id + "/" + ((.session_id // "-") | tostring)), state:(.observed_state // "unknown")}] as $agents
# idle: every host answered, at least one agent, every agent idle or done (blocked, working and unknown are not idle)
| (all($inv.hosts[]?; .reachable == true) and ($agents | length) > 0 and all($agents[]; .state == "idle" or .state == "done")) as $idle
| ($open | to_entries | map(.value + {handoff_id:.key})) as $hs
| (if $idle and $skipped == null then
     # a PR's implementer: the agent holding an open handoff for the issue the PR names, sent before the PR was opened;
     # its own grade is a review it did, not an independent one
     def impl($r): . as $pr | [$hs[] | select(.repo == $r) | (.task_ref | num) as $n | select($n != null and ($pr | refs($n)) and ($pr.createdAt // "") >= (.sent_at // "")) | .host + "/" + .agent_id];
     {open_prs:[$work | to_entries[] | .key as $r | .value.prs[] | select(.state == "OPEN") | . as $pr | ($pr | impl($r)) as $i
                 | select(any($pr | passes[]; .by as $b | ($i | index($b)) == null) | not) | $r + "#" + (.number | tostring)],
      approved_issues:[$work | to_entries[] | .key as $r | .value.issues[] | .number as $num
                 | select(any((.labels // [])[]; (.name // "") as $l | ($labels | index($l)) != null))
                 | select(any($hs[]; .repo == $r and (.task_ref | num) == $num) | not) | $r + "#" + ($num | tostring)],
      unverified_handoffs:[$hs[] | . as $h | (.task_ref | num) as $n
                 | (if $n == null or .repo == null then false
                    else (($work[.repo].merged // []) | any(.[]; .mergedAt != null and refs($n) and ((.createdAt // "") >= ($h.sent_at // "")))) end) as $verified
                 | select($verified | not) | .handoff_id + ":" + (.task_ref // "-")]}
     | map_values(sort)
   else null end) as $w
| (if $w == null then null else {agents:([$agents[].id] | sort), work:([($w.open_prs[] | "pr:" + .), ($w.approved_issues[] | "issue:" + .), ($w.unverified_handoffs[] | "handoff:" + .)] | sort)} end) as $fp
| {fleet_idle:$idle, agents:($agents | length), hosts:($inv.hosts | length), evaluated:($w != null), skipped:$skipped, work:$w, fingerprint:$fp,
   fired:($w != null and ($fp.work | length) > 0 and $fp != $prev.idle_wake.fingerprint)}
