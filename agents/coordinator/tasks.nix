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
      description = "Per-agent herdr_state + evidence-derived work_verdict (same repo only); partial on failed sources, never fails itself.";
      after = [ "herdr:inventory@completed" "gh:work@completed" "git:recent@completed" ];
      exec = ''
        ${cfg.prelude}
        at=$(now_iso)
        inv=$(upstream "herdr:inventory"); gh=$(upstream "gh:work"); git=$(upstream "git:recent")
        out=$(jq -cn --arg at "$at" --argjson inv "$inv" --argjson gh "$gh" --argjson git "$git" --argjson limit ${toString cfg.ghLimit} --argjson fleet ${lib.escapeShellArg (builtins.toJSON { inherit (cfg) hosts repos; })} '
          def failed(name; src): if src == null then [{source:name, error:{kind:"missing", message:"task produced no output"}}]
                                 else ((src.failed_sources // []) | map({source:(name + ":" + (.repo // "?")), error}))
                                      + ((src.hosts // []) | map(select(.reachable == false) | {source:(name + ":" + .host), error})) end;
          ($fleet.hosts | map(select(.ssh == null) | .name)) as $local_hosts
          | ($fleet.repos) as $repos
          | def refnum: if . == null then null else (ltrimstr("#") | tonumber? // null) end;
          # the agent repo: a fleet repo whose checkout equals the agent cwd (local agents), else a repo name that appears in the title
          def under($cwd; $co): $cwd != null and $co != null and ($cwd == $co or ($cwd | startswith($co + "/")));
          def repo_for($a): ([$repos[] | select(under($a.cwd; .checkout) and ($local_hosts | index($a.host)) != null)] | first)
                            // ([$repos[] | select(. as $r | ($a.title // "") | test("(^|[^A-Za-z0-9_.-])" + ($r.name | gsub("\\."; "\\\\.")) + "([^A-Za-z0-9_.-]|$)"))] | first) // null;
          def evidence_for($a): ($a.task_ref | refnum) as $n | repo_for($a) as $repo
            | if $n == null then {verdict:"unknown", refs:[], reasons:["no task reference (#N) on the agent"]}
              elif $gh == null or (($gh.repos // []) | length) == 0 then {verdict:"unknown", refs:[], reasons:["GitHub evidence unavailable" + (if $gh != null and (($gh.failed_sources // []) | length) > 0 then " (" + ($gh.failed_sources | map(.error.kind) | unique | join(",")) + ")" else "" end)]}
              elif $repo == null or $repo.gh == null then {verdict:"unknown", refs:[], reasons:["cannot tell which fleet repo #\($n) belongs to (no checkout match, no repo name in title)"]}
              else (($gh.repos // []) | map(select(.repo == $repo.name)) | first) as $g
              | if $g == null then {verdict:"unknown", refs:[], reasons:["no GitHub data for \($repo.name) in this run"]}
                else ([$g.prs[] | select(((.closes // []) | index($n)) != null or ((.title // "") | test("(^|[^0-9])#\($n)([^0-9]|$)")))]) as $ps
                | ([$g.issues[] | select(.number == $n)]) as $is
                | (any($ps[]; .merged_at != null)) as $merged | (any($ps[]; .state == "OPEN")) as $open
                # only the OPEN lists can hide something; a truncated open list means "cannot confirm nothing is still open"
                | (($g.issues | length) >= $limit) as $issues_truncated | (($g.open_pr_count // 0) >= $limit) as $prs_truncated
                | if $merged and ($open | not) and ($is | length) == 0 and ($issues_truncated | not) and ($prs_truncated | not) then {verdict:"verified", refs:[$ps[] | select(.merged_at != null) | .url], reasons:["merged PR in \($repo.gh) closes or names #\($n); no open issue or PR for it"]}
                  elif $merged and ($open | not) and ($is | length) == 0 then {verdict:"unverified", refs:[$ps[] | select(.merged_at != null) | .url], reasons:["merged PR names #\($n) but the open issue or PR list is truncated at \($limit); cannot confirm nothing is still open"]}
                  elif $merged and ($open | not) then {verdict:"unverified", refs:[$ps[] | select(.merged_at != null) | .url], reasons:["merged PR names #\($n) but issue #\($n) is still open in \($repo.gh)"]}
                  elif $open then {verdict:"unverified", refs:[$ps[] | select(.state=="OPEN") | .url],
                       reasons:(["open PR for #\($n) in \($repo.gh), not merged"] + [$ps[] | select(.state=="OPEN") | select(any(.checks[]?; . != "SUCCESS")) | "PR #\(.number) has non-green checks"])}
                  elif ($is | length) > 0 then {verdict:"unverified", refs:[$is[].url], reasons:["issue #\($n) open in \($repo.gh), no PR found"]}
                  else {verdict:"unknown", refs:[], reasons:["#\($n) not found in \($repo.gh)"]} end end end;
          {schema_version:1, task:"work:status", observed_at:$at, answered_hosts:($inv.answered_hosts // 0),
           failed_sources: (failed("herdr:inventory"; $inv) + failed("gh:work"; $gh) + failed("git:recent"; $git)),
           items: [($inv.hosts // [])[] | .host as $h | .agents[] | . as $a
             | (evidence_for($a)) as $e
             | ([($git.repos // [])[] | select(under($a.cwd; .checkout) and ($local_hosts | index($h)) != null)] | first) as $co
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
          | .partial = ((.failed_sources | length) > 0)') || fail 2 malformed "work:status could not join its sources" '{"task":"work:status"}'
        emit "$out"
      '';
    };

    "coord:brief" = {
      description = "Owner-facing brief: items needing input first, then every agent with herdr_state and work_verdict.";
      after = [ "work:status@completed" ];
      exec = ''
        ${cfg.prelude}
        ws=$(upstream "work:status")
        [ "$ws" != null ] || fail 2 missing "work:status produced no output" '{"task":"coord:brief"}'
        dir="${cfg.stateDir}/brief"; mkdir -p "$dir"
        # an empty fleet (no hosts in the fleet file, or no file at all) is a configuration state, not a failure: say so
        brief=$(jq -c --argjson n ${toString (builtins.length cfg.hosts)} --arg ff ${lib.escapeShellArg (toString cfg.fleetFile)} '. + {task:"coord:brief", hosts_configured:$n, fleet_file:$ff}' <<<"$ws")
        printf '%s\n' "$brief" > "$dir/latest.json.tmp" && mv "$dir/latest.json.tmp" "$dir/latest.json"
        printf '%s\n' "$brief" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
        jq -r --arg f "$dir/latest.json" '
          "# Fleet brief (\(.observed_at))",
          (if .hosts_configured == 0 then "", "**Fleet is empty:** no hosts in \(.fleet_file) (an absent file is an empty fleet). Add hosts there to see agents; nothing below can be observed." else empty end),
          (if .partial then "", "**Partial:** " + ([.failed_sources[] | "\(.source): \(.error.kind) — \(.error.message)"] | join("; ")) else empty end),
          "", "## Needs you",
          (([.items[] | select(.needs_owner)] | if length == 0 then ["- nothing"] else (.[0:10] | map("- \(.host)/\(.agent_id) (\(.harness)) \(.task_ref // "no ref"): herdr=\(.herdr_state) → \(.reasons | join("; "))")) + (if length > 10 then ["… \(length - 10) more needing you in the JSON"] else [] end) end)[]),
          "", "Full JSON: \($f)", "", "## Agents",
          (if (.items|length) == 0 then "- none observed" else (.items[0:30][] | "- \(.host)/\(.agent_id) \(.harness) \(.task_ref // "-") | herdr=\(.herdr_state) (\(.state_age_s)s\(if .stale then ", stale" else "" end)) | work=\(.work_verdict)\(if .evidence_ref then " " + .evidence_ref else "" end)\(if (.reasons|length) > 0 then " | " + (.reasons | join("; ")) else "" end)") end),
          (if (.items|length) > 30 then "… \((.items|length) - 30) more agents in the JSON" else empty end)
        ' <<<"$brief"
        # the brief is the one task whose exit says something: hosts configured but none answered and nothing stale to
        # show is a failure; an empty fleet is reported above and exits 0
        [ "$(jq -r '(.hosts_configured == 0) or ((.items|length) > 0) or (.answered_hosts > 0)' <<<"$brief")" = true ] || exit 2
      '';
    };

    "coord:handoff" = {
      description = "Draft (never send) a bounded assignment brief for one agent; saves it under the state dir with a handoff_id.";
      input = { host = null; agent_id = null; session_id = null; task_ref = null; scope = null; expected_evidence = null; acceptance = null; owner_input = ""; };
      exec = ''
        ${cfg.prelude}
        host=$(input .host); agent=$(input .agent_id); ses=$(input .session_id); ref=$(input .task_ref); scope=$(input .scope); ev=$(input .expected_evidence); acc=$(input .acceptance); need=$(input .owner_input)
        ctx=$(jq -cn --arg h "$host" --arg a "$agent" '{task:"coord:handoff",host:$h,agent_id:$a}')
        [ -z "$ses" ] || [[ "$ses" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 3 invalid_input "session_id has unsafe characters" "$ctx"
        [ -n "$host" ] && [ -n "$agent" ] && [ -n "$ref" ] && [ -n "$scope" ] && [ -n "$ev" ] && [ -n "$acc" ] \
          || fail 3 invalid_input "host, agent_id, task_ref, scope, expected_evidence and acceptance are required" "$ctx"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters" "$ctx"
        [[ "$ref" =~ ^#[0-9]+$ ]] || fail 3 invalid_input "task_ref must look like #N" "$ctx"
        ${cfg.hostCase}
        for v in "$scope" "$ev" "$acc" "$need"; do [ "''${#v}" -le 2000 ] || fail 3 invalid_input "a field exceeds 2000 characters" "$ctx"; done
        at=$(now_iso)
        text=$(printf 'Assignment %s for %s/%s\n\nScope: %s\n\nExpected evidence: %s\n\nAcceptance: %s\n%s\nReply in this pane when done, naming the commit or PR. Do not merge, deploy or delete anything.\n' \
          "$ref" "$host" "$agent" "$scope" "$ev" "$acc" "$([ -n "$need" ] && printf '\nOwner input still needed: %s\n' "$need")")
        id=$(printf '%s|%s|%s|%s|%s' "$host" "$agent" "$ses" "$ref" "$text" | sha256sum | cut -c1-12)
        dir="${cfg.stateDir}/handoffs"; mkdir -p "$dir"
        rec=$(jq -cn --arg id "$id" --arg at "$at" --arg h "$host" --arg a "$agent" --arg ses "$ses" --arg r "$ref" --arg t "$text" --arg need "$need" \
          '{schema_version:1, task:"coord:handoff", handoff_id:$id, created_at:$at, host:$h, agent_id:$a, session_id:(if $ses == "" then null else $ses end), task_ref:$r, text:$t,
            owner_input: (if $need == "" then null else $need end), approval_required:true, error:null}')
        if [ ! -f "$dir/$id.json" ]; then
          [ -n "$rec" ] && printf '%s\n' "$rec" > "$dir/$id.json.tmp" && mv "$dir/$id.json.tmp" "$dir/$id.json" || fail 2 state_write_failed "could not write the draft under $dir" "$ctx"
        fi
        emit "$(jq -c '.' "$dir/$id.json")"
      '';
    };
  };
}
