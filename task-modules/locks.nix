# host:locks (skills #28): the heavy-work and light-work lock lanes on this host and on every saved
# machine, as data for coord:capacity: who holds each lane, who waits, since when. Local reads go
# through /proc/locks and ps; a saved machine is reached over its ssh target with the same observer
# on stdin. Observations exit 0 and carry errors as data, like herdr:inventory.
{ lib, config, pkgs, ... }:
let
  cfg = config.coordinator;
  t = toString cfg.timeoutSeconds;
  # one TSV line per holder or waiter of a lane lock: lane, role, pid, age in seconds, argv
  observer = pkgs.writeText "host-locks-observe.sh" ''
    #!/bin/sh
    h=$(hostname -s 2>/dev/null || hostname)
    for lane in heavy-work light-work; do
      f="/tmp/$h-$lane.lock"
      [ -e "$f" ] || continue
      ino=$(stat -c %i "$f" 2>/dev/null) || continue
      grep -E "FLOCK .*:$ino " /proc/locks 2>/dev/null | while read -r line; do
        case "$line" in *'->'*) role=waiter ;; *) role=holder ;; esac
        pid=$(printf '%s' "$line" | awk '{for (i = 1; i <= NF; i++) if ($i == "WRITE" || $i == "READ") { print $(i + 1); exit }}')
        et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$et" ] || continue
        args=$(ps -o args= -p "$pid" 2>/dev/null | tr '\t' ' ' | cut -c1-200)
        printf '%s\t%s\t%s\t%s\t%s\n' "$lane" "$role" "$pid" "$et" "$args"
      done
    done
  '';
in
{
  imports = [ ./common.nix ];

  options.coordinator.sshCommand = lib.mkOption { type = lib.types.str; default = "ssh"; description = "Reaches a saved machine's target for host:locks (overridable for tests)."; };
  options.coordinator.locksCommand = lib.mkOption {
    type = lib.types.str;
    default = "sh ${observer}";
    description = "Observes this host's lock lanes as TSV (overridable for tests).";
  };

  config.tasks."host:locks" = {
    description = "Read-only: the heavy-work and light-work lock lanes (holder, waiters, since when) on this host and on every saved machine; partial on machine failures, never fails itself.";
    exec = ''
      ${cfg.prelude}
      at=$(now_iso); now=$(now_epoch); hosts_out="[]"; answered=0; total=1
      mj=$(machines_json); machines=$(jq -c .machines <<<"$mj"); machines_error=$(jq -c .error <<<"$mj")
      lanes_json() { # <host-label> <tsv on stdin>
        jq -Rs --arg host "$1" --argjson now "$now" '
          split("\n") | map(select(length > 0) | split("\t") | select(length >= 5))
          | map({lane:.[0], role:.[1], pid:(.[2] | tonumber? // null), age_s:(.[3] | tonumber? // 0),
                 what:(.[4:] | join("\t") | sub("^flock .*?\\.lock +"; "") | .[0:160])})
          | group_by(.lane) | map(. as $g | {
              lane:$g[0].lane, lock:("/tmp/" + $host + "-" + $g[0].lane + ".lock"),
              holder:(($g | map(select(.role == "holder")) | first) // null
                      | if . == null then null else {pid, age_s, since:(($now - .age_s) | todate), what} end),
              waiters:($g | map(select(.role == "waiter")) | sort_by(-.age_s) | map({pid, age_s, since:(($now - .age_s) | todate), what}))})
          | map(. + {queue_depth:((.waiters | length) + (if .holder == null then 0 else 1 end))})' 2>/dev/null; }
      add_host() { hosts_out=$(jq -c --argjson h "$1" '. + [$h]' <<<"$hosts_out"); }
      observe() { # <host-label> <machine-or-empty> <ssh-target-or-empty>
        local host="$1" m="$2" target="$3" rc=0 tsv errf herr lanes
        errf=$(mktemp)
        if [ -z "$m" ]; then tsv=$(timeout -k 1 ${t} ${cfg.locksCommand} 2>"$errf") || rc=$?
        else tsv=$(timeout -k 1 ${t} ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=5 "$target" sh -s <${observer} 2>"$errf") || rc=$?; fi
        herr=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        if [ "$rc" -ne 0 ]; then
          add_host "$(jq -cn --arg h "$host" --arg m "$m" --arg k "$(rc_kind $rc)" --argjson rc "$rc" --arg e "$herr" \
            '{host:$h, machine:(if $m == "" then null else $m end), reachable:false, error:{kind:$k, message:("locks observation exited \($rc)" + (if $e == "" then "" else ": " + $e end))}, lanes:[]}')"
          return 0
        fi
        lanes=$(lanes_json "$host" <<<"$tsv") && [ -n "$lanes" ] \
          || { add_host "$(jq -cn --arg h "$host" --arg m "$m" '{host:$h, machine:(if $m == "" then null else $m end), reachable:false, error:{kind:"malformed", message:"the locks observer printed no TSV"}, lanes:[]}')"; return 0; }
        answered=$((answered+1))
        add_host "$(jq -cn --arg h "$host" --arg m "$m" --argjson l "$lanes" '{host:$h, machine:(if $m == "" then null else $m end), reachable:true, error:null, lanes:$l}')"
      }
      observe "$(local_host)" "" ""
      while IFS=$'\t' read -r label target; do
        [ -n "$label" ] || continue
        total=$((total+1))
        if ! valid_machine "$label" || ! [[ "$target" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$ ]]; then
          add_host "$(jq -cn --arg l "$label" '{host:$l, machine:$l, reachable:false, error:{kind:"invalid_label", message:"saved machine label or target has characters the coordinator will not pass to ssh"}, lanes:[]}')"
          continue
        fi
        observe "$label" "$label" "$target"
      done < <(jq -r '.[] | [.label, (.target // "")] | @tsv' <<<"$machines")
      emit "$(jq -cn --arg at "$at" --argjson hosts "$hosts_out" --argjson n "$answered" --argjson total "$total" --argjson me "$machines_error" \
        '{schema_version:1, task:"host:locks", observed_at:$at, partial:($n < $total or $me != null), answered_hosts:$n, hosts_total:$total, machines_error:$me, hosts:$hosts}')"
    '';
  };
}
