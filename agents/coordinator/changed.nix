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
  # printing runs (min gap) and caps them per hour; a deferred run prints nothing and leaves the snapshot where it is, so
  # the changes stay pending and come out together once the budget allows.
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
  options.coordinator.openHandoffDays = lib.mkOption {
    type = lib.types.ints.positive;
    default = 7;
    description = "A delivered handoff older than this no longer counts as open for coord:changed.";
  };

  config.tasks."coord:changed" = {
    description = "Zero-LLM change check for a timer, with a wake budget (min gap, per-hour cap; deferred runs print nothing and keep the snapshot): diffs herdr agent state (state_change_seq), gh:repos counts (upstream in the same DAG) and the audit log's open handoffs against the last snapshot; prints nothing and exits 0 when nothing is actionable, else one compact line per actionable change. peek=true reports without moving the snapshot.";
    after = [ "herdr:inventory@completed" "gh:repos@completed" ];
    input = { peek = false; };
    exec = ''
      ${cfg.prelude}
      ctx='{"task":"coord:changed"}'
      peek=$(input .peek); case "$peek" in true|false|"") ;; *) fail 3 invalid_input "peek must be true or false" "$ctx" ;; esac; [ "$peek" = true ] || peek=false
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
                  | {key:.handoff_id, value:{host:.host, agent_id:.agent_id, task_ref:(.task_ref // null), sent_at:(.at // null)}})
            | from_entries' "$audit" > "$tmpd/open.json" 2>/dev/null; then audit_state=ok; else printf '{}\n' > "$tmpd/open.json"; audit_state=unreadable; fi
      fi

      # the previous snapshot: absent means baseline; unreadable means the baseline is rebuilt and the owner is told
      baseline=false; reset=false; printf '{}\n' > "$tmpd/prev.json"
      if [ -e "$snap" ]; then
        if ! jq -c 'select(type == "object" and .schema_version == 1)' "$snap" > "$tmpd/prev.json" 2>/dev/null || [ ! -s "$tmpd/prev.json" ]; then
          printf '{}\n' > "$tmpd/prev.json"; baseline=true; reset=true
        fi
      else baseline=true; fi

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
           audit_ok:($as != "unreadable")}' > "$tmpd/cur.json" || fail 2 malformed "herdr:inventory record has an unexpected shape" "$ctx"

      jq -c --argjson baseline "$baseline" --argjson reset "$reset" --arg snap "$snap" --arg audit "$audit" --slurpfile P "$tmpd/prev.json" '
        $P[0] as $p | . as $c
        | def safe: tostring | gsub("[^A-Za-z0-9_:.@/#-]"; "?") | .[0:80];
          def ref(a): ((a.task_ref // "-") | safe);
          def n(x): (x | safe);
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
          (if ($c.audit_ok | not) and ($p.audit_ok != false) then {kind:"audit", line:("audit " + $audit + " unreadable (not JSON lines); herdr:message refuses to send until the owner inspects it")} else empty end)
        ]' "$tmpd/cur.json" > "$tmpd/changes.json" || fail 2 malformed "snapshot diff failed" "$ctx"

      # a reported handoff is closed from now on
      jq -c --arg at "$at" --slurpfile C "$tmpd/changes.json" '
        .closed_handoffs += ([$C[0][] | select(.kind == "settled" or .kind == "gone" or .kind == "replaced") | {key:.handoff_id, value:{kind, at:$at}}] | from_entries)' "$tmpd/cur.json" > "$tmpd/next.json" || fail 2 malformed "snapshot update failed" "$ctx"
      jq -cn --arg at "$at" --argjson b "$baseline" --argjson r "$reset" --argjson pk "$peek" --arg rs "$repos_src" --arg as "$audit_state" --arg s "$snap" \
         --slurpfile C "$tmpd/changes.json" --slurpfile I "$tmpd/inv.json" --slurpfile N "$tmpd/next.json" '
        {schema_version:1, task:"coord:changed", observed_at:$at, baseline:$b, snapshot_reset:$r, peek:$pk, snapshot:$s,
         sources:{herdr:{answered_hosts:($I[0].answered_hosts // 0), hosts_total:($I[0].hosts_total // 0)}, repos:$rs, audit:$as},
         open_handoffs:(($N[0].open_handoffs | length) - ($N[0].closed_handoffs | length)), changes:$C[0]}' > "$tmpd/rec.json" || fail 2 malformed "record build failed" "$ctx"
      # the wake budget (wakes.json: epoch seconds of past printing runs, pruned to the window): a printing run within the
      # min gap of the last one, or beyond the hourly cap, is deferred: nothing printed, snapshot untouched, so its changes
      # stay pending and surface together on the first allowed run. peek never spends or checks the budget.
      wakes="$dir/wakes.json"; now=$(now_epoch); gap=${toString cfg.wakeMinGapSeconds}; cap=${toString cfg.wakeMaxPerHour}
      window=$(( gap > 3600 ? gap : 3600 ))
      recent=$(jq -c --argjson now "$now" --argjson w "$window" '[.[]? | numbers | select(. > $now - $w)]' "$wakes" 2>/dev/null) || recent='[]'
      nchanges=$(jq 'length' "$tmpd/changes.json"); deferred=false; reason=null; next_at=null
      if [ "$peek" = false ] && [ "$nchanges" -gt 0 ]; then
        last=$(jq -r 'max // 0' <<<"$recent"); hour=$(jq -r --argjson now "$now" '[.[] | select(. > $now - 3600)] | length' <<<"$recent")
        if [ "$gap" -gt 0 ] && [ $((now - last)) -lt "$gap" ]; then deferred=true; reason='"min_gap"'; next_at=$((last + gap))
        elif [ "$hour" -ge "$cap" ]; then deferred=true; reason='"per_hour_cap"'; next_at=$(( $(jq -r --argjson now "$now" '[.[] | select(. > $now - 3600)] | min' <<<"$recent") + 3600 )); fi
      fi
      wake=$(jq -cn --argjson d "$deferred" --argjson r "$reason" --argjson n "$next_at" --argjson h "$(jq -r --argjson now "$now" '[.[] | select(. > $now - 3600)] | length' <<<"$recent")" --argjson g "$gap" --argjson c "$cap" \
        '{deferred:$d, reason:$r, next_allowed_at:(if $n == null then null else ($n | todate) end), wakes_last_hour:$h, min_gap_seconds:$g, max_per_hour:$c}')
      jq -c --argjson w "$wake" '. + {wake:$w}' "$tmpd/rec.json" > "$tmpd/rec2.json" && mv "$tmpd/rec2.json" "$tmpd/rec.json" || fail 2 malformed "record build failed" "$ctx"
      # record and lines first, the snapshot last: a failure here repeats a change on the next run rather than losing it
      if [ "$peek" = false ]; then cp "$tmpd/rec.json" "$tmpd/latest.json" && mv "$tmpd/latest.json" "$dir/latest.json" || fail 2 state_unwritable "cannot write $dir/latest.json" "$ctx"; fi
      cat "$tmpd/rec.json" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
      if [ "$deferred" = true ]; then exit 0; fi
      # stdout is the contract for the timer: empty when nothing is actionable, one line per change otherwise
      jq -r '.changes[].line' "$tmpd/rec.json"
      if [ "$peek" = false ] && [ "$nchanges" -gt 0 ]; then
        jq -cn --argjson r "$recent" --argjson now "$now" '$r + [$now]' > "$tmpd/wakes.json" && mv "$tmpd/wakes.json" "$wakes" || fail 2 state_unwritable "cannot write $wakes" "$ctx"
      fi
      if [ "$peek" = false ]; then mv "$tmpd/next.json" "$snap" || fail 2 state_unwritable "cannot write $snap" "$ctx"; fi
    '';
  };
}
