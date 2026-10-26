# harness:* tasks: what an agent is doing, from the harness's own session store
# (Claude Code JSONL under ~/.claude/projects/<cwd-slug>/<id>.jsonl, Pi under
# ~/.pi/agent/sessions/-<cwd-slug>--/). The formats are undocumented and may
# change; lines that do not parse are skipped and counted, excerpts are bounded.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  t = lib.types;
in
{
  imports = [ ./fleet.nix ];

  options.coordinator = {
    claudeProjectsDir = lib.mkOption { type = t.str; default = "$HOME/.claude/projects"; };
    piSessionsDir = lib.mkOption { type = t.str; default = "$HOME/.pi/agent/sessions"; };
  };

  config.tasks."harness:session-summary" = {
    description = "Last events of one harness session: last prompt, last answer, tools, awaiting_input.";
    input = { host = null; harness = null; session_id = null; cwd = null; tail = 200; };
    exec = ''
      ${cfg.prelude}
      host=$(input .host); harness=$(input .harness); sid=$(input .session_id); cwd=$(input .cwd); tail_n=$(input .tail)
      ctx=$(jq -cn --arg h "$host" --arg ha "$harness" --arg s "$sid" '{task:"harness:session-summary",host:$h,harness:$ha,session_id:$s}')
      [ -n "$host" ] && [ -n "$harness" ] && [ -n "$sid" ] && [ -n "$cwd" ] || fail 3 invalid_input "host, harness, session_id and cwd are required" "$ctx"
      [[ "$sid" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 3 invalid_input "session_id has unsafe characters" "$ctx"
      [[ "$cwd" =~ ^/[A-Za-z0-9_./-]*$ ]] || fail 3 invalid_input "cwd has unsafe characters" "$ctx"
      [[ "$tail_n" =~ ^[0-9]+$ ]] || tail_n=200; [ "$tail_n" -gt 500 ] && tail_n=500
      ${cfg.hostCase}
      slug=$(printf '%s' "$cwd" | sed -E 's/[^A-Za-z0-9]/-/g')
      case "$harness" in
        claude) remote_cmd="f=${cfg.claudeProjectsDir}/$slug/$sid.jsonl; [ -r \"\$f\" ] || exit 44; tail -n $tail_n \"\$f\"" ;;
        pi)     remote_cmd="d=${cfg.piSessionsDir}/-$slug--; f=\$(ls -t \"\$d\"/*_$sid.jsonl 2>/dev/null | head -1); [ -n \"\$f\" ] || exit 44; tail -n $tail_n \"\$f\"" ;;
        codex)  fail 2 unsupported "codex keeps no readable session store on the fleet yet" "$ctx" ;;
        *)      fail 3 invalid_input "harness must be claude, pi or codex" "$ctx" ;;
      esac
      at=$(now_iso); rc=0
      events=$(run_on ${toString cfg.timeoutSeconds} "$target" bash -c "$remote_cmd" 2>/dev/null) || rc=$?
      case "$rc" in
        0) ;;
        44) fail 2 not_found "no session file for $harness/$sid under $cwd" "$ctx" ;;
        *) fail 2 "$(rc_kind $rc)" "session read: $(rc_kind $rc) (exit $rc)" "$ctx" ;;
      esac
      total=$(printf '%s\n' "$events" | grep -c . || true)
      parsed=$(printf '%s\n' "$events" | jq -Rc 'fromjson? // empty' 2>/dev/null | jq -sc 'map(select(type == "object"))') || parsed="[]"
      summary=$(jq -cn --arg at "$at" --arg h "$host" --arg ha "$harness" --arg s "$sid" --arg cwd "$cwd" --argjson total "$total" --argjson ev "$parsed" '
        def txt: if type=="string" then . elif type=="array" then (map(select(type=="object" and .type? == "text") | (.text // "") | select(startswith("<system-reminder>") | not)) | join(" ")) else "" end;
        def role: (.message.role? // (if .type == "user" or .type == "assistant" then .type else null end));
        [$ev[] | select(role == "user" and ((.message.content | type) == "string" or ((.message.content | type) == "array" and any(.message.content[]; type == "object" and .type? == "text"))))] as $users
        | [$ev[] | select(role == "assistant")] as $asst
        | [$ev[] | select(role != null)] as $conv
        | ($asst | last) as $la
        | ($conv | last) as $lc
        | ($la.message.content // "" | txt) as $atext
        | ($lc != null and ($lc | role) == "assistant") as $assistant_last
        | {schema_version:1, task:"harness:session-summary", host:$h, harness:$ha, session_id:$s, cwd:$cwd, observed_at:$at,
           event_count: ($ev|length), skipped_lines: ($total - ($ev|length)),
           last_event_at: ([$ev[] | .timestamp? // empty | strings] | last),
           last_role: (if $lc == null then null else ($lc | role) end),
           last_user_prompt_excerpt: ((($users | last).message.content // "") | txt | .[0:200]),
           last_assistant_excerpt: ($atext | .[0:400]),
           last_tools: ([$asst[] | .message.content | if type=="array" then .[] | select(type=="object" and .type? == "tool_use") | (.name // "?") else empty end] | .[-5:]),
           awaiting_input: ($assistant_last and (($atext | test("\\?\\s*$")) or (($la.message.content|type)=="array" and any($la.message.content[]; type=="object" and .type? == "tool_use" and (.name == "AskUserQuestion" or .name == "ExitPlanMode"))))),
           task_ref: ([$users[] | .message.content | txt | capture("(?<r>#[0-9]+)")?.r] | last // null),
           error: null}' 2>/dev/null) || fail 2 malformed "session events could not be summarised" "$ctx"
      emit "$summary"
    '';
  };
}
