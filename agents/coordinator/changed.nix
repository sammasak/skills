# coord:changed is the zero-LLM wake-up check (sammasak/skills#28, slice C2): a pure jq diff of what the read tasks
# already observe (herdr agent state with its state_change_seq, gh:repos counts, the audit log's open handoffs)
# against the previous snapshot. It prints nothing when nothing is actionable, so a timer can run it every minute
# and start a Coordinator session only when it prints; the snapshot moves on every run, so a change is reported once.
{ lib, config, ... }:
let
  cfg = config.coordinator;
in
{
  imports = [ ../../task-modules/common.nix ];

  tasks."coord:changed" = {
    description = "Zero-LLM change check for a timer: diffs herdr agent state (state_change_seq), gh:repos counts and the audit log's open handoffs against the last snapshot; prints nothing and exits 0 when nothing is actionable, else one compact line per actionable change.";
    after = [ "herdr:inventory@completed" ];
    input = { repos_file = null; };
    exec = ''
      ${cfg.prelude}
      ctx='{"task":"coord:changed"}'
      inv=$(upstream "herdr:inventory")
      [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" "$ctx"
      dir="${cfg.stateDir}/changed"; mkdir -p "$dir" || fail 2 state_unwritable "cannot create $dir" "$ctx"
      snap="$dir/snapshot.json"; at=$(now_iso)
      [ "$(jq -r '.answered_hosts // 0' <<<"$inv")" -gt 0 ] || fail 2 nothing_observed "no herdr host answered (not even this one); the snapshot is left as it was" "$ctx"

      # repos: the gh:repos record when it ran upstream (wired after sammasak/skills#38), else a file holding one, else absent;
      # a record carrying an error counts as absent for this run and the previous counts are carried forward in the snapshot
      repos=$(upstream "gh:repos"); repos_src=upstream
      if [ "$repos" = null ]; then
        rf=$(input .repos_file)
        if [ -z "$rf" ]; then repos_src=absent
        elif [[ "$rf" =~ ^/[A-Za-z0-9_./-]+$ ]] && [[ "/$rf/" != *"/../"* ]]; then
          repos=$(jq -c 'select(type == "object")' "$rf" 2>/dev/null) || repos=""; if [ -n "$repos" ]; then repos_src=file; else repos=null; repos_src=unreadable; fi
        else fail 3 invalid_input "repos_file must be a plain absolute path" "$ctx"; fi
      fi
      if [ "$repos" != null ] && ! jq -e '.error == null and (.repos | type) == "array"' <<<"$repos" >/dev/null 2>&1; then repos=null; repos_src=error; fi

      # open handoffs: the last attempt per handoff_id whose outcome line says delivered (the same reading coord:brief uses)
      audit="${cfg.stateDir}/audit.jsonl"; open='{}'; audit_state=absent
      if [ -s "$audit" ]; then
        if open=$(jq -sc '
            map(select(type == "object")) as $all | ($all | map(select(.phase == "outcome"))) as $outs
            | [$all[] | select(.phase == "attempt" and (.handoff_id | type) == "string" and (.host | type) == "string" and (.agent_id | type) == "string")]
            | group_by(.handoff_id) | map(last)
            | map(. as $a | ($outs | map(select(.audit_id == $a.audit_id)) | last) as $o | select(($o.outcome // "") == "delivered")
                  | {key:.handoff_id, value:{host:.host, agent_id:.agent_id, task_ref:(.task_ref // null), sent_at:(.at // null)}})
            | from_entries' "$audit" 2>/dev/null); then audit_state=ok; else open='{}'; audit_state=unreadable; fi
      fi

      # the previous snapshot: absent means baseline; unreadable means the baseline is rebuilt and the owner is told
      prev='{}'; baseline=false; reset=false
      if [ -e "$snap" ]; then
        prev=$(jq -c 'select(type == "object" and .schema_version == 1)' "$snap" 2>/dev/null | head -n 1) || prev=""
        [ -n "$prev" ] || { prev='{}'; baseline=true; reset=true; }
      else baseline=true; fi

      cur=$(jq -cn --arg at "$at" --argjson inv "$inv" --argjson repos "$repos" --argjson open "$open" --arg as "$audit_state" --argjson p "$prev" '
        {schema_version:1, observed_at:$at,
         hosts:($inv.hosts | map({key:.host, value:{reachable:.reachable, error_kind:(.error.kind // null),
                 agents:(.agents | map({key:.agent_id, value:{state:.observed_state, seq:.state_change_seq, session_id, harness, task_ref, title}}) | from_entries)}}) | from_entries),
         repos:(if $repos == null then ($p.repos // null) else ($repos.repos | map({key:.repo, value:{open_prs:(.open_prs // 0), approved_issues:(.approved_issues // 0), active:(.active // false)}}) | from_entries) end),
         open_handoffs:$open, audit_ok:($as != "unreadable")}') || fail 2 malformed "herdr:inventory record has an unexpected shape" "$ctx"

      changes=$(jq -cn --argjson p "$prev" --argjson c "$cur" --argjson baseline "$baseline" --argjson reset "$reset" --arg snap "$snap" --arg audit "$audit" '
        def ref(a): (a.task_ref // "-");
        def n(x): (x | tostring);
        ($c.open_handoffs | to_entries | sort_by(.value.sent_at // "") | map({key:(.value.host + "/" + .value.agent_id), value:(.value + {handoff_id:.key})}) | from_entries) as $byagent
        # one agent against its previous record; quiet suppresses "new" (baseline, or a host that just came back)
        | def agent_lines($h; $a; $ac; $ap; $quiet):
            ($byagent[$h + "/" + $a] // null) as $ho
            | if $ac.state == "blocked" and ($ap == null or $ap.state != "blocked") then
                {kind:"blocked", host:$h, agent_id:$a, handoff_id:($ho.handoff_id // null), line:("blocked " + $h + "/" + $a + " " + ref(if $ho != null then $ho else $ac end) + " " + ($ac.harness // "?") + " seq " + n($ac.seq) + (if $ho then " handoff " + $ho.handoff_id else "" end) + " needs the owner")}
              elif $ap == null then
                (if $quiet then empty else {kind:"new", host:$h, agent_id:$a, handoff_id:null, line:("new " + $h + "/" + $a + " " + ref($ac) + " " + ($ac.harness // "?") + " " + ($ac.state // "unknown") + " seq " + n($ac.seq))} end)
              elif $ho != null and $ap.session_id != $ac.session_id then
                {kind:"replaced", host:$h, agent_id:$a, handoff_id:$ho.handoff_id, line:("replaced " + $h + "/" + $a + " " + ref($ho) + " handoff " + $ho.handoff_id + " is now a different session (" + n($ap.session_id) + " → " + n($ac.session_id) + ")")}
              elif $ho != null and $ap.seq != $ac.seq and (["idle","done"] | index($ac.state)) != null then
                {kind:"settled", host:$h, agent_id:$a, handoff_id:$ho.handoff_id, line:("settled " + $h + "/" + $a + " " + ref($ho) + " handoff " + $ho.handoff_id + " " + $ac.state + " seq " + n($ap.seq) + "→" + n($ac.seq))}
              else empty end;
        [
          (if $reset then {kind:"snapshot", line:("snapshot " + $snap + " was unreadable; baseline rebuilt")} else empty end),
          ($c.hosts | to_entries[] | .key as $h | .value as $hc | ($p.hosts[$h] // null) as $hp
            | if $hc.reachable == false then
                (if $hp != null and $hp.reachable == true then {kind:"host", host:$h, line:("host " + $h + " unreachable (" + ($hc.error_kind // "error") + ")")} else empty end)
              else
                (if ($baseline | not) and ($hp == null or $hp.reachable == false) then
                   {kind:"host", host:$h, line:("host " + $h + (if $hp == null then " now listed (" else " reachable again (" end) + n($hc.agents | length) + " agents)")}
                 else empty end),
                ($hc.agents | to_entries[] | .key as $a | agent_lines($h; $a; .value; ($hp.agents[$a] // null); ($baseline or $hp == null or $hp.reachable == false))),
                ((if $hp != null and $hp.reachable == true then $hp.agents else {} end) | to_entries[] | .key as $a
                  | select(($hc.agents[$a] // null) == null) | ($byagent[$h + "/" + $a] // null) as $ho | select($ho != null)
                  | {kind:"gone", host:$h, agent_id:$a, handoff_id:$ho.handoff_id, line:("gone " + $h + "/" + $a + " " + ref($ho) + " handoff " + $ho.handoff_id + " no longer listed")})
              end),
          (if $c.repos != null and ($p.repos // null) != null then
             ($c.repos | to_entries[] | .key as $r | .value as $rc | ($p.repos[$r] // null) as $rp
               | if $rp == null then (if $rc.active then {kind:"repo", repo:$r, line:("repo " + $r + " active: open_prs " + n($rc.open_prs) + " approved_issues " + n($rc.approved_issues))} else empty end)
                 elif $rp.open_prs != $rc.open_prs or $rp.approved_issues != $rc.approved_issues then
                   {kind:"repo", repo:$r, line:("repo " + $r + " open_prs " + n($rp.open_prs) + "→" + n($rc.open_prs) + " approved_issues " + n($rp.approved_issues) + "→" + n($rc.approved_issues))}
                 else empty end)
           else empty end),
          (if ($c.audit_ok | not) and ($p.audit_ok != false) then {kind:"audit", line:("audit " + $audit + " unreadable (not JSON lines); herdr:message refuses to send until the owner inspects it")} else empty end)
        ]') || fail 2 malformed "snapshot diff failed" "$ctx"

      printf '%s\n' "$cur" > "$snap.tmp" && mv "$snap.tmp" "$snap" || fail 2 state_unwritable "cannot write $snap" "$ctx"
      rec=$(jq -cn --arg at "$at" --argjson b "$baseline" --argjson r "$reset" --argjson ch "$changes" --argjson inv "$inv" --arg rs "$repos_src" --arg as "$audit_state" --arg s "$snap" --argjson open "$open" '
        {schema_version:1, task:"coord:changed", observed_at:$at, baseline:$b, snapshot_reset:$r, snapshot:$s,
         sources:{herdr:{answered_hosts:($inv.answered_hosts // 0), hosts_total:($inv.hosts_total // 0)}, repos:$rs, audit:$as},
         open_handoffs:($open | length), changes:$ch}')
      printf '%s\n' "$rec" > "$dir/latest.json.tmp" && mv "$dir/latest.json.tmp" "$dir/latest.json"
      printf '%s\n' "$rec" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
      # stdout is the contract for the timer: empty when nothing is actionable, one line per change otherwise
      jq -r '.changes[].line' <<<"$rec"
    '';
  };
}
