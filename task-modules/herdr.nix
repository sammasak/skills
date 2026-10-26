# herdr:* tasks: live pane state over the installed herdr CLI. One herdr:list:<host>
# per fleet host; herdr:inventory aggregates them with @completed so one dead host
# never hides the others. A list task exits 0 whenever it made its observation --
# a dead host is data in its output (devenv drops the output of a failed task).
{ lib, config, ... }:

let
  cfg = config.coordinator;
  hostNames = map (h: h.name) cfg.hosts;
  sshTarget = h: if h.ssh == null then "" else h.ssh;
  listTask = h: lib.nameValuePair "herdr:list:${h.name}" {
    description = "herdr agent list on ${h.name} (bounded, raw).";
    exec = ''
      set -uo pipefail
      . ${cfg.lib}
      at=$(now_iso); rc=0
      # devenv runs execs with errexit: capture the status on the same line
      if [ -z "${sshTarget h}" ]; then
        raw=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.herdrCommand} agent list 2>/dev/null) || rc=$?
      else
        raw=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=${toString cfg.timeoutSeconds} -o StrictHostKeyChecking=accept-new ${sshTarget h} herdr agent list 2>/dev/null) || rc=$?
      fi
      case "$rc" in
        0) if agents=$(jq -c '.result.agents' <<<"$raw" 2>/dev/null) && [ "$agents" != null ]; then
             emit "$(jq -cn --arg h "${h.name}" --arg at "$at" --argjson a "$agents" '{schema_version:1, task:"herdr:list", host:$h, observed_at:$at, agents:$a, error:null}')"
           else observe_error malformed "herdr agent list did not return an agent_list" '{"task":"herdr:list","host":"${h.name}"}'; fi ;;
        124) observe_error timeout "no answer within ${toString cfg.timeoutSeconds}s" '{"task":"herdr:list","host":"${h.name}"}' ;;
        255) observe_error unreachable "ssh could not connect" '{"task":"herdr:list","host":"${h.name}"}' ;;
        *) observe_error command_failed "herdr agent list exited $rc" '{"task":"herdr:list","host":"${h.name}"}' ;;
      esac
    '';
  };
