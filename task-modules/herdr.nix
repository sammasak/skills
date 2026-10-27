# herdr:* tasks over the installed herdr CLI, herdr-native: the local server plus every enabled saved machine
# (`herdr machine list --json`), each reached with `herdr --machine <label>`. Observations exit 0 and carry
# `error` as data (devenv drops a failed task's output); only coord:brief decides the exit.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  t = toString cfg.timeoutSeconds;
in
{
  imports = [ ./common.nix ];

  tasks = {
    "herdr:inventory" = {
      description = "Every agent on this host and on every enabled saved herdr machine, record schema v1; partial on machine failures, never fails itself.";
      exec = ''
        ${cfg.prelude}
        at=$(now_iso); hosts_out="[]"; answered=0; total=1
        mj=$(machines_json); machines=$(jq -c .machines <<<"$mj"); machines_error=$(jq -c .error <<<"$mj")
        normalise() { # <host-label> <machine-or-empty> <raw agent list json>
          jq -c --arg host "$1" --arg m "$2" --arg at "$at" '
            .result.agents | select(type == "array") | map(select(type == "object" and (.pane_id | type) == "string")
            | {host:$host, machine:(if $m == "" then null else $m end), agent_id:.pane_id, harness:(.agent // "unknown"),
               session_id:(.agent_session.value? // null), cwd:(.cwd // null), title:(.terminal_title_stripped // .terminal_title // ""),
               observed_state:(.agent_status // "unknown"), observed_at:$at, state_change_seq:(.state_change_seq // null),
               task_ref:((.terminal_title_stripped // "") | capture("(?<r>#[0-9]+)")?.r // null), evidence_ref:null,
               approval_required:(.agent_status == "blocked"), error:null})' <<<"$3" 2>/dev/null; }
        observe() { # <host-label> <machine-or-empty>
          local host="$1" m="$2" rc=0 raw records
          raw=$(herdr_at ${t} "$m" agent list 2>/dev/null) || rc=$?
          if [ "$rc" -ne 0 ]; then
            hosts_out=$(jq -c --arg h "$host" --arg m "$m" --arg k "$(rc_kind $rc)" --argjson rc "$rc" '. + [{host:$h, machine:(if $m == "" then null else $m end), reachable:false, error:{kind:$k, message:("herdr agent list: " + $k + " (exit " + ($rc|tostring) + ")")}, agents:[]}]' <<<"$hosts_out"); return; fi
          records=$(normalise "$host" "$m" "$raw") && [ -n "$records" ] \
            || { hosts_out=$(jq -c --arg h "$host" --arg m "$m" '. + [{host:$h, machine:(if $m == "" then null else $m end), reachable:false, error:{kind:"malformed", message:"herdr agent list did not return an agent_list"}, agents:[]}]' <<<"$hosts_out"); return; }
          answered=$((answered+1))
          hosts_out=$(jq -c --arg h "$host" --arg m "$m" --argjson r "$records" '. + [{host:$h, machine:(if $m == "" then null else $m end), reachable:true, error:null, agents:$r}]' <<<"$hosts_out")
        }
        observe "$(local_host)" ""
        while IFS= read -r label; do
          [ -n "$label" ] || continue
          valid_machine "$label" || continue
          total=$((total+1)); observe "$label" "$label"
        done < <(jq -r '.[].label' <<<"$machines")
        emit "$(jq -cn --arg at "$at" --argjson hosts "$hosts_out" --argjson n "$answered" --argjson total "$total" --argjson nm "$(jq 'length' <<<"$machines")" --argjson me "$machines_error" \
          '{schema_version:1, task:"herdr:inventory", observed_at:$at, partial:($n < $total or $me != null), answered_hosts:$n, hosts_total:$total, machines_configured:$nm, machines_error:$me, hosts:$hosts}')"
      '';
    };

    "herdr:inspect" = {
      description = "Bounded terminal excerpt of one agent (<= 200 lines, <= 64 KiB) on this host or a saved machine.";
      input = { machine = null; agent_id = null; lines = 40; source = "visible"; };
      exec = ''
        ${cfg.prelude}
        m=$(input .machine); agent=$(input .agent_id); lines=$(input .lines); source=$(input .source)
        host=$([ -n "$m" ] && printf '%s' "$m" || local_host)
        ctx=$(jq -cn --arg h "$host" --arg m "$m" --arg a "$agent" '{task:"herdr:inspect",host:$h,machine:(if $m == "" then null else $m end),agent_id:$a}')
        [ -n "$agent" ] || fail 3 invalid_input "agent_id is required" "$ctx"
        [ -z "$m" ] || valid_machine "$m" || fail 3 invalid_input "machine label has unsafe characters" "$ctx"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters" "$ctx"
        [[ "$lines" =~ ^[0-9]{1,6}$ ]] || fail 3 invalid_input "lines must be an integer below 1000000" "$ctx"
        case "$source" in visible|recent|recent-unwrapped) ;; *) fail 3 invalid_input "source must be visible, recent or recent-unwrapped" "$ctx" ;; esac
        requested=$lines; [ "$lines" -gt 200 ] && lines=200; [ "$lines" -gt 0 ] || lines=1
        at=$(now_iso); rc=0
        # herdr 0.9.5 parses <TARGET> first and rejects options before it ("unknown option"); valid_id excludes a leading '-'
        text=$(herdr_at ${t} "$m" agent read "$agent" --lines "$lines" --source "$source" --format text 2>/dev/null) || rc=$?
        [ "$rc" -eq 0 ] || fail 2 "$(rc_kind $rc)" "herdr agent read: $(rc_kind $rc) (exit $rc; unknown agent or machine?)" "$ctx"
        cut=$(printf '%s\n' "$text" | head -n 200 | LC_ALL=C head -c 65536); truncated=false; capped=false
        [ "$cut" = "$text" ] || truncated=true; [ "$requested" -le 200 ] || capped=true
        emit "$(jq -cn --argjson c "$ctx" --arg at "$at" --arg t "$cut" --arg src "$source" --argjson req "$requested" --argjson tr "$truncated" --argjson cap "$capped" \
          '{schema_version:1} + $c + {observed_at:$at, source:$src, lines_requested:$req, lines_returned:($t | split("\n") | length), truncated:$tr, capped:$cap, excerpt:$t, error:null}')"
      '';
    };
    "herdr:message" = {
      description = "ACT: send a confirmed coord:handoff draft to its agent; audit log, duplicate detection, never to a blocked or changed agent.";
      input = { handoff_id = null; confirm = null; resend = null; };
      exec = ''
        ${cfg.prelude}
        id=$(input .handoff_id); confirm=$(input .confirm); resend=$(input .resend)
        ctx=$(jq -cn --arg i "$id" '{task:"herdr:message",handoff_id:$i}')
        [[ "$id" =~ ^[a-f0-9]{12}$ ]] || fail 3 invalid_input "handoff_id must be a 12-hex coord:handoff id" "$ctx"
        draft="${cfg.stateDir}/handoffs/$id.json"
        [ -r "$draft" ] || fail 3 invalid_input "no draft with handoff_id $id (run coord:handoff first)" "$ctx"
        host=$(jq -r '.host // empty' "$draft"); m=$(jq -r '.machine // empty' "$draft"); agent=$(jq -r '.agent_id // empty' "$draft"); text=$(jq -r '.text // empty' "$draft"); ref=$(jq -r '.task_ref // empty' "$draft"); want_session=$(jq -r '.session_id // empty' "$draft")
        [ -n "$host" ] && [ -n "$agent" ] && [ -n "$text" ] || fail 3 invalid_input "draft $id is incomplete" "$ctx"
        # the id is content-addressed: re-derive it so the text sent is the text the owner confirmed
        [ "$(printf '%s|%s|%s|%s|%s' "$host" "$agent" "$want_session" "$ref" "$text" | sha256sum | cut -c1-12)" = "$id" ] || fail 3 invalid_input "draft $id does not match its content (edited?)" "$ctx"
        [ "$confirm" = "$host/$agent" ] || fail 3 not_confirmed "confirm must equal the draft target '$host/$agent' (got '$confirm')" "$ctx"
        valid_id "$agent" || fail 3 invalid_input "draft agent_id has unsafe characters" "$ctx"
                audit="${cfg.stateDir}/audit.jsonl"; mkdir -p "${cfg.stateDir}"; touch "$audit"
        exec 9>"$audit.lock"; flock -w 10 9 || fail 2 busy "another herdr:message holds the audit lock" "$ctx"
        [ ! -s "$audit" ] || jq -n -e 'all(inputs; type == "object" and (.audit_id|type) == "string" and (.phase|type) == "string")' "$audit" >/dev/null 2>&1 \
          || fail 2 audit_corrupt "audit log is not valid JSON lines; refusing to send until the owner inspects $audit" "$ctx"
        attempts=$(jq -c --arg i "$id" 'select(.handoff_id == $i and .phase == "attempt")' "$audit") || fail 2 audit_corrupt "audit lookup failed" "$ctx"
        prior=$(tail -1 <<<"$attempts")
        errf=$(mktemp); rc=0; st=$(herdr_at ${t} "$m" agent get "$agent" 2>"$errf" 9>&-) || rc=$?
        code=$(jq -rs 'if length == 1 then (.[0].error.code // empty) else empty end' "$errf" 2>/dev/null || true); rm -f "$errf"
        [ "$rc" -eq 0 ] || fail 2 "''${code:-$(rc_kind $rc)}" "herdr agent get failed for $host/$agent: ''${code:-$(rc_kind $rc)} (exit $rc)" "$ctx"
        state=$(jq -r '.result.agent.agent_status // empty' <<<"$st" 2>/dev/null || true); seq=$(jq -r '.result.agent.state_change_seq // empty' <<<"$st" 2>/dev/null || true); session=$(jq -r '.result.agent.agent_session.value // empty' <<<"$st" 2>/dev/null || true)
        case "$state" in idle|done) ;; blocked) fail 2 agent_blocked "agent $host/$agent is blocked (needs a human at its prompt); not sending" "$ctx" ;;
          working) fail 2 agent_busy "agent $host/$agent is mid-turn; a queued prompt would blur which turn answered it. Check herdr:inventory until it is idle, then send" "$ctx" ;;
          *) fail 2 agent_state_unknown "herdr agent get returned no usable state for $host/$agent; not sending" "$ctx" ;; esac
        [[ "$seq" =~ ^[0-9]+$ ]] || fail 2 agent_state_unknown "herdr agent get returned no state_change_seq; not sending" "$ctx"
        if [ -n "$want_session" ] && [ "$session" != "$want_session" ]; then
          fail 2 agent_changed "pane $host/$agent now runs session ''${session:-?} (draft was for $want_session); the agent restarted or the pane was reused" "$ctx"
        fi
        if [ -n "$prior" ]; then
          pid=$(jq -r .audit_id <<<"$prior")
          poutcome=$(jq -r --arg a "$pid" 'select(.audit_id == $a and .phase == "outcome") | .outcome' "$audit" | tail -1)
          [ "$resend" = "$pid" ] || fail 3 duplicate "handoff $id was already sent (audit $pid, outcome ''${poutcome:-interrupted}); inspect the pane first (herdr:inspect); only the owner can decide to send it again (resend=\"$pid\")" "$ctx"
          # any earlier attempt whose delivery is unconfirmed, and not superseded by a LATER delivered one, still counts:
          # if the agent's state advanced since it, the text probably arrived. Newest first, so the flag means "a later attempt was delivered".
          delivered_later=false
          while IFS= read -r att; do
            [ -n "$att" ] || continue
            a_id=$(jq -r .audit_id <<<"$att"); a_seq=$(jq -r '.seq_before // 0' <<<"$att")
            a_out=$(jq -r --arg a "$a_id" 'select(.audit_id == $a and .phase == "outcome") | .outcome' "$audit" | tail -1)
            case "''${a_out:-interrupted}" in
              delivered) delivered_later=true ;;
              unknown_delivery|interrupted|agent_prompt_stalled)
                if [ "$delivered_later" != true ]; then
                  [ "$seq" -ge "$a_seq" ] || fail 2 agent_restarted "state_change_seq went backwards ($a_seq -> $seq) since attempt $a_id; the agent or Herdr restarted, inspect before resending" "$ctx"
                  [ "$seq" -eq "$a_seq" ] || fail 2 probably_received "agent state advanced ($a_seq -> $seq) after attempt $a_id with outcome ''${a_out:-interrupted}; it probably received the message. Inspect with herdr:inspect instead of resending" "$ctx"
                fi ;;
            esac
          done < <(tac <<<"$attempts")
        fi
        aid=$(printf '%s|%s|%s' "$id" "$(now_iso)" "$RANDOM$RANDOM" | sha256sum | cut -c1-12); at=$(now_iso)
        jq -cn --arg a "$aid" --arg i "$id" --arg h "$host" --arg m "$m" --arg ag "$agent" --arg at "$at" --arg c "$confirm" --arg s "$state" --argjson q "$seq" --arg ses "$session" \
          '{audit_id:$a, handoff_id:$i, phase:"attempt", host:$h, machine:(if $m == "" then null else $m end), agent_id:$ag, session_id:(if $ses == "" then null else $ses end), at:$at, confirm:$c, state_before:$s, seq_before:$q}' >> "$audit" \
          || fail 2 audit_failed "could not write the attempt record; not sending" "$ctx"
        outcome=interrupted
        trap 'jq -cn --arg a "$aid" --arg i "$id" --arg at "$(now_iso)" --arg o "$outcome" "{audit_id:\$a, handoff_id:\$i, phase:\"outcome\", at:\$at, outcome:\$o}" >> "$audit"' EXIT
        errf=$(mktemp); rc=0
        herdr_at ${toString cfg.messageTimeoutSeconds} "$m" agent prompt "$agent" "$text" >/dev/null 2>"$errf" 9>&- || rc=$?
        if [ "$rc" -eq 0 ]; then outcome=delivered
        else code=$(jq -rs 'if length == 1 then (.[0].error.code // empty) else empty end' "$errf" 2>/dev/null || true)
          # a stall means the text may already sit in the input box: delivery unknown, never "refused"
          case "$code" in agent_blocked|agent_not_found) outcome=$code ;; agent_prompt_stalled) outcome=agent_prompt_stalled ;; *) outcome=unknown_delivery ;; esac
        fi
        rm -f "$errf"
        rec=$(jq -cn --arg a "$aid" --arg i "$id" --arg h "$host" --arg m "$m" --arg ag "$agent" --arg at "$at" --arg o "$outcome" --arg s "$state" --argjson q "$seq" --arg ses "$session" \
          '{schema_version:1, task:"herdr:message", audit_id:$a, handoff_id:$i, host:$h, machine:(if $m == "" then null else $m end), agent_id:$ag, session_id:(if $ses == "" then null else $ses end), sent_at:$at, state_before:$s, seq_before:$q, outcome:$o,
            receipt:($o == "delivered"), worker_done:false, accepted:false,
            error:(if $o == "delivered" then null elif ($o == "unknown_delivery" or $o == "agent_prompt_stalled") then {kind:$o, message:"prompt did not confirm; the text may already sit in the input box of the agent. Inspect the pane; only the owner decides on a resend (audit " + $a + ")"} else {kind:$o, message:"herdr agent prompt refused: " + $o + "; nothing was delivered"} end)}')
        emit "$rec"
        [ "$outcome" = delivered ] || exit 2
      '';
    };

    "herdr:await" = {
      description = "Bounded wait for an agent's turn to END after a message: observes the turn start (working/blocked or a state_change_seq advance past since_seq), then idle/done/blocked. Reports herdr_state only, never acceptance.";
      input = { audit_id = null; machine = null; agent_id = null; since_seq = null; timeout_s = 120; start_timeout_s = 20; };
      exec = ''
        ${cfg.prelude}
        aid=$(input .audit_id); m=$(input .machine); agent=$(input .agent_id); tmo=$(input .timeout_s); since=$(input .since_seq); start_t=$(input .start_timeout_s); want_session=""
        audit="${cfg.stateDir}/audit.jsonl"
        delivery=live
        if [ -n "$aid" ]; then
          [[ "$aid" =~ ^[a-f0-9]{12}$ ]] || fail 3 invalid_input "audit_id must be 12 hex" '{"task":"herdr:await"}'
          [ ! -s "$audit" ] || jq -n -e 'all(inputs; type == "object" and (.audit_id|type) == "string" and (.phase|type) == "string")' "$audit" >/dev/null 2>&1 || fail 2 audit_corrupt "audit log is not valid JSON lines" '{"task":"herdr:await"}'
          att=$(jq -c --arg a "$aid" 'select(.audit_id == $a and .phase == "attempt")' "$audit" | tail -1) || fail 2 audit_corrupt "audit lookup failed" '{"task":"herdr:await"}'
          [ -n "$att" ] || fail 3 invalid_input "no herdr:message attempt with audit_id $aid" '{"task":"herdr:await"}'
          delivery=$(jq -r --arg a "$aid" 'select(.audit_id == $a and .phase == "outcome") | .outcome' "$audit" | tail -1); delivery=''${delivery:-interrupted}
          # interrupted = killed mid-prompt or still in flight: delivery unknown, like a timeout
          case "$delivery" in delivered|unknown_delivery|agent_prompt_stalled|interrupted) ;;
            *) fail 2 not_delivered "attempt $aid ended with outcome $delivery; nothing was delivered, so there is no turn to await" "$(jq -cn --arg a "$aid" --arg o "$delivery" '{task:"herdr:await",audit_id:$a,outcome:$o}')" ;; esac
          m=$(jq -r '.machine // empty' <<<"$att"); agent=$(jq -r .agent_id <<<"$att"); since=$(jq -r '.seq_before // empty' <<<"$att"); want_session=$(jq -r '.session_id // empty' <<<"$att")
        fi
        host=$([ -n "$m" ] && printf '%s' "$m" || local_host)
        ctx=$(jq -cn --arg h "$host" --arg m "$m" --arg a "$agent" --arg aid "$aid" '{task:"herdr:await",host:$h,machine:(if $m == "" then null else $m end),agent_id:$a,audit_id:(if $aid == "" then null else $aid end)}')
        [ -n "$agent" ] || fail 3 invalid_input "audit_id, or agent_id (and machine for a remote agent), are required" "$ctx"
        [ -z "$m" ] || valid_machine "$m" || fail 3 invalid_input "machine label has unsafe characters" "$ctx"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters" "$ctx"
        [[ "$tmo" =~ ^[0-9]+$ ]] && [ "$tmo" -ge 1 ] && [ "$tmo" -le 1800 ] || fail 3 invalid_input "timeout_s must be 1..1800" "$ctx"
        [[ "$start_t" =~ ^[0-9]+$ ]] && [ "$start_t" -ge 1 ] || fail 3 invalid_input "start_timeout_s must be a positive integer" "$ctx"; [ "$start_t" -lt "$tmo" ] || start_t=$tmo
        [ -z "$since" ] || [[ "$since" =~ ^[0-9]+$ ]] || fail 3 invalid_input "since_seq must be an integer" "$ctx"
                at=$(now_iso); deadline=$(( $(now_epoch) + tmo ))
        parse_agent() { state=$(jq -r '.result.agent.agent_status // empty' <<<"$1" 2>/dev/null || true); seq=$(jq -r '.result.agent.state_change_seq // empty' <<<"$1" 2>/dev/null || true); session=$(jq -r '.result.agent.agent_session.value // empty' <<<"$1" 2>/dev/null || true); }
        herdr_err() { jq -rs 'if length == 1 then (.[0].error.code // empty) else empty end' "$1" 2>/dev/null; }
        errf=$(mktemp); rc=0; st=$(herdr_at ${t} "$m" agent get "$agent" 2>"$errf") || rc=$?
        code=$(herdr_err "$errf"); rm -f "$errf"
        [ "$rc" -eq 0 ] || fail 2 "''${code:-$(rc_kind $rc)}" "herdr agent get failed for $host/$agent: ''${code:-$(rc_kind $rc)} (exit $rc)" "$ctx"
        parse_agent "$st"
        case "$state" in idle|done|working|blocked|unknown) ;; *) fail 2 agent_state_unknown "herdr agent get returned no usable state" "$ctx" ;; esac
        [[ "$seq" =~ ^[0-9]+$ ]] || fail 2 agent_state_unknown "herdr agent get returned no state_change_seq" "$ctx"
        [ -z "$want_session" ] || [ "$session" = "$want_session" ] || fail 2 agent_changed "pane $host/$agent now runs session ''${session:-?} (message went to $want_session)" "$ctx"
        if [ -n "$since" ] && [ "$seq" -lt "$since" ]; then
          fail 2 agent_restarted "state_change_seq went backwards ($since -> $seq): the agent or Herdr server restarted after the message" \
            "$(jq -cn --argjson c "$ctx" --arg s "$state" --argjson q "$seq" '$c + {herdr_state:$s, state_change_seq:$q, turn_observed:false, reached:false, accepted:false}')"
        fi
        turn_seen=false
        if [ "$state" = working ] || [ "$state" = blocked ] || { [ -n "$since" ] && [ "$seq" -gt "$since" ]; }; then turn_seen=true
        else
          errf=$(mktemp); rc=0; res=$(herdr_at $((start_t + 5)) "$m" agent wait "$agent" --until working --until blocked --timeout $((start_t * 1000)) 2>"$errf") || rc=$?
          code=$(herdr_err "$errf"); rm -f "$errf"
          if [ "$rc" -eq 0 ]; then turn_seen=true; parse_agent "$res"; [ -n "$state" ] || fail 2 agent_state_unknown "herdr agent wait returned no usable state" "$ctx"
            [ -z "$want_session" ] || [ "$session" = "$want_session" ] || fail 2 agent_changed "the pane's session changed during the wait" "$ctx"
          elif [ "$code" = timeout ] || [ "$rc" -eq 124 ]; then
            # a fast turn may have started and ended between the first get and this wait: one more look at the seq
            st2=$(herdr_at ${t} "$m" agent get "$agent" 2>/dev/null) || st2=""
            seq2=$(jq -r '.result.agent.state_change_seq // empty' <<<"$st2" 2>/dev/null || true); state2=$(jq -r '.result.agent.agent_status // empty' <<<"$st2" 2>/dev/null || true)
            session2=$(jq -r '.result.agent.agent_session.value // empty' <<<"$st2" 2>/dev/null || true)
            if [ -n "$since" ] && [[ "$seq2" =~ ^[0-9]+$ ]] && [ "$seq2" -gt "$since" ] && { [ -z "$want_session" ] || [ "$session2" = "$want_session" ]; }; then turn_seen=true; seq=$seq2; state=''${state2:-$state}
            else
            fail 2 no_turn_observed "agent $host/$agent stayed $state for ''${start_t}s after the prompt. Do not resend: inspect the pane with herdr:inspect first" \
              "$(jq -cn --argjson c "$ctx" --arg s "$state" --argjson q "$seq" '$c + {herdr_state:$s, state_change_seq:$q, turn_observed:false, reached:false, accepted:false}')"
            fi
          elif [ -n "$code" ]; then fail 2 "$code" "herdr agent wait refused: $code (agent gone?)" "$ctx"
          else fail 2 "$(rc_kind $rc)" "herdr agent wait: $(rc_kind $rc) (exit $rc)" "$ctx"; fi
        fi
        if [ "$state" != blocked ]; then
          remaining=$(( deadline - $(now_epoch) )); [ "$remaining" -ge 1 ] || remaining=1
          errf=$(mktemp); rc=0; res=$(herdr_at $((remaining + 5)) "$m" agent wait "$agent" --until idle --until done --until blocked --timeout $((remaining * 1000)) 2>"$errf") || rc=$?
          code=$(herdr_err "$errf"); rm -f "$errf"
          if [ "$rc" -eq 0 ]; then parse_agent "$res"; [ -n "$state" ] || fail 2 agent_state_unknown "herdr agent wait returned no usable state" "$ctx"
            [ -z "$want_session" ] || [ "$session" = "$want_session" ] || fail 2 agent_changed "the pane's session changed during the wait" "$ctx"
          elif [ "$code" = timeout ] || [ "$rc" -eq 124 ]; then
            fail 2 timeout "agent $host/$agent did not finish its turn within ''${tmo}s" \
              "$(jq -cn --argjson c "$ctx" --argjson tm "$tmo" '$c + {timeout_s:$tm, turn_observed:true, reached:false, accepted:false}')"
          elif [ -n "$code" ]; then fail 2 "$code" "herdr agent wait refused: $code (agent gone?)" "$ctx"
          else fail 2 "$(rc_kind $rc)" "herdr agent wait: $(rc_kind $rc) (exit $rc)" "$ctx"; fi
        fi
        emit "$(jq -cn --argjson c "$ctx" --arg at "$at" --arg s "$state" --argjson tm "$tmo" --argjson seen "$turn_seen" --arg d "$delivery" \
          '{schema_version:1} + $c + {started_at:$at, timeout_s:$tm, delivery:$d, herdr_state:$s, turn_observed:$seen, reached:true,
            worker_done:($s == "idle" or $s == "done"), needs_owner:($s == "blocked"), accepted:false,
            note:"accepted is decided by work:status evidence, never by this task", error:null}')"
      '';
    };
  };
}
