# coord:capacity: the developer environments per environment host. An environment is an agent with a name in the host's
# Herdr (named after its sam.workers.instances.<name>); unnamed agents there are the owner's own panes and are not listed.
# Inputs: $inv (herdr:inventory, slurped), $hosts (the environment host labels, matched case-insensitively), $audit
# (audit.jsonl lines, slurped; [] when none), $next ({repo, task_ref} or null), $at, $now (epoch seconds).
# A handoff is in flight while its send has no outcome yet (younger than the send bound) or after delivery while the
# environment is working or blocked; an environment idle after a delivered handoff awaits its follow-up (work:status).
# $ctx: {"<host>/<name>": context tokens} of the idle environments read; $ctxerr: [{source, error}] of the reads that failed;
# $threshold: the context size at which an idle environment's advice is /compact.
$inv[0] as $inv | $audit[0] as $audit | $ctx[0] as $ctx | $ctxerr[0] as $ctxerr
| ($audit | INDEX(.[] | select(.phase == "outcome"); .audit_id)) as $out
| [$audit[] | select(.phase == "attempt" and (.agent_id | type) == "string")
   | ($out[.audit_id | tostring].outcome // null) as $o
   | select($o == "delivered" or ($o == null and (((.at // "") | try fromdateiso8601 catch 0) >= $now - 120)))
   | {host:(.host // "" | ascii_downcase), agent_id, session_id:(.session_id // null), audit_id, handoff_id:(.handoff_id // null), task_ref:(.task_ref // null),
      repo:((.authorized_by.issue_url // "") | [capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/").r] | first), at, sending:($o == null)}] as $work
| def busy: . == "working" or . == "blocked";
  def idle: . == "idle" or . == "done";
{schema_version:1, task:"coord:capacity", observed_at:$at, next:$next,
 hosts:[$hosts[] as $h
   | ([$inv.hosts[]? | select((.host | ascii_downcase) == ($h | ascii_downcase))] | first // null) as $hst
   | ($hst.reachable == true) as $up
   | [($hst.agents // [])[] | select((.name | type) == "string") | . as $a | ($a.observed_state // "unknown") as $s
       | ([$work[] | select(.host == ($h | ascii_downcase) and (.agent_id == $a.agent_id or (.session_id != null and .session_id == $a.session_id)))] | sort_by(.at) | last) as $w
       | {name:$a.name, agent_id:$a.agent_id, harness:$a.harness, herdr_state:$s, unavailable:$a.unavailable, session_id:$a.session_id,
          last_handoff:(if $w == null then null else $w | {audit_id, handoff_id, task_ref, repo, at} end),
          handoff_in_flight:($w != null and ($w.sending or ($s | busy))),
          available:(($s | idle) and $a.unavailable == null and ($w.sending // false | not)),
          hygiene:(($ctx["\($h)/\($a.name)"] // null) as $tok
                   | ($tok != null and $tok >= $threshold) as $full
                   | (($next != null and $w != null and ($next.repo != $w.repo or $next.task_ref != $w.task_ref))) as $indep
                   | {context_tokens:$tok} + (
                     if ($s | idle | not) then {advice:null, reasons:[]}
                     elif $indep then {advice:"/clear", reasons:["next assignment \($next.repo // "?")\($next.task_ref // "") is independent of its last (\($w.repo // "?")\($w.task_ref // ""))"] + (if $full then ["context \($tok) tokens >= \($threshold)"] else [] end)}
                     elif $full then {advice:"/compact", reasons:["context \($tok) tokens >= \($threshold)"]}
                     else {advice:null, reasons:[]} end))}] as $envs
   | ([$envs[] | select(.available)] | length) as $idle
   | ([$envs[] | select(.unavailable == null and (.herdr_state | busy))] | length) as $busy
   | ([$envs[] | select(.unavailable != null)] | length) as $unavail
   | {host:$h, machine:($hst.machine // null), reachable:$up,
      environments:{total:($envs | length), idle:$idle, busy:$busy, unavailable:$unavail, unknown:(($envs | length) - $idle - $busy - $unavail), list:$envs},
      reasons:[if $hst == null then "not a saved Herdr machine (herdr machine list)" elif $up | not then "host did not answer" else empty end,
               if $up and ($envs | length) == 0 then "no environment declared (sam.workers.instances in its nixos-config)" else empty end,
               if $up and ($envs | length) > 0 and $idle == 0 then "no idle environment" else empty end,
               if $unavail > 0 then "\($unavail) environment(s) unavailable (usage limit): " + ([$envs[] | select(.unavailable != null) | .name] | join(", ")) else empty end]}],
 failed_sources:([$inv.hosts[]? | select(.reachable == false and ((.host | ascii_downcase) as $n | $hosts | map(ascii_downcase) | index($n)))
                   | {source:("herdr:inventory:" + .host), error}]
   + $ctxerr
   + (if $inv.machines_error != null then [{source:"herdr:machine-list", error:$inv.machines_error}] else [] end))}
| .available = [.hosts[] | .host as $h | .environments.list[] | select(.available) | {host:$h, name, agent_id}]
| .partial = ((.failed_sources | length) > 0)
