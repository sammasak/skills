# herdr:* tasks: live pane state over the installed herdr CLI. One herdr:list:<host>
# per fleet host; herdr:inventory aggregates them with @completed so one dead host
# never hides the others. Observations always exit 0 and carry `error` as data
# (devenv drops the output of a failed task); only coord:brief decides the exit.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  hostNames = map (h: h.name) cfg.hosts;
  t = toString cfg.timeoutSeconds;
  listTask = h: lib.nameValuePair "herdr:list:${h.name}" {
    description = "herdr agent list on ${h.name} (bounded, raw).";
    exec = ''
      ${cfg.prelude}
      host=${h.name}; ${cfg.hostCase}
      ctx='{"task":"herdr:list","host":"${h.name}"}'
      at=$(now_iso); rc=0
      raw=$(herdr_on ${t} "$target" agent list 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error "$(rc_kind $rc)" "herdr agent list: $(rc_kind $rc) (exit $rc)" "$ctx"; exit 0; }
      agents=$(jq -c '.result.agents | select(type == "array") | map(select(type == "object" and (.pane_id | type) == "string"))' <<<"$raw" 2>/dev/null) && [ -n "$agents" ] \
        || { observe_error malformed "herdr agent list did not return an agent_list" "$ctx"; exit 0; }
      emit "$(jq -cn --arg h "${h.name}" --arg at "$at" --argjson a "$agents" '{schema_version:1, task:"herdr:list", host:$h, observed_at:$at, agents:$a, error:null}')"
    '';
  };
