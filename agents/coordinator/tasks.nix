# Coordinator role DAG: work:status joins live Herdr state with durable GitHub/git
# evidence per agent; coord:brief renders it. Both depend on every source with
# @completed, so one failed source is reported as partial, never hidden.
{ lib, config, ... }:

let
  cfg = config.coordinator;
in
{
  imports = [ ../../task-modules/fleet.nix ];

  tasks = {
    "work:status" = {
      description = "Per-agent herdr_state + evidence-derived work_verdict; partial on failed sources.";
      after = [ "herdr:inventory@completed" "gh:work@completed" "git:recent@completed" ];
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        at=$(now_iso)
        inv=$(upstream "herdr:inventory"); gh=$(upstream "gh:work"); git=$(upstream "git:recent")
        out=$(jq -cn --arg at "$at" --argjson inv "$inv" --argjson gh "$gh" --argjson git "$git" '
          def failed(name; src): if src == null then [{source:name, error:{kind:"missing", message:"task produced no output"}}]
                                 else ((src.failed_sources // []) | map({source:(name + ":" + (.repo // .host // "?")), error}))
                                      + ((src.hosts // []) | map(select(.reachable == false) | {source:(name + ":" + .host), error})) end;
          ($gh.repos // [] | map(.prs[]) ) as $prs
          | ($gh.repos // [] | map(.issues[])) as $issues
          | ($git.repos // []) as $checkouts
          | def refnum: if . == null then null else (ltrimstr("#") | tonumber? // null) end;
          def evidence_for($ref): ($ref | refnum) as $n
            | if $n == null then {verdict:"unknown", refs:[], reasons:["no task reference (#N) on the agent"]}
              else ([$prs[] | select((.closes | index($n)) != null or (.title | test("#\($n)\\b")) or (.branch | test("\($n)")))]) as $ps
              | ([$issues[] | select(.number == $n)]) as $is
              | if any($ps[]; .merged_at != null) then {verdict:"verified", refs:[$ps[] | select(.merged_at != null) | .url], reasons:["merged PR closes or names #\($n)"]}
                elif any($ps[]; .state == "OPEN") then {verdict:"unverified", refs:[$ps[] | select(.state=="OPEN") | .url],
                       reasons:(["open PR for #\($n), not merged"] + [$ps[] | select(.state=="OPEN") | select(any(.checks[]?; . != "SUCCESS")) | "PR #\(.number) has non-green checks"])}
                elif ($is | length) > 0 then {verdict:"unverified", refs:[$is[].url], reasons:["issue #\($n) open, no PR found"]}
                else {verdict:"unknown", refs:[], reasons:["#\($n) not found in fleet repos"]} end end;
          {schema_version:1, task:"work:status", observed_at:$at,
           failed_sources: (failed("herdr:inventory"; $inv) + failed("gh:work"; $gh) + failed("git:recent"; $git)),
           items: [($inv.hosts // [])[] | .host as $h | .agents[] | . as $a
             | (evidence_for($a.task_ref)) as $e
             | ([$checkouts[] | select(.checkout == $a.cwd)] | first) as $co
             | {host:$h, agent_id:$a.agent_id, harness:$a.harness, session_id:$a.session_id, title:$a.title, task_ref:$a.task_ref,
                herdr_state:$a.observed_state, state_age_s:$a.state_age_s, stale:$a.stale, observed_at:$a.observed_at,
                work_verdict: (if $a.observed_state == "blocked" then "blocked" else $e.verdict end),
                needs_owner: ($a.observed_state == "blocked" or $a.approval_required == true),
                evidence_ref: ($e.refs | first // null),
                reasons: ($e.reasons + (if $co != null and $co.dirty_files > 0 then ["checkout has \($co.dirty_files) uncommitted file(s)"] else [] end)
                                     + (if $co != null and ($co.unpushed|length) > 0 then ["\($co.unpushed|length) unpushed commit(s)"] else [] end)
                                     + (if $a.stale then ["Herdr state is from a snapshot (\($a.snapshot_age_s // "?")s old)"] else [] end)),
                sources: ([{task:"herdr:inventory", observed_at:$a.observed_at}] + (if $gh != null then [{task:"gh:work", observed_at:$gh.observed_at}] else [] end)
                          + (if $git != null then [{task:"git:recent", observed_at:$git.observed_at}] else [] end))}]}
          | .partial = ((.failed_sources | length) > 0)')
        emit "$out"
        [ "$inv" != null ] || exit 2
      '';
    };

    "coord:brief" = {
      description = "Owner-facing brief: items needing input first, then every agent with herdr_state and work_verdict.";
      after = [ "work:status@completed" ];
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        ws=$(upstream "work:status")
        [ "$ws" != null ] || fail 2 missing "work:status produced no output" '{"task":"coord:brief"}'
        dir="${cfg.stateDir}/brief"; mkdir -p "$dir"
        brief=$(jq -c '. + {task:"coord:brief"}' <<<"$ws")
        printf '%s\n' "$brief" > "$dir/latest.json"
        printf '%s\n' "$brief" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
        jq -r --arg f "$dir/latest.json" '
          "# Fleet brief (\(.observed_at))",
          (if .partial then "", "**Partial:** " + ([.failed_sources[] | "\(.source): \(.error.kind) — \(.error.message)"] | join("; ")) else empty end),
          "", "## Needs you",
          (([.items[] | select(.needs_owner)] | if length == 0 then ["- nothing"] else map("- \(.host)/\(.agent_id) (\(.harness)) \(.task_ref // "no ref"): herdr=\(.herdr_state) → \(.reasons | join("; "))") end)[]),
          "", "## Agents",
          (if (.items|length) == 0 then "- none observed" else (.items[] | "- \(.host)/\(.agent_id) \(.harness) \(.task_ref // "-") | herdr=\(.herdr_state) (\(.state_age_s)s\(if .stale then ", stale" else "" end)) | work=\(.work_verdict)\(if .evidence_ref then " " + .evidence_ref else "" end)\(if (.reasons|length) > 0 then " | " + (.reasons | join("; ")) else "" end)") end),
          "", "Full JSON: \($f)"
        ' <<<"$brief"
      '';
    };

    "coord:handoff" = {
      description = "Draft (never send) a bounded assignment brief for one agent; saves it under the state dir with a handoff_id.";
      input = { host = null; agent_id = null; task_ref = null; scope = null; expected_evidence = null; acceptance = null; owner_input = ""; };
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        host=$(input .host); agent=$(input .agent_id); ref=$(input .task_ref); scope=$(input .scope); ev=$(input .expected_evidence); acc=$(input .acceptance); need=$(input .owner_input)
        ctx() { jq -cn --arg h "$host" --arg a "$agent" '{task:"coord:handoff",host:$h,agent_id:$a}'; }
        [ -n "$host" ] && [ -n "$agent" ] && [ -n "$ref" ] && [ -n "$scope" ] && [ -n "$ev" ] && [ -n "$acc" ] \
          || fail 3 invalid_input "host, agent_id, task_ref, scope, expected_evidence and acceptance are required" "$(ctx)"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters" "$(ctx)"
        [[ "$ref" =~ ^#[0-9]+$ ]] || fail 3 invalid_input "task_ref must look like #N" "$(ctx)"
        case "$host" in
          ${lib.concatMapStringsSep "\n          " (h: ''${h.name}) ;;'') cfg.hosts}
          *) fail 3 invalid_input "host not in fleet: $host" "$(ctx)" ;;
        esac
        for v in "$scope" "$ev" "$acc" "$need"; do [ "''${#v}" -le 2000 ] || fail 3 invalid_input "a field exceeds 2000 characters" "$(ctx)"; done
        at=$(now_iso)
        text=$(printf 'Assignment %s for %s/%s\n\nScope: %s\n\nExpected evidence: %s\n\nAcceptance: %s\n%s\nReply in this pane when done, naming the commit or PR. Do not merge, deploy or delete anything.\n' \
          "$ref" "$host" "$agent" "$scope" "$ev" "$acc" "$([ -n "$need" ] && printf '\nOwner input still needed: %s\n' "$need")")
        id=$(printf '%s|%s|%s|%s' "$host" "$agent" "$ref" "$text" | sha256sum | cut -c1-12)
        dir="${cfg.stateDir}/handoffs"; mkdir -p "$dir"
        rec=$(jq -cn --arg id "$id" --arg at "$at" --arg h "$host" --arg a "$agent" --arg r "$ref" --arg t "$text" --arg need "$need" \
          '{schema_version:1, task:"coord:handoff", handoff_id:$id, created_at:$at, host:$h, agent_id:$a, task_ref:$r, text:$t,
            owner_input: (if $need == "" then null else $need end), approval_required:true, sent:false, error:null}')
        [ -f "$dir/$id.json" ] || printf '%s\n' "$rec" > "$dir/$id.json"
        emit "$(jq -c '.' "$dir/$id.json")"
      '';
    };
  };
}
