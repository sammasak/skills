# harness:* tasks: what an agent is doing, from the harness's own session store
# (Claude Code JSONL under ~/.claude/projects/<cwd-slug>/<id>.jsonl, Pi under
# ~/.pi/agent/sessions/<cwd-slug>/). The JSONL formats are undocumented and may
# change; every field is read defensively and the excerpts are bounded.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  t = lib.types;
  sshTarget = h: if h.ssh == null then "" else h.ssh;
in
{
  imports = [ ./fleet.nix ];

  options.coordinator = {
    claudeProjectsDir = lib.mkOption { type = t.str; default = "$HOME/.claude/projects"; };
    piSessionsDir = lib.mkOption { type = t.str; default = "$HOME/.pi/agent/sessions"; };
  };

  config.tasks."harness:session-summary" = {
    description = "Last events of one harness session: last prompt, last answer, tools, awaiting_input.";
    input = { host = null; harness = null; session_id = null; cwd = null; tail = 50; };
    exec = ''
      set -uo pipefail
      . ${cfg.lib}
      host=$(input .host); harness=$(input .harness); sid=$(input .session_id); cwd=$(input .cwd); tail_n=$(input .tail)
      ctx() { jq -cn --arg h "$host" --arg ha "$harness" --arg s "$sid" '{task:"harness:session-summary",host:$h,harness:$ha,session_id:$s}'; }
      [ -n "$host" ] && [ -n "$harness" ] && [ -n "$sid" ] && [ -n "$cwd" ] || fail 3 invalid_input "host, harness, session_id and cwd are required" "$(ctx)"
      [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || fail 3 invalid_input "session_id has unsafe characters" "$(ctx)"
      [[ "$cwd" =~ ^/[A-Za-z0-9_./-]*$ ]] || fail 3 invalid_input "cwd has unsafe characters" "$(ctx)"
      [[ "$tail_n" =~ ^[0-9]+$ ]] || tail_n=50; [ "$tail_n" -gt 500 ] && tail_n=500
      target=""
      case "$host" in
        ${lib.concatMapStringsSep "\n        " (h: ''${h.name}) target="${sshTarget h}" ;;'') cfg.hosts}
        *) fail 3 invalid_input "host not in fleet: $host" ;;
      esac
      slug=$(printf '%s' "$cwd" | sed -E 's/[^A-Za-z0-9]/-/g')
      case "$harness" in
        claude) remote_cmd="d=${cfg.claudeProjectsDir}/$slug; f=\"\$d/$sid.jsonl\"; [ -r \"\$f\" ] && tail -n $tail_n \"\$f\" || exit 44" ;;
        pi)     remote_cmd="d=${cfg.piSessionsDir}/-$slug--; f=\$(ls -t \"\$d\"/*_$sid.jsonl 2>/dev/null | head -1); [ -n \"\$f\" ] && tail -n $tail_n \"\$f\" || exit 44" ;;
        codex)  fail 2 unsupported "codex keeps no readable session store on the fleet yet" "$(ctx)" ;;
        *)      fail 3 invalid_input "harness must be claude, pi or codex" "$(ctx)" ;;
      esac
      at=$(now_iso); rc=0
      if [ -z "$target" ]; then
        events=$(timeout -k 1 ${toString cfg.timeoutSeconds} bash -c "$remote_cmd" 2>/dev/null) || rc=$?
      else
        events=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=${toString cfg.timeoutSeconds} -o StrictHostKeyChecking=accept-new "$target" bash -c "$(printf '%q' "$remote_cmd")" 2>/dev/null) || rc=$?
      fi
      case "$rc" in
        0) ;;
        44) fail 2 not_found "no session file for $harness/$sid under $cwd" "$(ctx)" ;;
        124) fail 2 timeout "no answer within ${toString cfg.timeoutSeconds}s" "$(ctx)" ;;
        255) fail 2 unreachable "ssh could not connect" "$(ctx)" ;;
        *) fail 2 command_failed "session read exited $rc" "$(ctx)" ;;
      esac
      summary=$(jq -cs --arg at "$at" --arg h "$host" --arg ha "$harness" --arg s "$sid" --arg cwd "$cwd" '
        def txt: if type=="string" then . elif type=="array" then (map(select(type=="object" and .type=="text") | .text) | join(" ")) else "" end;
        def ts: (.timestamp // "");
        [.[] | select(type=="object")] as $ev
        | [$ev[] | select((.type=="user" or (.message.role? == "user")) and ((.message.content|type)=="string" or ((.message.content|type)=="array" and any(.message.content[]; .type=="text"))))] as $users
        | [$ev[] | select(.type=="assistant" or (.message.role? == "assistant"))] as $asst
        | ($asst | last) as $la
        | ($la.message.content | txt) as $atext
        | {schema_version:1, task:"harness:session-summary", host:$h, harness:$ha, session_id:$s, cwd:$cwd, observed_at:$at,
           event_count: ($ev|length),
           last_event_at: ([$ev[] | ts | select(. != "")] | last),
           last_role: (if $la == null then null elif (($ev|last) == $la) or ((($ev|last).type) == "system") then "assistant" else "user" end),
           last_user_prompt_excerpt: (($users | last).message.content | txt | .[0:200]),
           last_assistant_excerpt: ($atext | .[0:400]),
           last_tools: ([$asst[] | .message.content | if type=="array" then .[] | select(.type=="tool_use") | .name else empty end] | .[-5:]),
           awaiting_input: ($la != null and (($atext | test("\\?\\s*$")) or (($la.message.content|type)=="array" and any($la.message.content[]; .type=="tool_use" and (.name=="AskUserQuestion" or .name=="ExitPlanMode"))))),
           task_ref: (([$users[] | .message.content | txt] | join(" ")) | capture("(?<r>#[0-9]+)")?.r // null),
           error: null}' <<<"$events") || fail 2 malformed "session lines were not parseable JSON" "$(ctx)"
      emit "$summary"
    '';
  };
}