in
{
  imports = [ ./fleet.nix ];

  tasks = lib.listToAttrs (map listTask cfg.hosts) // {
    "herdr:inventory" = {
      description = "Every agent on every fleet host as record schema v1; partial on host failures, never fails itself.";
      after = map (n: "herdr:list:${n}@completed") hostNames;
      exec = ''
        ${cfg.prelude}
        snap_dir="${cfg.stateDir}/herdr"; mkdir -p "$snap_dir"
        at=$(now_iso); now=$(now_epoch); hosts_out="[]"; answered=0
        for name in ${lib.concatStringsSep " " hostNames}; do
          snap="$snap_dir/$name.json"; prev="{}"; [ -r "$snap" ] && prev=$(jq -c '.by_id // {}' "$snap" 2>/dev/null || echo "{}")
          up=$(upstream "herdr:list:$name"); err=null; records=""
          if [ "$up" != null ] && [ "$(jq -r '.error' <<<"$up")" = null ]; then
            # since/state_age_s key on pane_id + harness session; a renumbered pane or a new session starts at 0
            records=$(jq -c --arg host "$name" --arg at "$at" --argjson now "$now" --argjson prev "$prev" '
              .agents | map(
                (.pane_id + "|" + (.agent_session.value? // "")) as $k
                | ($prev[$k] // null) as $p
                | (if $p != null and $p.state_change_seq == .state_change_seq then $p.since else $now end) as $since
                | {host:$host, server:$host, agent_id:.pane_id, harness:(.agent // "unknown"), session_id:(.agent_session.value? // null),
                   cwd:(.cwd // null), title:(.terminal_title_stripped // .terminal_title // ""), observed_state:(.agent_status // "unknown"),
                   observed_at:$at, state_age_s:($now - $since), state_change_seq:(.state_change_seq // null), since:$since, stale:false,
                   task_ref:((.terminal_title_stripped // "") | capture("(?<r>#[0-9]+)")?.r // null), evidence_ref:null,
                   approval_required:(.agent_status == "blocked"), error:null})' <<<"$up" 2>/dev/null) \
              || { err='{"kind":"malformed","message":"agent records could not be normalised"}'; records=""; }
          elif [ "$up" != null ]; then err=$(jq -c '.error' <<<"$up")
          else err='{"kind":"missing","message":"herdr:list task produced no output"}'; fi
          if [ -n "$records" ]; then
            answered=$((answered+1))
            jq -cn --arg at "$at" --argjson r "$records" '{observed_at:$at, by_id:($r | map({key:(.agent_id + "|" + (.session_id // "")), value:{state_change_seq, since, record:.}}) | from_entries)}' > "$snap.tmp" && mv "$snap.tmp" "$snap"
            hosts_out=$(jq -c --arg h "$name" --argjson r "$records" '. + [{host:$h, reachable:true, error:null, agents:$r}]' <<<"$hosts_out")
          else
            records="[]"
            if [ -r "$snap" ]; then
              records=$(jq -c --argjson now "$now" --argjson max ${toString cfg.maxAgeSeconds} '
                (.observed_at | fromdateiso8601) as $age0 | ($now - $age0) as $age
                | if $age > $max then {dropped:true, records:[]} else {dropped:false, records:[.by_id[].record | .stale = true | .snapshot_at = (.observed_at) | .snapshot_age_s = $age]} end' "$snap" 2>/dev/null || echo '{"dropped":false,"records":[]}')
              [ "$(jq -r .dropped <<<"$records")" = false ] || err=$(jq -c '.message += "; last snapshot older than ${toString cfg.maxAgeSeconds}s, discarded"' <<<"$err")
              records=$(jq -c .records <<<"$records")
            fi
            hosts_out=$(jq -c --arg h "$name" --argjson e "$err" --argjson r "$records" '. + [{host:$h, reachable:false, error:$e, agents:$r}]' <<<"$hosts_out")
          fi
        done
        emit "$(jq -cn --arg at "$at" --argjson hosts "$hosts_out" --argjson n "$answered" --argjson total ${toString (lib.length hostNames)} \
          '{schema_version:1, task:"herdr:inventory", observed_at:$at, partial:($n < $total), answered_hosts:$n, hosts:$hosts}')"
      '';
    };

    "herdr:inspect" = {
      description = "Bounded terminal excerpt of one agent (<= 200 lines, <= 64 KiB) on a fleet host.";
      input = { host = null; agent_id = null; lines = 40; source = "visible"; };
      exec = ''
        ${cfg.prelude}
        host=$(input .host); agent=$(input .agent_id); lines=$(input .lines); source=$(input .source)
        [ -n "$host" ] && [ -n "$agent" ] || fail 3 invalid_input "host and agent_id are required"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters"
        [[ "$lines" =~ ^[0-9]+$ ]] || fail 3 invalid_input "lines must be an integer"
        case "$source" in visible|recent|recent-unwrapped) ;; *) fail 3 invalid_input "source must be visible, recent or recent-unwrapped" ;; esac
        ${cfg.hostCase}
        requested=$lines; [ "$lines" -gt 200 ] && lines=200; [ "$lines" -gt 0 ] || lines=1
        ctx=$(jq -cn --arg h "$host" --arg a "$agent" '{task:"herdr:inspect",host:$h,agent_id:$a}')
        at=$(now_iso); rc=0
        text=$(herdr_on ${t} "$target" agent read -- "$agent" --lines "$lines" --source "$source" --format text 2>/dev/null) || rc=$?
        [ "$rc" -eq 0 ] || fail 2 "$(rc_kind $rc)" "herdr agent read: $(rc_kind $rc) (exit $rc; unknown agent?)" "$ctx"
        full_lines=$(printf '%s\n' "$text" | wc -l); full_bytes=''${#text}
        text=$(printf '%s\n' "$text" | head -n 200 | head -c 65536)
        emit "$(jq -cn --arg h "$host" --arg a "$agent" --arg at "$at" --arg t "$text" --arg src "$source" --argjson req "$requested" --argjson fl "$full_lines" --argjson fb "$full_bytes" \
          '{schema_version:1, task:"herdr:inspect", host:$h, agent_id:$a, observed_at:$at, source:$src, lines_requested:$req,
            lines_returned:($t | split("\n") | length), truncated:($req > 200 or $fl > 200 or $fb > 65536), excerpt:$t, error:null}')"
      '';
    };
    "herdr:message" = {
      description = "ACT: send a confirmed coord:handoff draft to its agent; audit log, duplicate detection, never to a blocked agent.";
      input = { handoff_id = null; confirm = null; resend = null; };
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        id=$(input .handoff_id); confirm=$(input .confirm); resend=$(input .resend)
        ctx() { jq -cn --arg i "$id" '{task:"herdr:message",handoff_id:$i}'; }
        [[ "$id" =~ ^[a-f0-9]{12}$ ]] || fail 3 invalid_input "handoff_id must be a 12-hex coord:handoff id" "$(ctx)"
        draft="${cfg.stateDir}/handoffs/$id.json"
        [ -r "$draft" ] || fail 3 invalid_input "no draft with handoff_id $id (run coord:handoff first)" "$(ctx)"
        host=$(jq -r .host "$draft"); agent=$(jq -r .agent_id "$draft"); text=$(jq -r .text "$draft")
        [ "$confirm" = "$host/$agent" ] || fail 3 not_confirmed "confirm must equal the draft target '$host/$agent' (got '$confirm')" "$(ctx)"
        valid_id "$agent" || fail 3 invalid_input "draft agent_id has unsafe characters" "$(ctx)"
        target=""
        case "$host" in
          ${lib.concatMapStringsSep "\n          " (h: ''${h.name}) target="${sshTarget h}" ;;'') cfg.hosts}
          *) fail 3 invalid_input "draft host not in fleet: $host" "$(ctx)" ;;
        esac
        audit="${cfg.stateDir}/audit.jsonl"; mkdir -p "${cfg.stateDir}"; touch "$audit"
        prior=$(jq -c --arg i "$id" 'select(.handoff_id == $i and .phase == "attempt")' "$audit" | tail -1)
        if [ -n "$prior" ]; then
          pid=$(jq -r .audit_id <<<"$prior")
          [ "$resend" = "$pid" ] || fail 3 duplicate "handoff $id was already sent (audit $pid, outcome $(jq -r --arg a "$pid" 'select(.audit_id == $a and .phase == "outcome") | .outcome' "$audit" | tail -1)); pass resend=\"$pid\" to send again" "$(ctx)"
        fi
        run_h() { # argv after the herdr binary
          if [ -z "$target" ]; then timeout -k 1 "$1" ${cfg.herdrCommand} "''${@:2}"
          else timeout -k 1 "$1" ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=${toString cfg.timeoutSeconds} -o StrictHostKeyChecking=accept-new "$target" herdr "''${@:2}"; fi
        }
        rc=0; st=$(run_h ${toString cfg.timeoutSeconds} agent get "$agent" 2>/dev/null) || rc=$?
        [ "$rc" -eq 0 ] || fail 2 agent_missing "herdr agent get $agent failed on $host (exit $rc)" "$(ctx)"
        state=$(jq -r '.result.agent.agent_status // "unknown"' <<<"$st")
        [ "$state" != blocked ] || fail 2 agent_blocked "agent $host/$agent is blocked (needs a human at its prompt); not sending" "$(ctx)"
        aid=$(printf '%s|%s' "$id" "$(now_iso)" | sha256sum | cut -c1-12); at=$(now_iso)
        jq -cn --arg a "$aid" --arg i "$id" --arg h "$host" --arg ag "$agent" --arg at "$at" --arg c "$confirm" --arg s "$state" \
          '{audit_id:$a, handoff_id:$i, phase:"attempt", host:$h, agent_id:$ag, at:$at, confirm:$c, state_before:$s}' >> "$audit"
        rc=0; resp=$(run_h ${toString cfg.messageTimeoutSeconds} agent prompt "$agent" "$text" 2>"${cfg.stateDir}/last-prompt.err") || rc=$?
        case "$rc" in
          0) outcome=delivered ;;
          124) outcome=unknown_delivery ;;
          *) outcome=$(jq -r '.error.code // "command_failed"' "${cfg.stateDir}/last-prompt.err" 2>/dev/null || echo command_failed) ;;
        esac
        jq -cn --arg a "$aid" --arg i "$id" --arg at "$(now_iso)" --arg o "$outcome" --argjson rc "$rc" '{audit_id:$a, handoff_id:$i, phase:"outcome", at:$at, outcome:$o, exit:$rc}' >> "$audit"
        rec=$(jq -cn --arg a "$aid" --arg i "$id" --arg h "$host" --arg ag "$agent" --arg at "$at" --arg o "$outcome" --arg s "$state" \
          '{schema_version:1, task:"herdr:message", audit_id:$a, handoff_id:$i, host:$h, agent_id:$ag, sent_at:$at, state_before:$s, outcome:$o,
            receipt:($o == "delivered"), worker_done:false, accepted:false,
            error:(if $o == "delivered" then null elif $o == "unknown_delivery" then {kind:"timeout", message:"prompt timed out; delivery unknown, do not resend blindly (audit " + $a + ")"} else {kind:$o, message:"herdr agent prompt failed"} end)}')
        [ "$outcome" = delivered ] && jq -c '.sent = true' "$draft" > "$draft.tmp" && mv "$draft.tmp" "$draft"
        emit "$rec"
        [ "$outcome" = delivered ] || exit 2
      '';
    };

    "herdr:await" = {
      description = "Bounded wait for an agent to reach idle/done/blocked; reports herdr_state only, never acceptance.";
      input = { host = null; agent_id = null; timeout_s = 120; };
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        host=$(input .host); agent=$(input .agent_id); t=$(input .timeout_s)
        ctx() { jq -cn --arg h "$host" --arg a "$agent" '{task:"herdr:await",host:$h,agent_id:$a}'; }
        [ -n "$host" ] && [ -n "$agent" ] || fail 3 invalid_input "host and agent_id are required" "$(ctx)"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters" "$(ctx)"
        [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le 1800 ] || fail 3 invalid_input "timeout_s must be 1..1800" "$(ctx)"
        target=""
        case "$host" in
          ${lib.concatMapStringsSep "\n          " (h: ''${h.name}) target="${sshTarget h}" ;;'') cfg.hosts}
          *) fail 3 invalid_input "host not in fleet: $host" "$(ctx)" ;;
        esac
        ms=$((t * 1000)); at=$(now_iso); rc=0
        if [ -z "$target" ]; then
          res=$(timeout -k 1 $((t + 5)) ${cfg.herdrCommand} agent wait "$agent" --until idle --until done --until blocked --timeout "$ms" 2>/dev/null) || rc=$?
        else
          res=$(timeout -k 1 $((t + 5)) ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=${toString cfg.timeoutSeconds} -o StrictHostKeyChecking=accept-new "$target" herdr agent wait "$agent" --until idle --until done --until blocked --timeout "$ms" 2>/dev/null) || rc=$?
        fi
        case "$rc" in
          0) state=$(jq -r '.result.status // .result.agent_status // "unknown"' <<<"$res" 2>/dev/null || echo unknown)
             emit "$(jq -cn --arg h "$host" --arg a "$agent" --arg at "$at" --arg s "$state" --argjson t "$t" \
               '{schema_version:1, task:"herdr:await", host:$h, agent_id:$a, started_at:$at, timeout_s:$t, herdr_state:$s, reached:true,
                 worker_done:($s == "idle" or $s == "done"), needs_owner:($s == "blocked"), accepted:false,
                 note:"accepted is decided by work:status evidence, never by this task", error:null}')" ;;
          124|1) fail 2 timeout "agent $host/$agent did not reach idle/done/blocked within ''${t}s" "$(jq -cn --arg h "$host" --arg a "$agent" --argjson t "$t" '{task:"herdr:await",host:$h,agent_id:$a,timeout_s:$t,reached:false,accepted:false}')" ;;
          255) fail 2 unreachable "ssh could not connect" "$(ctx)" ;;
          *) fail 2 command_failed "herdr agent wait exited $rc" "$(ctx)" ;;
        esac
      '';
    };
  };
}