in
{
  imports = [ ./fleet.nix ];

  tasks = lib.listToAttrs (map listTask cfg.hosts) // {
    "herdr:inventory" = {
      description = "Every agent on every fleet host as record schema v1 (partial on host failures).";
      after = map (n: "herdr:list:${n}@completed") hostNames;
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        snap_dir="${cfg.stateDir}/herdr"; mkdir -p "$snap_dir"
        at=$(now_iso); now=$(now_epoch); hosts_out="[]"; answered=0
        for name in ${lib.concatStringsSep " " hostNames}; do
          snap="$snap_dir/$name.json"; prev="{}"; [ -r "$snap" ] && prev=$(jq -c '.by_id // {}' "$snap" 2>/dev/null || echo "{}")
          up=$(upstream "herdr:list:$name")
          if [ "$up" != null ] && [ "$(jq -r '.error' <<<"$up")" = null ]; then
            answered=$((answered+1))
            records=$(jq -c --arg host "$name" --arg at "$at" --argjson now "$now" --argjson prev "$prev" '
              .agents | map(($prev[.pane_id] // null) as $p
                | (if $p != null and $p.state_change_seq == .state_change_seq then $p.since else $now end) as $since
                | {host:$host, server:$host, agent_id:.pane_id, harness:.agent, session_id:(.agent_session.value // null),
                   cwd:.cwd, title:(.terminal_title_stripped // .terminal_title // ""), observed_state:.agent_status,
                   observed_at:$at, state_age_s:($now - $since), state_change_seq:.state_change_seq, since:$since, stale:false,
                   task_ref:((.terminal_title_stripped // "") | capture("(?<r>#[0-9]+)")?.r // null), evidence_ref:null,
                   approval_required:(.agent_status == "blocked"), error:null})' <<<"$up")
            jq -cn --arg at "$at" --argjson r "$records" '{observed_at:$at, by_id:($r | map({key:.agent_id, value:{state_change_seq, since, record:.}}) | from_entries)}' > "$snap"
            hosts_out=$(jq -c --arg h "$name" --argjson r "$records" '. + [{host:$h, reachable:true, error:null, agents:$r}]' <<<"$hosts_out")
          else
            err=$(jq -c '.error // {kind:"missing", message:"herdr:list task produced no output"}' <<<"$up")
            records="[]"
            if [ -r "$snap" ]; then
              records=$(jq -c --argjson now "$now" --argjson max ${toString cfg.maxAgeSeconds} '
                (.observed_at | fromdateiso8601) as $t
                | if ($now - $t) > $max then [] else [.by_id[].record | .stale = true | .snapshot_at = (.observed_at) | .snapshot_age_s = ($now - $t)] end' "$snap" 2>/dev/null || echo "[]")
              [ "$records" != "[]" ] || err=$(jq -c '.message += "; last snapshot older than ${toString cfg.maxAgeSeconds}s, discarded"' <<<"$err")
            fi
            hosts_out=$(jq -c --arg h "$name" --argjson e "$err" --argjson r "$records" '. + [{host:$h, reachable:false, error:$e, agents:$r}]' <<<"$hosts_out")
          fi
        done
        emit "$(jq -cn --arg at "$at" --argjson hosts "$hosts_out" --argjson n "$answered" --argjson total ${toString (lib.length hostNames)} \
          '{schema_version:1, task:"herdr:inventory", observed_at:$at, partial:($n < $total), hosts:$hosts}')"
        [ "$answered" -gt 0 ] || exit 2
      '';
    };
    "herdr:inspect" = {
      description = "Bounded terminal excerpt of one agent (<= 200 lines) on a fleet host.";
      input = { host = null; agent_id = null; lines = 40; source = "visible"; };
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        host=$(input .host); agent=$(input .agent_id); lines=$(input .lines); source=$(input .source)
        [ -n "$host" ] && [ -n "$agent" ] || fail 3 invalid_input "host and agent_id are required"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters"
        [[ "$lines" =~ ^[0-9]+$ ]] || fail 3 invalid_input "lines must be an integer"
        case "$source" in visible|recent|recent-unwrapped) ;; *) fail 3 invalid_input "source must be visible, recent or recent-unwrapped" ;; esac
        [ "$lines" -gt 200 ] && lines=200
        [ "$lines" -gt 0 ] || lines=1
        target=""
        case "$host" in
          ${lib.concatMapStringsSep "
          " (h: ''${h.name}) target="${sshTarget h}" ;;'') cfg.hosts}
          *) fail 3 invalid_input "host not in fleet: $host" ;;
        esac
        at=$(now_iso); rc=0
        if [ -z "$target" ]; then
          text=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.herdrCommand} agent read "$agent" --lines "$lines" --source "$source" --format text 2>/dev/null) || rc=$?
        else
          text=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=${toString cfg.timeoutSeconds} -o StrictHostKeyChecking=accept-new "$target" herdr agent read "$agent" --lines "$lines" --source "$source" --format text 2>/dev/null) || rc=$?
        fi
        case "$rc" in
          0) ;;
          124) fail 2 timeout "no answer within ${toString cfg.timeoutSeconds}s" "$(jq -cn --arg h "$host" --arg a "$agent" '{task:"herdr:inspect",host:$h,agent_id:$a}')" ;;
          255) fail 2 unreachable "ssh could not connect" "$(jq -cn --arg h "$host" --arg a "$agent" '{task:"herdr:inspect",host:$h,agent_id:$a}')" ;;
          *) fail 2 command_failed "herdr agent read exited $rc (unknown agent?)" "$(jq -cn --arg h "$host" --arg a "$agent" '{task:"herdr:inspect",host:$h,agent_id:$a}')" ;;
        esac
        text=$(head -n 200 <<<"$text")
        n=$(printf '%s
' "$text" | grep -c . || true)
        emit "$(jq -cn --arg h "$host" --arg a "$agent" --arg at "$at" --arg t "$text" --argjson n "$n" --argjson req "$(input .lines)" --arg src "$source"           '{schema_version:1, task:"herdr:inspect", host:$h, agent_id:$a, observed_at:$at, source:$src, lines_returned:$n, truncated:($req > 200), excerpt:$t, error:null}')"
      '';
    };
  } // lib.genAttrs [ "herdr:message" "herdr:await" ] (import ./pending.nix);
}
