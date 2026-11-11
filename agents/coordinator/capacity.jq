# coord:capacity / coord:spawn (skills #28 W1): per-host worker capacity from herdr:inventory and the configured limits.
# Inputs: $inv (herdr:inventory, slurped), $cap ({"<host label>": {worker, heavy_jobs, max_workers, slots?, spawn, heavy_gates}}, matched
# case-insensitively; heavy_gates defaults true, false refuses heavy gates on that host -- finding 6, nixos-config#109),
# $kinds ({"<kind>": {tier, model, heavy}}), $audit (audit.jsonl lines, slurped; [] when none),
# $usage ({"<host>/<agent_id>": context tokens} for local Claude sessions),
# $slots ({"<nspawn host>": {reachable, error, units:{"<unit>": "<systemctl is-active state>"}, workspaces:{"<label>": "<workspace_id>"}}}), $next ({repo, task_ref}
# or null), $threshold (context tokens that call for /compact or /clear), $at, $now (epoch seconds).
# Heavy-job slots are held by every worker spawned for a heavy kind (whatever its state: it was started to run heavy
# gates), by a busy or unknown worker whose kind is not known, and by a heavy spawn still in flight (an attempt line with
# no outcome yet, younger than the agent-start bound); an in-flight spawn also holds a worker slot.
# A worker:"nspawn" host counts only its containers: a slot is in use when its unit is active (asked over ssh) or a spawn
# for it is in flight; the slot's worker is the claude agent in the host Herdr workspace its start hook created (label =
# the container name). Its transcript is inside the container: context size unknown (null).
$inv[0] as $inv | $audit[0] as $audit | $usage[0] as $usage | (($locks // [null])[0]) as $locks | (($slots // [{}])[0]) as $slots
| [$cap | to_entries[] | select(.value.worker == "nspawn")] as $boxes
| [$boxes[] | .key | ascii_downcase] as $boxnames
| ($cap | with_entries(.key |= ascii_downcase)) as $cap
| ($audit | map(select(type == "object")) | INDEX(.[] | select(.phase == "outcome"); .audit_id)) as $out
# the last delivered handoff or started spawn per pane and session: what the worker last worked on
| [$audit[] | select(type == "object" and (.phase == "attempt" or (.phase == "spawn" and .stage == "attempt")))
   | select(($out[.audit_id | tostring].outcome // "") == "delivered" or ($out[.audit_id | tostring].outcome // "") == "started")
   | {host, agent_id:(.agent_id // ($out[.audit_id | tostring].agent_id // null)), session_id:(.session_id // ($out[.audit_id | tostring].session_id // null)),
      task_ref:(.task_ref // null), repo:((.authorized_by.issue_url // "") | [capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/").r] | first), at, handoff:(.phase == "attempt")}] as $work
# the kind of each pane a spawn created (started, or left blocked at startup), and the spawns still in flight
| [$audit[] | select(type == "object" and .phase == "spawn" and .stage == "attempt")] as $sp
| {kind_of:([$sp[] | ($out[.audit_id | tostring] // null) as $o | select(($o.agent_id | type) == "string")
             | {key:(.host + "/" + $o.agent_id), value:.kind}] | from_entries),
   inflight:[$sp[] | select($out[.audit_id | tostring] == null and (((.at // "") | try fromdateiso8601 catch 0) >= $now - 120)) | {host, kind}]} as $spawns
| def heavy_kind: . != null and ($kinds[.].heavy // false);
  def last_work($h; $a; $s): [$work[] | select(.host == $h and .agent_id == $a and (.session_id == null or $s == null or .session_id == $s))] | sort_by(.at) | last;
  def busy: . == "working" or . == "blocked";
  def idle: . == "idle" or . == "done";
  def hygiene($s; $w; $tok; $src):
    ($next != null and $w != null and ($next.repo != $w.repo or $next.task_ref != $w.task_ref)) as $independent
    | {context_tokens:$tok, context_source:$src} + (
        if ($s | idle | not) then {advice:null, reasons:[]}
        elif $independent then {advice:"/clear", reasons:["next assignment \($next.repo // "?")\($next.task_ref // "") is independent of its last (\($w.repo // "?")\($w.task_ref // ""))"]
                                 + (if $tok != null and $tok >= $threshold then ["context \($tok) tokens >= \($threshold)"] else [] end)}
        elif $tok != null and $tok >= $threshold then {advice:"/compact", reasons:["context \($tok) tokens >= \($threshold)"]}
        else {advice:null, reasons:[]} end);
  # the last spawn into a slot that is still its current boot (no reap after it, started or in flight), and whether an
  # in-flight attempt reserves the slot before its unit is active
  def slot_spawn($h; $slot):
    ([$sp[] | select(.host == $h and .slot == $slot)] | last) as $s
    | ([$audit[] | select(type == "object" and .phase == "reap" and .host == $h and .slot == $slot)] | last) as $r
    | (if $s == null then null else $s + {outcome:($out[$s.audit_id | tostring].outcome // null)} end) as $s
    | {spawn:(if $s != null and ($r == null or $s.at >= $r.at) and ($s.outcome == null or $s.outcome == "started") then $s else null end),
       reserved:($s != null and $s.outcome == null and ((($s.at // "") | try fromdateiso8601 catch 0) >= $now - 120))};
  # one host's record from its workers ($ws), in-flight spawns ($fly) and limits ($c); $extra adds per-kind fields
  def host_record($hst; $c; $ws; $fly; $extra):
    (if $locks == null then null else ([$locks.hosts[]? | select((.host | ascii_downcase) == ($hst.host | ascii_downcase))] | first // null) end) as $lq
    | (($lq.lanes // []) | map(select(.lane == "heavy-work")) | first // null) as $heavy_lane
    | ($heavy_lane.queue_depth // 0) as $heavy_queue
    # a worker at its usage limit is neither idle nor busy: it holds its slot and takes no work
    | ([$ws[] | select(.unavailable == null and (.herdr_state | idle))] | length) as $idle
    | ([$ws[] | select(.unavailable == null and (.herdr_state | busy))] | length) as $busy
    | ([$ws[] | select(.unavailable != null)] | length) as $unavail
    | (($ws | length) - $idle - $busy - $unavail) as $unknown
    | ([$ws[] | select((.kind | heavy_kind) or (.kind == null and (.herdr_state | idle | not)))] | length) as $heavy_held
    | ($heavy_held + ([$fly[] | select(.kind | heavy_kind)] | length)) as $heavy_used
    | (($ws | length) + ($fly | length)) as $slots_used
    | (if $c == null then 0 else ([$c.max_workers - $slots_used, 0] | max) end) as $free_w
    | (if $c == null then 0 else ([$c.heavy_jobs - $heavy_used, 0] | max) end) as $free_h
    | ($hst.reachable != false) as $up
    | ($up and $c != null and $c.spawn == true and $free_w > 0) as $light
    # heavy gates are refused on a host whose capability says heavy_gates:false (finding 6: lenovo, the control plane, was
    # OOM-killed twice mid platform:verify, nixos-config#109); unset means true, so existing hosts are unaffected
    | ($light and ($c.heavy_gates != false) and $free_h > 0 and ($c == null or $heavy_queue < $c.heavy_jobs)) as $heavy
    | {host:$hst.host, machine:($hst.machine // null), reachable:$up, configured:($c != null),
       limits:(if $c == null then null else {worker:($c.worker // "host"), slots:($c.slots | if type == "array" then length else null end), heavy_jobs:$c.heavy_jobs, max_workers:$c.max_workers, spawn:$c.spawn, heavy_gates:($c.heavy_gates != false)} end),
       workers:{total:($ws | length), idle:$idle, busy:$busy, unavailable:$unavail, unknown:$unknown, spawning:($fly | length), list:$ws},
       free:{workers:$free_w, heavy_jobs:$free_h},
       lock_queue:(if $lq == null then {observed:false, lanes:[]} else {observed:$lq.reachable, error:$lq.error, lanes:$lq.lanes} end),
       spawn_ok:{light:$light, heavy:$heavy},
       fits:{spawn:[$kinds | to_entries[] | select(if .value.heavy then $heavy else $light end) | .key],
             idle_worker:[$kinds | to_entries[] | select($up and $idle > 0 and ((.value.heavy | not) or $free_h > 0)) | .key]},
       reasons:([if $up | not then "host did not answer" else empty end,
                 if $unavail > 0 then "\($unavail) worker(s) unavailable (usage limit): " + ([$ws[] | select(.unavailable != null) | .agent_id] | join(", ")) else empty end, if $c == null then "no capacity configured for this host (coordinator.capacity)" else empty end,
                 if $c != null and $c.spawn != true then "spawning is off for this host" else empty end,
                 if $c != null and $c.heavy_gates == false then "this host runs no heavy gates (heavy_gates:false): light assignments only" else empty end,
                 if $c != null and $free_w == 0 then "\($slots_used) of \($c.max_workers) " + (if $c.worker == "nspawn" then "worker slots" else "workers" end) + " in use" else empty end,
                 if $c != null and $free_h == 0 then "\($heavy_used) of \($c.heavy_jobs) heavy-job slots taken" else empty end,
                 if $c != null and $heavy_queue >= $c.heavy_jobs then "heavy-work lane: \($heavy_queue) on the lock (\($heavy_lane.holder.what // "?") for \(($heavy_lane.holder.age_s // 0) / 60 | floor) min)" else empty end])}
    + $extra;
{schema_version:1, task:"coord:capacity", observed_at:$at, kinds:$kinds, context_threshold:$threshold, next:$next,
 hosts:([$inv.hosts[]? | select((.host | ascii_downcase) as $n | $boxnames | index($n) | not) | . as $hst
   | ($cap[$hst.host | ascii_downcase] // null) as $c
   | [$hst.agents[]? | . as $a | ($a.observed_state // "unknown") as $s | last_work($hst.host; $a.agent_id; $a.session_id) as $w
       | ($usage["\($hst.host)/\($a.agent_id)"] // null) as $tok
       | {agent_id:$a.agent_id, harness:$a.harness, herdr_state:$s, unavailable:($a.unavailable // null), session_id:$a.session_id, kind:($spawns.kind_of["\($hst.host)/\($a.agent_id)"] // null), last_task_ref:($w.task_ref // null), last_repo:($w.repo // null),
          hygiene:hygiene($s; $w; $tok; (if $tok == null then null else "host transcript" end))}] as $ws
   | host_record($hst; $c; $ws; [$spawns.inflight[] | select((.host | ascii_downcase) == ($hst.host | ascii_downcase))]; {})]
  + [$boxes[] | .key as $h | $cap[$h | ascii_downcase] as $c
   | ($slots[$h] // {reachable:false, error:"slot units not observed", units:{}, workspaces:{}}) as $pr
   | ([$inv.hosts[]? | select((.host | ascii_downcase) == ($h | ascii_downcase))] | first // null) as $hst
   | [$c.slots[] | . as $s | slot_spawn($h; $s.container) as $ev
       | ($pr.units[$s.unit] // "unknown") as $us | ($pr.workspaces[$s.container] // null) as $wsid
       | {container:$s.container, unit:$s.unit, unit_state:$us, workspace_id:$wsid,
          active:($us | IN("active", "activating", "deactivating", "reloading", "refreshing")), reserved:$ev.reserved, spawn:$ev.spawn,
          agent:(if $wsid == null then null else [($hst.agents // [])[] | select(.workspace_id == $wsid)] | (map(select(.harness == "claude")) + .) | first // null end)}
       | .reserved = (.reserved and (.active | not))] as $sl
   | [$sl[] | select(.active) | . as $x | ($x.agent.observed_state // "unknown") as $st
       | (if $x.agent == null then null else [$work[] | select(.host == $h and .agent_id == $x.agent.agent_id and .at >= ($x.spawn.at // ""))] | sort_by(.at) | last end) as $w
       | {agent_id:($x.agent.agent_id // null), harness:($x.agent.harness // null), herdr_state:$st, unavailable:($x.agent.unavailable // null), session_id:($x.agent.session_id // null),
          slot:$x.container, unit:$x.unit, workspace_id:$x.workspace_id, kind:($x.spawn.kind // null), last_task_ref:($w.task_ref // null), last_repo:($w.repo // null),
          # done with its assignment: idle after a handoff delivered in this boot (coord:reap ends it)
          reapable:(($st | idle) and $x.agent.unavailable == null
                    and any($work[]; .handoff and .host == $h and .agent_id == $x.agent.agent_id and .at >= ($x.spawn.at // ""))),
          hygiene:hygiene($st; $w; null; "unknown: transcript inside the worker container")}] as $ws
   | host_record({host:$h, machine:($hst.machine // null), reachable:($pr.reachable and ($hst.reachable // false))}; $c; $ws; [$sl[] | select(.reserved) | {host:$h, kind:.spawn.kind}];
       {slots:[$sl[] | {container, unit, unit_state, workspace_id, in_use:(.active or .reserved)}],
        free_slot:([$sl[] | select((.active or .reserved) | not) | {container, unit}] | first // null),
        reapable:[$ws[] | select(.reapable) | .slot]})]),
 failed_sources:([$inv.hosts[]? | select(.reachable == false) | {source:("herdr:inventory:" + .host), error}]
   + [$boxes[] | .key as $h | ($slots[$h] // null) | select(. != null and .reachable == false) | {source:("ssh:" + $h), error:{kind:"unreachable", message:.error}}]
   + (if $locks == null then [{source:"host:locks", error:{kind:"missing", message:"host:locks produced no output"}}] else [$locks.hosts[]? | select(.reachable == false) | {source:("host:locks:" + .host), error}] end) + (if $inv.machines_error != null then [{source:"herdr:machine-list", error:$inv.machines_error}] else [] end))}
| .partial = ((.failed_sources | length) > 0)
