# coord:capacity / coord:spawn (skills #28 W1): per-host worker capacity from herdr:inventory and the configured limits.
# Inputs: $inv (herdr:inventory, slurped), $cap ({"<host label>": {heavy_jobs, max_workers, spawn}}, matched
# case-insensitively), $kinds ({"<kind>": {tier, model, heavy}}), $audit (audit.jsonl lines, slurped; [] when none),
# $usage ({"<host>/<agent_id>": context tokens} for local Claude sessions), $next ({repo, task_ref} or null),
# $threshold (context tokens that call for /compact or /clear), $at, $now (epoch seconds).
# Heavy-job slots are held by every worker spawned for a heavy kind (whatever its state: it was started to run heavy
# gates), by a busy or unknown worker whose kind is not known, and by a heavy spawn still in flight (an attempt line with
# no outcome yet, younger than the agent-start bound); an in-flight spawn also holds a worker slot.
$inv[0] as $inv | $audit[0] as $audit | $usage[0] as $usage | (($locks // [null])[0]) as $locks
| ($cap | with_entries(.key |= ascii_downcase)) as $cap
# the last delivered handoff or started spawn per pane and session: what the worker last worked on
| (($audit | map(select(type == "object")) | INDEX(.[] | select(.phase == "outcome"); .audit_id)) as $out
   | [$audit[] | select(type == "object" and (.phase == "attempt" or (.phase == "spawn" and .stage == "attempt")))
      | select(($out[.audit_id | tostring].outcome // "") == "delivered" or ($out[.audit_id | tostring].outcome // "") == "started")
      | {host, agent_id:(.agent_id // ($out[.audit_id | tostring].agent_id // null)), session_id:(.session_id // ($out[.audit_id | tostring].session_id // null)),
         task_ref:(.task_ref // null), repo:((.authorized_by.issue_url // "") | [capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/").r] | first), at}]) as $work
# the kind of each pane a spawn created (started, or left blocked at startup), and the spawns still in flight
| (($audit | map(select(type == "object")) | INDEX(.[] | select(.phase == "outcome"); .audit_id)) as $out
   | [$audit[] | select(type == "object" and .phase == "spawn" and .stage == "attempt")] as $sp
   | {kind_of:([$sp[] | ($out[.audit_id | tostring] // null) as $o | select(($o.agent_id | type) == "string")
                | {key:(.host + "/" + $o.agent_id), value:.kind}] | from_entries),
      inflight:[$sp[] | select($out[.audit_id | tostring] == null and (((.at // "") | try fromdateiso8601 catch 0) >= $now - 120)) | {host, kind}]}) as $spawns
| def heavy_kind: . != null and ($kinds[.].heavy // false);
  def last_work($h; $a; $s): [$work[] | select(.host == $h and .agent_id == $a and (.session_id == null or $s == null or .session_id == $s))] | sort_by(.at) | last;
  def busy: . == "working" or . == "blocked";
  def idle: . == "idle" or . == "done";
{schema_version:1, task:"coord:capacity", observed_at:$at, kinds:$kinds, context_threshold:$threshold, next:$next,
 hosts:[$inv.hosts[]? | . as $hst
   | ($cap[$hst.host | ascii_downcase] // null) as $c
   # the host's lock lanes (host:locks): the heavy lane's holder plus waiters are jobs the lock will run one by one
   | (if $locks == null then null else ([$locks.hosts[]? | select((.host | ascii_downcase) == ($hst.host | ascii_downcase))] | first // null) end) as $lq
   | (($lq.lanes // []) | map(select(.lane == "heavy-work")) | first // null) as $heavy_lane
   | ($heavy_lane.queue_depth // 0) as $heavy_queue
   | [$hst.agents[]? | . as $a | ($a.observed_state // "unknown") as $s | last_work($hst.host; $a.agent_id; $a.session_id) as $w
       | ($usage["\($hst.host)/\($a.agent_id)"] // null) as $tok
       | ($next != null and $w != null and ($next.repo != $w.repo or $next.task_ref != $w.task_ref)) as $independent
       | {agent_id:$a.agent_id, harness:$a.harness, herdr_state:$s, session_id:$a.session_id, kind:($spawns.kind_of["\($hst.host)/\($a.agent_id)"] // null), last_task_ref:($w.task_ref // null), last_repo:($w.repo // null),
          hygiene:({context_tokens:$tok} + (
            if ($s | idle | not) then {advice:null, reasons:[]}
            elif $independent then {advice:"/clear", reasons:["next assignment \($next.repo // "?")\($next.task_ref // "") is independent of its last (\($w.repo // "?")\($w.task_ref // ""))"]
                                     + (if $tok != null and $tok >= $threshold then ["context \($tok) tokens >= \($threshold)"] else [] end)}
            elif $tok != null and $tok >= $threshold then {advice:"/compact", reasons:["context \($tok) tokens >= \($threshold)"]}
            else {advice:null, reasons:[]} end))}] as $ws
   | ([$ws[] | select(.herdr_state | idle)] | length) as $idle
   | ([$ws[] | select(.herdr_state | busy)] | length) as $busy
   | (($ws | length) - $idle - $busy) as $unknown
   | [$spawns.inflight[] | select((.host | ascii_downcase) == ($hst.host | ascii_downcase))] as $fly
   | ([$ws[] | select((.kind | heavy_kind) or (.kind == null and (.herdr_state | idle | not)))] | length) as $heavy_held
   | ($heavy_held + ([$fly[] | select(.kind | heavy_kind)] | length)) as $heavy_used
   | (($ws | length) + ($fly | length)) as $slots_used
   | (if $c == null then 0 else ([$c.max_workers - $slots_used, 0] | max) end) as $free_w
   | (if $c == null then 0 else ([$c.heavy_jobs - $heavy_used, 0] | max) end) as $free_h
   | ($hst.reachable != false) as $up
   | ($up and $c != null and $c.spawn == true and $free_w > 0) as $light
   | ($light and $free_h > 0 and ($c == null or $heavy_queue < $c.heavy_jobs)) as $heavy
   | {host:$hst.host, machine:($hst.machine // null), reachable:$up, configured:($c != null),
      limits:(if $c == null then null else {heavy_jobs:$c.heavy_jobs, max_workers:$c.max_workers, spawn:$c.spawn} end),
      workers:{total:($ws | length), idle:$idle, busy:$busy, unknown:$unknown, spawning:($fly | length), list:$ws},
      free:{workers:$free_w, heavy_jobs:$free_h},
      lock_queue:(if $lq == null then {observed:false, lanes:[]} else {observed:$lq.reachable, error:$lq.error, lanes:$lq.lanes} end),
      spawn_ok:{light:$light, heavy:$heavy},
      fits:{spawn:[$kinds | to_entries[] | select(if .value.heavy then $heavy else $light end) | .key],
            idle_worker:[$kinds | to_entries[] | select($up and $idle > 0 and ((.value.heavy | not) or $free_h > 0)) | .key]},
      reasons:([if $up | not then "host did not answer" else empty end, if $c == null then "no capacity configured for this host (coordinator.capacity)" else empty end,
                if $c != null and $c.spawn != true then "spawning is off for this host" else empty end,
                if $c != null and $free_w == 0 then "\($slots_used) of \($c.max_workers) workers in use" else empty end,
                if $c != null and $free_h == 0 then "\($heavy_used) of \($c.heavy_jobs) heavy-job slots taken" else empty end,
                if $c != null and $heavy_queue >= $c.heavy_jobs then "heavy-work lane: \($heavy_queue) on the lock (\($heavy_lane.holder.what // "?") for \(($heavy_lane.holder.age_s // 0) / 60 | floor) min)" else empty end])}],
 failed_sources:([$inv.hosts[]? | select(.reachable == false) | {source:("herdr:inventory:" + .host), error}] + (if $locks == null then [{source:"host:locks", error:{kind:"missing", message:"host:locks produced no output"}}] else [$locks.hosts[]? | select(.reachable == false) | {source:("host:locks:" + .host), error}] end) + (if $inv.machines_error != null then [{source:"herdr:machine-list", error:$inv.machines_error}] else [] end))}
| .partial = ((.failed_sources | length) > 0)
